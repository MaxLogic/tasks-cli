//! The restricted RFC 9421/RFC 9530 application profile from spec.md.
use super::{OwnedServer, Registration, ServiceError};
use crate::model::{Attribution, AttributionSource};
use crate::remote::signing::{
    header, signature_base, COMPONENTS, MAX_PROTOCOL_VERSION, MIN_PROTOCOL_VERSION, PROTOCOL_HEADER,
};
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
        let expected_type = if crate::remote::signing::is_upload(method, uri) {
            "application/octet-stream"
        } else {
            "application/json"
        };
        if header(headers, "content-type")? != expected_type {
            return Err(ServiceError::Unauthorized(
                "content type does not match the signed route profile",
            ));
        }
        let download = crate::remote::signing::is_download(method, uri);
        let binary = crate::remote::signing::is_upload(method, uri) || download;
        if binary && headers.contains_key("transfer-encoding") {
            return Err(ServiceError::Unauthorized(
                "binary requests require a fixed signed length",
            ));
        }
        // Downloads are always bodiless. A gateway may add or remove a zero
        // framing header, but must never control the signed component profile.
        if download
            && headers.contains_key("content-length")
            && header(headers, "content-length")? != "0"
        {
            return Err(ServiceError::Unauthorized(
                "download content length must be zero",
            ));
        }
        let signed_length = crate::remote::signing::is_upload(method, uri);
        if signed_length {
            let text = header(headers, "content-length")?;
            if text
                .parse::<u64>()
                .ok()
                .is_none_or(|n| n.to_string() != text)
            {
                return Err(ServiceError::Unauthorized("invalid signed content length"));
            }
        }
        let addressed = Uuid::parse_str(header(headers, "x-tasks-server-id")?)
            .map_err(|_| ServiceError::Unauthorized("invalid server identity"))?;
        if addressed != self.server_id() {
            return Err(ServiceError::Unauthorized(
                "request is addressed to another server",
            ));
        }
        let version = if headers.contains_key(PROTOCOL_HEADER) {
            let text = header(headers, PROTOCOL_HEADER)?;
            Some(
                text.parse::<u32>()
                    .ok()
                    .filter(|v| v.to_string() == text)
                    .ok_or(ServiceError::Unauthorized("invalid protocol version"))?,
            )
        } else {
            None
        };
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
        if version.is_none() {
            expected.retain(|name| *name != PROTOCOL_HEADER);
        }
        if mutation {
            expected.push("idempotency-key");
        }
        if signed_length {
            expected.push("content-length");
        }
        // Compatibility with clients before TSK-056: their fixed zero length
        // is authenticated even if an intermediary removed the framing header.
        // All other components and signature parameters remain exact.
        let legacy_download_length = download
            && list.items.len() == expected.len() + 1
            && list.items.last().is_some_and(|item| {
                item.bare_item.as_string().map(|v| v.as_str()) == Some("content-length")
            });
        if legacy_download_length {
            expected.push("content-length");
        }
        if list.items.len() != expected.len()
            || list.items.iter().zip(expected).any(|(item, name)| {
                !item.params.is_empty()
                    || item.bare_item.as_string().map(|value| value.as_str()) != Some(name)
            })
        {
            return Err(ServiceError::Unauthorized(
                "signed components do not match the request profile; check gateway header preservation",
            ));
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
        let registration = {
            let _credential = super::timing::Phase::Credential.start();
            self.credential(credential_id)?
        };
        let key = VerifyingKey::from_bytes(&registration.public_key)
            .map_err(|_| ServiceError::Unauthorized("invalid registered public key"))?;
        // Serialize the parsed inner list, preserving parameter order per RFC 9421.
        let serialized = dictionary
            .serialize()
            .ok_or(ServiceError::Unauthorized("empty signature input"))?;
        let parameters = serialized
            .strip_prefix("tasks=")
            .ok_or(ServiceError::Unauthorized("unexpected signature label"))?;
        let mut normalized;
        let signed_headers = if download {
            normalized = headers.clone();
            normalized.remove("content-length");
            if legacy_download_length {
                normalized.insert("content-length", http::HeaderValue::from_static("0"));
            }
            &normalized
        } else {
            headers
        };
        let base = signature_base(method, uri, signed_headers, parameters, mutation)?;
        {
            let _signature = super::timing::Phase::Signature.start();
            key.verify_strict(base.as_bytes(), &signature)
                .map_err(|_| ServiceError::Unauthorized("signature verification failed"))?;
        }
        if version.is_none_or(|v| v < MIN_PROTOCOL_VERSION)
            || version.is_some_and(|v| v > MAX_PROTOCOL_VERSION)
        {
            let (code, update) = if version.is_some_and(|v| v > MAX_PROTOCOL_VERSION) {
                (
                    "server_upgrade_required",
                    "update tasks-server before using this client",
                )
            } else {
                (
                    "client_upgrade_required",
                    "update the tasks CLI and viewer before retrying",
                )
            };
            let client =
                version.map_or_else(|| "1 (version header absent)".into(), |v| v.to_string());
            return Err(ServiceError::UpgradeRequired {
                code,
                message: format!("update required: client protocol {client}; server supports protocols {MIN_PROTOCOL_VERSION}..={MAX_PROTOCOL_VERSION}; {update}"),
                // This is a pre-admission refusal marker, never a stored
                // mutation receipt or evidence about an earlier attempt.
                receipt: idempotency_key.map(|request_id| crate::remote::protocol::RequestReceipt {
                    request_id,
                    route: format!("{method} {uri}"),
                    payload_sha256: digest.iter().map(|b| format!("{b:02x}")).collect(),
                    status: 426,
                }),
            });
        }
        self.consume_nonce(credential_id, nonce, expires, now)?;
        Ok(AuthenticatedRequest {
            credential_id,
            registration,
            idempotency_key,
            digest,
        })
    }
}
