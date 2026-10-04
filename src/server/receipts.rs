//! Durable deduplication in the same project transaction as the mutation.
use crate::{store::Store, AppError};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct ReceiptIdentity {
    pub request_id: Uuid,
    pub actor_id: String,
    pub installation_id: Uuid,
    pub route: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReceiptResponse {
    pub status: u16,
    pub body: Value,
    #[serde(skip)]
    pub receipt: Option<crate::remote::protocol::RequestReceipt>,
}

pub fn refusal(error: &AppError) -> Option<ReceiptResponse> {
    let status = match error {
        AppError::VersionConflict { .. } | AppError::StaleSnapshot(_) | AppError::Conflict(_) => {
            409
        }
        AppError::NotFound(_) | AppError::NotFoundCode(_) => 404,
        AppError::ResponseLimit(_) => 413,
        AppError::Usage(_)
        | AppError::Validation(_)
        | AppError::OpenPrerequisites { .. }
        | AppError::InvalidPath(_)
        | AppError::ShaMismatch { .. } => 400,
        _ => return None,
    };
    // Only application errors with public messages enter the durable response.
    let mut body = serde_json::from_str::<Value>(&error.json()).ok()?;
    body["error"]["exit_code"] = json!(error.exit_code());
    Some(ReceiptResponse {
        status,
        body,
        receipt: None,
    })
}

/// Owning the connection ensures even a panic drops and rolls back the outer
/// transaction. Callers must prepare/validate typed input before entering here.
pub fn execute(
    mut store: Store,
    identity: &ReceiptIdentity,
    canonical_request: &[u8],
    mutation: impl FnOnce(&mut Store) -> Result<Value, AppError>,
) -> Result<ReceiptResponse, AppError> {
    let digest = crate::markdown::sha256(canonical_request);
    store.conn.execute_batch("BEGIN IMMEDIATE")?;
    let prior = store
        .conn
        .query_row(
            "SELECT actor_id,installation_id,route,payload_sha256,status,response_json
         FROM mutation_receipts WHERE request_id=?1",
            [identity.request_id.to_string()],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, u16>(4)?,
                    r.get::<_, String>(5)?,
                ))
            },
        )
        .optional()?;
    if let Some((actor, installation, route, prior_digest, status, body)) = prior {
        if actor != identity.actor_id
            || installation != identity.installation_id.to_string()
            || route != identity.route
            || prior_digest != digest
        {
            return Ok(ReceiptResponse {
                receipt: None,
                status: 409,
                body: json!({"schema_version":1,"error":{
                    "code":"idempotency_conflict", "message":"this request ID belongs to a different request", "exit_code":4
                }}),
            });
        }
        return Ok(ReceiptResponse {
            receipt: Some(crate::remote::protocol::RequestReceipt {
                request_id: identity.request_id,
                route: identity.route.clone(),
                payload_sha256: digest,
                status,
            }),
            status,
            body: serde_json::from_str(&body)?,
        });
    }
    store.project_key = crate::keys::read_key(&store.conn)?;
    // The complete operation also has a savepoint: an operation consisting of
    // multiple successful store calls must not leak changes on terminal refusal.
    store.conn.execute_batch("SAVEPOINT receipt_operation")?;
    let response = match mutation(&mut store) {
        Ok(body) => {
            store.conn.execute_batch("RELEASE receipt_operation")?;
            ReceiptResponse {
                status: 200,
                body,
                receipt: None,
            }
        }
        Err(error) => {
            store
                .conn
                .execute_batch("ROLLBACK TO receipt_operation; RELEASE receipt_operation")?;
            match refusal(&error) {
                Some(response) => response,
                None => return Err(error),
            }
        }
    };
    let body = serde_json::to_string(&response.body)?;
    store.conn.execute(
        "INSERT INTO mutation_receipts(request_id,actor_id,installation_id,route,payload_sha256,status,response_json)
         VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![identity.request_id.to_string(),identity.actor_id,identity.installation_id.to_string(),identity.route,digest,response.status,body],
    )?;
    store.conn.execute_batch("COMMIT")?;
    Ok(ReceiptResponse {
        receipt: Some(crate::remote::protocol::RequestReceipt {
            request_id: identity.request_id,
            route: identity.route.clone(),
            payload_sha256: digest,
            status: response.status,
        }),
        ..response
    })
}
