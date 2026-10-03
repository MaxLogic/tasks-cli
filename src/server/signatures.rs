//! The restricted RFC 9421/RFC 9530 application profile from spec.md.
use super::{OwnedServer, Registration, ServiceError};
use crate::model::{Attribution, AttributionSource};
use axum::http::{HeaderMap, HeaderValue, Method, Uri};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand_core::{OsRng, RngCore};
use sfv::{Dictionary, FieldType, ListEntry, Parser, Version};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const COMPONENTS: [&str; 6] = [
    "@method",
    "@path",
    "@query",
    "content-type",
    "content-digest",
    "x-tasks-server-id",
];
const PARAMS: [&str; 5] = ["created", "expires", "nonce", "alg", "keyid"];

pub struct SigningIdentity {
    pub credential_id: Uuid,
    pub server_id: Uuid,
    pub key: SigningKey,
}

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

pub fn is_mutation(method: &Method, uri: &Uri) -> bool {
    if matches!(*method, Method::GET | Method::HEAD) {
        return false;
    }
    if *method == Method::POST {
        let segments = uri.path().split('/').collect::<Vec<_>>();
        if segments.len() == 5
            && segments[1] == "v1"
            && segments[2] == "projects"
            && Uuid::parse_str(segments[3]).is_ok()
            && segments[4] == "query"
        {
            return false;
        }
    }
    true
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Result<&'a str, ServiceError> {
    let mut values = headers.get_all(name).iter();
    let value = values
        .next()
        .ok_or(ServiceError::Unauthorized("missing signed header"))?;
    if values.next().is_some() {
        return Err(ServiceError::Unauthorized("duplicate security header"));
    }
    let text = value
        .to_str()
        .map_err(|_| ServiceError::Unauthorized("invalid security header"))?;
    if text.len() > 2048 {
        return Err(ServiceError::Unauthorized("oversized security header"));
    }
    Ok(text.trim())
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

fn signature_base(
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    parameters: &str,
    mutation: bool,
) -> Result<String, ServiceError> {
    // RFC 9421: absent query is '?', encoded octets stay encoded, method is case-sensitive.
    let query = format!("?{}", uri.query().unwrap_or(""));
    let path = if uri.path().is_empty() {
        "/"
    } else {
        uri.path()
    };
    let mut base = format!("\"@method\": {method}\n\"@path\": {path}\n\"@query\": {query}");
    for name in &COMPONENTS[3..] {
        base.push_str(&format!("\n\"{name}\": {}", header(headers, name)?));
    }
    if mutation {
        base.push_str(&format!(
            "\n\"idempotency-key\": {}",
            header(headers, "idempotency-key")?
        ));
    }
    base.push_str(&format!("\n\"@signature-params\": {parameters}"));
    Ok(base)
}

impl SigningIdentity {
    /// Explicit freshness inputs support deterministic fixtures. Ordinary client
    /// callers use sign_now, which obtains the nonce from the OS random source.
    pub fn sign(
        &self,
        method: &Method,
        uri: &Uri,
        body: &[u8],
        idempotency: Option<Uuid>,
        created: i64,
        nonce: &[u8; 32],
    ) -> Result<HeaderMap, ServiceError> {
        let mutation = is_mutation(method, uri);
        if mutation != idempotency.is_some() || idempotency.is_some_and(|id| id.is_nil()) {
            return Err(ServiceError::Validation(
                "mutations require a non-nil idempotency UUID; reads must omit it",
            ));
        }
        if self.credential_id.is_nil()
            || self.server_id.is_nil()
            || !(0..=999_999_999_999_879).contains(&created)
        {
            return Err(ServiceError::Validation(
                "invalid signing identity or UTC timestamp",
            ));
        }
        let mut headers = HeaderMap::new();
        let mut insert = |name: &'static str, value: String| -> Result<(), ServiceError> {
            headers.insert(
                name,
                HeaderValue::from_str(&value)
                    .map_err(|_| ServiceError::Validation("invalid signing header"))?,
            );
            Ok(())
        };
        insert("content-type", "application/json".into())?;
        insert(
            "content-digest",
            format!("sha-256=:{}:", STANDARD.encode(Sha256::digest(body))),
        )?;
        insert("x-tasks-server-id", self.server_id.to_string())?;
        if let Some(id) = idempotency {
            insert("idempotency-key", id.to_string())?;
        }
        let mut components = COMPONENTS
            .iter()
            .map(|name| format!("\"{name}\""))
            .collect::<Vec<_>>();
        if mutation {
            components.push("\"idempotency-key\"".into());
        }
        let parameters = format!(
            "({});created={created};expires={};nonce=\"{}\";alg=\"ed25519\";keyid=\"{}\"",
            components.join(" "),
            created + 120,
            URL_SAFE_NO_PAD.encode(nonce),
            self.credential_id
        );
        let base = signature_base(method, uri, &headers, &parameters, mutation)?;
        let signature = self.key.sign(base.as_bytes());
        headers.insert(
            "signature-input",
            format!("tasks={parameters}")
                .parse()
                .map_err(|_| ServiceError::Validation("invalid signature parameters"))?,
        );
        headers.insert(
            "signature",
            format!("tasks=:{}:", STANDARD.encode(signature.to_bytes()))
                .parse()
                .map_err(|_| ServiceError::Validation("invalid signature"))?,
        );
        Ok(headers)
    }

    pub fn sign_now(
        &self,
        method: &Method,
        uri: &Uri,
        body: &[u8],
        idempotency: Option<Uuid>,
    ) -> Result<HeaderMap, ServiceError> {
        let mut nonce = [0; 32];
        OsRng
            .try_fill_bytes(&mut nonce)
            .map_err(|_| ServiceError::Validation("OS randomness unavailable"))?;
        let created = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| ServiceError::Clock)?
            .as_secs();
        let created = i64::try_from(created).map_err(|_| ServiceError::Clock)?;
        self.sign(method, uri, body, idempotency, created, &nonce)
    }
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
