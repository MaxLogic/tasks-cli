//! The restricted RFC 9421/RFC 9530 application profile from spec.md.
use super::{OwnedServer, Registration, ServiceError};
use crate::model::{Attribution, AttributionSource};
use crate::remote::signing::{header, signature_base, COMPONENTS};
pub use crate::remote::signing::{is_mutation, SigningIdentity};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use http::{HeaderMap, Method, Uri};
use sfv::{Dictionary, FieldType, ListEntry, Parser, Version};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const PARAMS: [&str; 5] = ["created", "expires", "nonce", "alg", "keyid"];

pub struct AuthenticatedRequest {
    pub credential_id: Uuid,
    pub registration: Registration,
    pub idempotency_key: Option<Uuid>,
    digest: [u8; 32],
}

impl AuthenticatedRequest {
    pub fn check_body(&self, body: &[u8]) -> Result<(), ServiceError> {
        if Sha256::digest(body).as_slice() != self.digest {
            return Err(ServiceError::Unauthorized("body digest does not match"));
        }
        Ok(())
    }

    pub fn apply_identity(&self, context: &mut Attribution) {
        context.actor_id = Some(self.registration.actor_id.clone());
        context.actor_name = Some(self.registration.actor_name.clone());
        context.actor_authority = AttributionSource::Credential;
        context.machine_id = Some(self.registration.installation_id);
        context.registered_machine_name = Some(self.registration.installation_name.clone());
        for name in [
            "actor_id",
            "actor_name",
            "machine_id",
            "registered_machine_name",
        ] {
            context
                .context_source
                .insert(name.into(), AttributionSource::Credential);
        }
        if let Some(id) = self.idempotency_key {
            context.request_id = id;
        }
    }
}

fn parse_dictionary(text: &str) -> Result<Dictionary, ServiceError> {
    // This profile has one member. Its string fields are fixed UUID/algorithm/
    // base64url values, so commas cannot be valid member content either.
    if text.contains(',') {
        return Err(ServiceError::Unauthorized(
            "additional signature or digest member",
        ));
    }
    Parser::new(text)
        .with_version(Version::Rfc8941)
        .parse()
        .map_err(|_| ServiceError::Unauthorized("malformed structured security header"))
}

fn bytes_member(text: &str, label: &str) -> Result<Vec<u8>, ServiceError> {
    let dictionary = parse_dictionary(text)?;
    if dictionary.len() != 1 {
        return Err(ServiceError::Unauthorized("unexpected security member"));
    }
    let Some(ListEntry::Item(item)) = dictionary.get(label) else {
        return Err(ServiceError::Unauthorized("missing security member"));
    };
    if !item.params.is_empty() {
        return Err(ServiceError::Unauthorized("unexpected security parameters"));
    }
    item.bare_item
        .as_byte_sequence()
        .map(ToOwned::to_owned)
        .ok_or(ServiceError::Unauthorized(
            "expected security byte sequence",
        ))
}

impl OwnedServer {
    /// Verifies only bounded metadata and consumes the nonce before body reads.
    /// The HTTP layer must call check_body before any project lookup or dispatch.
    pub fn authenticate(
        &self,
        method: &Method,
        uri: &Uri,
        headers: &HeaderMap,
        now: i64,
    ) -> Result<AuthenticatedRequest, ServiceError> {
        if headers.contains_key("content-encoding") {
            return Err(ServiceError::Unauthorized(
                "request compression is unsupported",
            ));
        }
        if header(headers, "content-type")? != "application/json" {
            return Err(ServiceError::Unauthorized(
                "content type must be application/json",
            ));
        }
        let addressed = Uuid::parse_str(header(headers, "x-tasks-server-id")?)
            .map_err(|_| ServiceError::Unauthorized("invalid server identity"))?;
        if addressed != self.server_id() {
            return Err(ServiceError::Unauthorized(
                "request is addressed to another server",
            ));
        }
        let input = header(headers, "signature-input")?;
        let dictionary = parse_dictionary(input)?;
        if dictionary.len() != 1 || input.bytes().filter(|byte| *byte == b';').count() != 5 {
            return Err(ServiceError::Unauthorized(
                "unexpected signature parameters",
            ));
        }
        let Some(ListEntry::InnerList(list)) = dictionary.get("tasks") else {
            return Err(ServiceError::Unauthorized("missing tasks signature input"));
        };
        if list.params.len() != 5 || PARAMS.iter().any(|name| !list.params.contains_key(*name)) {
            return Err(ServiceError::Unauthorized(
                "unsupported signature parameters",
            ));
        }
        let mutation = is_mutation(method, uri);
        let mut expected = COMPONENTS.to_vec();
        if mutation {
            expected.push("idempotency-key");
        }
        if list.items.len() != expected.len()
            || list.items.iter().zip(expected).any(|(item, name)| {
                !item.params.is_empty()
                    || item.bare_item.as_string().map(|value| value.as_str()) != Some(name)
            })
        {
            return Err(ServiceError::Unauthorized("unexpected signed components"));
        }
        let string = |name: &str| {
            list.params
                .get(name)
                .and_then(|value| value.as_string())
                .map(|value| value.as_str())
                .ok_or(ServiceError::Unauthorized(
                    "invalid signature string parameter",
                ))
        };
        let integer = |name: &str| {
            list.params
                .get(name)
                .and_then(|value| value.as_integer())
                .map(i64::from)
                .ok_or(ServiceError::Unauthorized("invalid signature timestamp"))
        };
        if string("alg")? != "ed25519" {
            return Err(ServiceError::Unauthorized(
                "unsupported signature algorithm",
            ));
        }
        let credential_id = Uuid::parse_str(string("keyid")?)
            .map_err(|_| ServiceError::Unauthorized("invalid credential identity"))?;
        let nonce = string("nonce")?;
        let decoded = URL_SAFE_NO_PAD
            .decode(nonce)
            .map_err(|_| ServiceError::Unauthorized("invalid nonce"))?;
        if decoded.len() != 32 || URL_SAFE_NO_PAD.encode(&decoded) != nonce {
            return Err(ServiceError::Unauthorized(
                "nonce must contain 32 random bytes",
            ));
        }
        let created = integer("created")?;
        let expires = integer("expires")?;
        if created < 0
            || created.checked_add(120) != Some(expires)
            || created > now.saturating_add(30)
            || expires < now.saturating_sub(30)
        {
            return Err(ServiceError::Clock);
        }
        let idempotency_key = if mutation {
            let id = Uuid::parse_str(header(headers, "idempotency-key")?)
                .map_err(|_| ServiceError::Unauthorized("invalid idempotency identity"))?;
            if id.is_nil() {
                return Err(ServiceError::Unauthorized("nil idempotency identity"));
            }
            Some(id)
        } else {
            if headers.contains_key("idempotency-key") {
                return Err(ServiceError::Unauthorized(
                    "read request has an unsigned idempotency header",
                ));
            }
            None
        };
        let digest: [u8; 32] = bytes_member(header(headers, "content-digest")?, "sha-256")?
            .try_into()
            .map_err(|_| ServiceError::Unauthorized("invalid SHA-256 digest length"))?;
        let signature =
            Signature::from_slice(&bytes_member(header(headers, "signature")?, "tasks")?)
                .map_err(|_| ServiceError::Unauthorized("invalid signature length"))?;
        let registration = self.credential(credential_id)?;
        let key = VerifyingKey::from_bytes(&registration.public_key)
            .map_err(|_| ServiceError::Unauthorized("invalid registered public key"))?;
        // Serialize the parsed inner list, preserving parameter order per RFC 9421.
        let serialized = dictionary
            .serialize()
            .ok_or(ServiceError::Unauthorized("empty signature input"))?;
        let parameters = serialized
            .strip_prefix("tasks=")
            .ok_or(ServiceError::Unauthorized("unexpected signature label"))?;
        let base = signature_base(method, uri, headers, parameters, mutation)?;
        key.verify_strict(base.as_bytes(), &signature)
            .map_err(|_| ServiceError::Unauthorized("signature verification failed"))?;
        self.consume_nonce(credential_id, nonce, expires, now)?;
        Ok(AuthenticatedRequest {
            credential_id,
            registration,
            idempotency_key,
            digest,
        })
    }
}
