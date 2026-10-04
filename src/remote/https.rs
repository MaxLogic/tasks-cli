//! Strict synchronous HTTPS with bounded bodies and fresh request signatures.
use super::signing::SigningIdentity;
use http::{Method, Uri};
use reqwest::{blocking::Client, redirect::Policy, Url};
use std::{io::Read, path::PathBuf, time::Duration};
use thiserror::Error;
use uuid::Uuid;

const MAX_REQUEST_BYTES: usize = 8 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
#[derive(Debug, Error)]
pub enum ClientError {
    #[error("invalid remote configuration: {0}")]
    Configuration(&'static str),
    #[error("HTTPS connection failed; check server availability, hostname, certificate trust and UTC clock")]
    Transport,
    #[error("HTTPS endpoint returned a redirect; configure its final HTTPS origin explicitly")]
    Redirect,
    #[error("server response exceeds the 16 MiB limit; use a smaller read or streamed export")]
    ResponseLimit,
    #[error("export transfer is incomplete or invalid; discard partial output")]
    Export,
    #[error("request signature could not be created; check credential identity and UTC clock")]
    Signature,
}

pub struct ClientOptions {
    pub private_ca: Option<PathBuf>,
    pub connect_timeout: Duration,
    pub request_timeout: Duration,
}
impl Default for ClientOptions {
    fn default() -> Self {
        Self {
            private_ca: None,
            connect_timeout: Duration::from_secs(3),
            request_timeout: Duration::from_secs(15),
        }
    }
}
pub struct HttpsClient {
    client: Client,
    origin: Url,
    identity: SigningIdentity,
}
pub(crate) fn validate_origin(endpoint: &str) -> Result<Url, ClientError> {
    let origin =
        Url::parse(endpoint).map_err(|_| ClientError::Configuration("expected an HTTPS origin"))?;
    if origin.scheme() != "https"
        || origin.host_str().is_none()
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.path() != "/"
        || origin.query().is_some()
        || origin.fragment().is_some()
    {
        return Err(ClientError::Configuration(
            "use an HTTPS origin without credentials, path, query or fragment",
        ));
    }
    Ok(origin)
}
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}
pub enum RemoteExportResponse {
    Complete(super::export::ExportSummary),
    Refused(HttpResponse),
}

impl HttpsClient {
    pub fn new(
        endpoint: &str,
        options: ClientOptions,
        identity: SigningIdentity,
    ) -> Result<Self, ClientError> {
        let origin = validate_origin(endpoint)?;
        if options.connect_timeout.is_zero() || options.request_timeout.is_zero() {
            return Err(ClientError::Configuration(
                "timeouts must be greater than zero",
            ));
        }
        let mut builder = Client::builder()
            .https_only(true)
            .min_tls_version(reqwest::tls::Version::TLS_1_2)
            .redirect(Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(options.connect_timeout)
            .timeout(options.request_timeout);
        if let Some(path) = options.private_ca {
            let file = std::fs::File::open(path)
                .map_err(|_| ClientError::Configuration("cannot open private CA file"))?;
            let mut pem = Vec::new();
            file.take(262145)
                .read_to_end(&mut pem)
                .map_err(|_| ClientError::Configuration("cannot read private CA file"))?;
            if pem.len() > 262144 {
                return Err(ClientError::Configuration(
                    "private CA file exceeds 256 KiB",
                ));
            }
            let certificates = reqwest::Certificate::from_pem_bundle(&pem)
                .map_err(|_| ClientError::Configuration("invalid private CA PEM"))?;
            if certificates.is_empty() {
                return Err(ClientError::Configuration(
                    "private CA file has no certificates",
                ));
            }
            for certificate in certificates {
                builder = builder.add_root_certificate(certificate);
            }
        }
        let client = builder
            .build()
            .map_err(|_| ClientError::Configuration("cannot initialize HTTPS client"))?;
        Ok(Self {
            client,
            origin,
            identity,
        })
    }

    /// Send exactly once. A caller must persist mutation recovery evidence before
    /// invoking this function; a transport error may follow a committed write.
    pub fn send(
        &self,
        method: Method,
        target: &str,
        body: &[u8],
        receipt: Option<Uuid>,
    ) -> Result<HttpResponse, ClientError> {
        self.read_response(self.request(method, target, body, receipt)?)
    }

    fn request(
        &self,
        method: Method,
        target: &str,
        body: &[u8],
        receipt: Option<Uuid>,
    ) -> Result<reqwest::blocking::Response, ClientError> {
        if !target.starts_with("/v1/") || target.contains('#') || body.len() > MAX_REQUEST_BYTES {
            return Err(ClientError::Configuration(
                "expected a bounded /v1/ request target",
            ));
        }
        let url = self
            .origin
            .join(target)
            .map_err(|_| ClientError::Configuration("invalid API request target"))?;
        // URL parsers can normalize dot segments. Sign only the exact bytes that
        // will be transmitted, and refuse requests whose spelling was changed.
        let transmitted = format!(
            "{}{}",
            url.path(),
            url.query()
                .map(|query| format!("?{query}"))
                .unwrap_or_default()
        );
        if transmitted != target || url.origin() != self.origin.origin() {
            return Err(ClientError::Configuration(
                "API target changes the configured origin or path",
            ));
        }
        let uri: Uri = transmitted
            .parse()
            .map_err(|_| ClientError::Configuration("invalid API request target"))?;
        let headers = self
            .identity
            .sign_now(&method, &uri, body, receipt)
            .map_err(|_| ClientError::Signature)?;
        let response = self
            .client
            .request(method, url)
            .headers(headers)
            .body(body.to_vec())
            .send()
            .map_err(|_| ClientError::Transport)?;
        if response.status().is_redirection() {
            return Err(ClientError::Redirect);
        }
        Ok(response)
    }

    fn read_response(
        &self,
        mut response: reqwest::blocking::Response,
    ) -> Result<HttpResponse, ClientError> {
        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
        {
            return Err(ClientError::ResponseLimit);
        }
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        Read::by_ref(&mut response)
            .take((MAX_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| ClientError::Transport)?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(ClientError::ResponseLimit);
        }
        Ok(HttpResponse {
            status,
            body: bytes,
        })
    }

    pub fn export(
        &self,
        project: Uuid,
        out: &mut impl std::io::Write,
    ) -> Result<RemoteExportResponse, ClientError> {
        let response = self.request(
            Method::GET,
            &format!("/v1/projects/{project}/export"),
            b"",
            None,
        )?;
        if response.status().as_u16() != 200 {
            return self
                .read_response(response)
                .map(RemoteExportResponse::Refused);
        }
        if response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(';').next())
            .map(str::trim)
            != Some("application/x-ndjson")
        {
            return Err(ClientError::Export);
        }
        let summary = super::export::consume(&mut std::io::BufReader::new(response), out, project)
            .map_err(|_| ClientError::Export)?;
        Ok(RemoteExportResponse::Complete(summary))
    }
}
