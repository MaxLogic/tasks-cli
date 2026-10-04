//! Client signing uses HTTP types without depending on the server runtime.
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use ed25519_dalek::{Signer, SigningKey};
use http::{HeaderMap, HeaderValue, Method, Uri};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;
#[derive(Debug, Error)]
pub enum SigningError {
    #[error("invalid signed header: {0}")]
    Unauthorized(&'static str),
    #[error("invalid UTC clock")]
    Clock,
    #[error("invalid signing input: {0}")]
    Validation(&'static str),
}
pub(crate) const COMPONENTS: [&str; 6] = [
    "@method",
    "@path",
    "@query",
    "content-type",
    "content-digest",
    "x-tasks-server-id",
];
pub struct SigningIdentity {
    pub credential_id: Uuid,
    pub server_id: Uuid,
    pub key: SigningKey,
}

pub fn is_mutation(method: &Method, uri: &Uri) -> bool {
    if matches!(*method, Method::GET | Method::HEAD) {
        return false;
    }
    if *method == Method::POST {
        if uri.path() == "/v1/viewer/projects" {
            return false;
        }
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

pub(crate) fn header<'a>(headers: &'a HeaderMap, name: &str) -> Result<&'a str, SigningError> {
    let mut values = headers.get_all(name).iter();
    let value = values
        .next()
        .ok_or(SigningError::Unauthorized("missing signed header"))?;
    if values.next().is_some() {
        return Err(SigningError::Unauthorized("duplicate security header"));
    }
    let text = value
        .to_str()
        .map_err(|_| SigningError::Unauthorized("invalid security header"))?;
    if text.len() > 2048 {
        return Err(SigningError::Unauthorized("oversized security header"));
    }
    Ok(text.trim())
}

pub(crate) fn signature_base(
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    parameters: &str,
    mutation: bool,
) -> Result<String, SigningError> {
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
    ) -> Result<HeaderMap, SigningError> {
        let mutation = is_mutation(method, uri);
        if mutation != idempotency.is_some() || idempotency.is_some_and(|id| id.is_nil()) {
            return Err(SigningError::Validation(
                "mutations require a non-nil idempotency UUID; reads must omit it",
            ));
        }
        if self.credential_id.is_nil()
            || self.server_id.is_nil()
            || !(0..=999_999_999_999_879).contains(&created)
        {
            return Err(SigningError::Validation(
                "invalid signing identity or UTC timestamp",
            ));
        }
        let mut headers = HeaderMap::new();
        let mut insert = |name: &'static str, value: String| -> Result<(), SigningError> {
            headers.insert(
                name,
                HeaderValue::from_str(&value)
                    .map_err(|_| SigningError::Validation("invalid signing header"))?,
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
                .map_err(|_| SigningError::Validation("invalid signature parameters"))?,
        );
        headers.insert(
            "signature",
            format!("tasks=:{}:", STANDARD.encode(signature.to_bytes()))
                .parse()
                .map_err(|_| SigningError::Validation("invalid signature"))?,
        );
        Ok(headers)
    }

    pub fn sign_now(
        &self,
        method: &Method,
        uri: &Uri,
        body: &[u8],
        idempotency: Option<Uuid>,
    ) -> Result<HeaderMap, SigningError> {
        let mut nonce = [0; 32];
        OsRng
            .try_fill_bytes(&mut nonce)
            .map_err(|_| SigningError::Validation("OS randomness unavailable"))?;
        let created = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| SigningError::Clock)?
            .as_secs();
        let created = i64::try_from(created).map_err(|_| SigningError::Clock)?;
        self.sign(method, uri, body, idempotency, created, &nonce)
    }
}
