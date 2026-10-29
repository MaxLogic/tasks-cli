#![allow(dead_code)]
use http::Method;
use tasks_cli::remote::https::ClientOptions;
// Fixture I/O must allow for loaded test hosts without becoming unbounded.
pub const FIXTURE_IO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub struct HttpBackend {
    pub address: std::net::SocketAddr,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl HttpBackend {
    pub fn new(state: tasks_cli::server::transport::ServiceState) -> Self {
        let (ready, address) = std::sync::mpsc::channel();
        let (stop, stopped) = tokio::sync::oneshot::channel();
        let worker = std::thread::spawn(move || {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                    ready.send(listener.local_addr().unwrap()).unwrap();
                    axum::serve(tasks_cli::server::transport::TransferListener(listener),
                        state.router().into_make_service_with_connect_info::<tasks_cli::server::transport::ConnectionControl>())
                        .with_graceful_shutdown(async {
                            let _ = stopped.await;
                        })
                        .await
                        .unwrap();
                });
        });
        Self {
            address: address.recv_timeout(FIXTURE_IO_TIMEOUT).unwrap(),
            stop: Some(stop),
            worker: Some(worker),
        }
    }
}
impl Drop for HttpBackend {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !std::thread::panicking() {
                result.unwrap();
            }
        }
    }
}

pub enum Reply {
    Ok,
    JsonRoutes(Vec<(String, serde_json::Value)>),
    Redirect(String),
    Large,
    LargeStream,
    Stall,
    Authenticate(tasks_cli::server::OwnedServer),
    Proxy(std::net::SocketAddr),
    // HTTP intermediaries may omit Content-Length on an empty GET. Preserve
    // every other header and byte so this exercises the signed wire profile.
    ProxyWithoutEmptyGetLength(std::net::SocketAddr),
    ProxyWithoutProtocolVersion(std::net::SocketAddr),
    // A signed older/future client against the real binary's supported range.
    ProxyProtocol {
        address: std::net::SocketAddr,
        version: Option<u32>,
        identity: Box<tasks_cli::remote::signing::SigningIdentity>,
    },
    ProxyWithLoss {
        address: std::net::SocketAddr,
        drop_next_mutation: std::sync::Arc<std::sync::atomic::AtomicBool>,
        truncate_next_export: std::sync::Arc<std::sync::atomic::AtomicBool>,
        substitute_next_mutation: std::sync::Arc<std::sync::atomic::AtomicBool>,
    },
}
pub struct TlsFixture {
    _root: tempfile::TempDir,
    ca: std::path::PathBuf,
    port: u16,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    requests: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl TlsFixture {
    pub fn new(host: &str, expired: bool, reply: Reply) -> Self {
        use rcgen::{BasicConstraints, CertificateParams, CertifiedIssuer, IsCa, KeyPair};
        use rustls::pki_types::PrivatePkcs8KeyDer;
        use std::sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            Arc,
        };
        let root = tempfile::tempdir().unwrap();
        let mut ca_params = CertificateParams::new(vec![]).unwrap();
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let issuer = CertifiedIssuer::self_signed(ca_params, KeyPair::generate().unwrap()).unwrap();
        let ca = root.path().join("ca.pem");
        std::fs::write(&ca, issuer.pem()).unwrap();
        let mut params = CertificateParams::new(vec![host.into()]).unwrap();
        if expired {
            params.not_before = rcgen::date_time_ymd(2000, 1, 1);
            params.not_after = rcgen::date_time_ymd(2001, 1, 1);
        }
        let key = KeyPair::generate().unwrap();
        let cert = params.signed_by(&key, &issuer).unwrap();
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.der().clone()],
            PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
        )
        .unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(AtomicUsize::new(0));
        let worker_stop = stop.clone();
        let worker_requests = requests.clone();
        let worker = std::thread::spawn(move || {
            use std::io::{Read, Write};
            while !worker_stop.load(Ordering::SeqCst) {
                let (stream, _) = match listener.accept() {
                    Ok(value) => value,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                        continue;
                    }
                    Err(error) => panic!("{error}"),
                };
                // Accepted sockets inherit nonblocking mode on Windows. TLS
                // fixture I/O is synchronous and bounded by socket timeouts.
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(FIXTURE_IO_TIMEOUT)).unwrap();
                stream.set_write_timeout(Some(FIXTURE_IO_TIMEOUT)).unwrap();
                let connection = rustls::ServerConnection::new(Arc::new(config.clone())).unwrap();
                let mut stream = rustls::StreamOwned::new(connection, stream);
                let mut request = Vec::new();
                let mut byte = [0];
                while request.len() < 16384 && !request.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => request.push(byte[0]),
                        _ => break,
                    }
                }
                if !request.ends_with(b"\r\n\r\n") {
                    continue;
                }
                worker_requests.fetch_add(1, Ordering::SeqCst);
                let head = std::str::from_utf8(&request).unwrap();
                let mut lines = head.split("\r\n");
                let first = lines.next().unwrap().split_whitespace().collect::<Vec<_>>();
                let method = Method::from_bytes(first[0].as_bytes()).unwrap();
                let uri: http::Uri = first[1].parse().unwrap();
                let mut headers = axum::http::HeaderMap::new();
                for line in lines.filter(|line| !line.is_empty()) {
                    let (name, value) = line.split_once(':').unwrap();
                    headers.append(
                        axum::http::HeaderName::from_bytes(name.as_bytes()).unwrap(),
                        value.trim().parse().unwrap(),
                    );
                }
                let length = headers
                    .get("content-length")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0usize);
                assert!(length <= 52 * 1024 * 1024);
                let mut body = vec![0; length];
                stream.read_exact(&mut body).unwrap();
                match &reply {
                    Reply::JsonRoutes(routes) => {
                        let value = &routes
                            .iter()
                            .find(|(path, _)| *path == uri.path())
                            .unwrap()
                            .1;
                        let body = serde_json::to_vec(value).unwrap();
                        write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).unwrap();
                        stream.write_all(&body).unwrap();
                    }
                    Reply::Stall => {
                        std::thread::sleep(std::time::Duration::from_secs(2));
                    }
                    Reply::LargeStream => {
                        write!(stream, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").unwrap();
                        // The client deliberately closes after the bounded read.
                        let _ =
                            std::io::copy(&mut std::io::repeat(b'x').take(16777217), &mut stream);
                    }
                    Reply::Proxy(address)
                    | Reply::ProxyWithoutEmptyGetLength(address)
                    | Reply::ProxyWithoutProtocolVersion(address)
                    | Reply::ProxyProtocol { address, .. }
                    | Reply::ProxyWithLoss { address, .. } => {
                        if let Reply::ProxyProtocol {
                            version, identity, ..
                        } = &reply
                        {
                            resign_version(identity, &method, &uri, &mut headers, *version);
                        }
                        if matches!(reply, Reply::ProxyWithoutProtocolVersion(_)) {
                            headers.remove("x-tasks-protocol-version");
                        }
                        let mut upstream = std::net::TcpStream::connect(address).unwrap();
                        upstream.set_read_timeout(Some(FIXTURE_IO_TIMEOUT)).unwrap();
                        upstream
                            .set_write_timeout(Some(FIXTURE_IO_TIMEOUT))
                            .unwrap();
                        write!(upstream, "{method} {uri} HTTP/1.1\r\nConnection: close\r\n")
                            .unwrap();
                        for (name, value) in &headers {
                            let omit_length = matches!(reply, Reply::ProxyWithoutEmptyGetLength(_))
                                && method == Method::GET
                                && name == "content-length"
                                && value == "0";
                            if name != "connection" && !omit_length {
                                write!(upstream, "{name}: {}\r\n", value.to_str().unwrap())
                                    .unwrap();
                            }
                        }
                        upstream.write_all(b"\r\n").unwrap();
                        upstream.write_all(&body).unwrap();
                        let (drop_reply, truncate, substitute) = match &reply {
                            Reply::ProxyWithLoss {
                                drop_next_mutation,
                                truncate_next_export,
                                substitute_next_mutation,
                                ..
                            } => (
                                tasks_cli::remote::signing::is_mutation(&method, &uri)
                                    && drop_next_mutation.swap(false, Ordering::SeqCst),
                                uri.path().ends_with("/export")
                                    && truncate_next_export.swap(false, Ordering::SeqCst),
                                tasks_cli::remote::signing::is_mutation(&method, &uri)
                                    && substitute_next_mutation.swap(false, Ordering::SeqCst),
                            ),
                            _ => (false, false, false),
                        };
                        if drop_reply || substitute {
                            std::io::copy(
                                &mut upstream.take(128 * 1024 * 1024),
                                &mut std::io::sink(),
                            )
                            .unwrap();
                            if substitute {
                                let body =
                                    b"{\"error\":{\"message\":\"proxy unavailable after commit\"}}";
                                write!(stream,"HTTP/1.1 503 Unavailable\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).unwrap();
                                stream.write_all(body).unwrap();
                            }
                        } else {
                            std::io::copy(
                                &mut upstream.take(if truncate { 4096 } else { 128 * 1024 * 1024 }),
                                &mut stream,
                            )
                            .unwrap();
                        }
                    }
                    Reply::Redirect(location) => {
                        write!(stream,"HTTP/1.1 302 Found\r\nLocation: {location}/v1/info\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                    }
                    Reply::Large => {
                        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\nConnection: close\r\n\r\n").unwrap();
                    }
                    _ => {
                        if let Reply::Authenticate(server) = &reply {
                            let now = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap()
                                .as_secs() as i64;
                            server
                                .authenticate(&method, &uri, &headers, now)
                                .unwrap()
                                .check_body(&body)
                                .unwrap();
                        }
                        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{{\"fixture\":true}}").unwrap();
                    }
                }
                let _ = stream.flush();
            }
        });
        Self {
            _root: root,
            ca,
            port,
            stop,
            requests,
            worker: Some(worker),
        }
    }
    pub fn url(&self) -> String {
        format!("https://localhost:{}", self.port)
    }
    pub fn options(&self) -> ClientOptions {
        ClientOptions {
            private_ca: Some(self.ca.clone()),
            ..Default::default()
        }
    }
    pub fn requests(&self) -> usize {
        self.requests.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Independently assemble RFC 9421 input, so tests can exercise incompatible
/// versions without adding production version overrides or a permissive server.
pub fn resign_version(
    identity: &tasks_cli::remote::signing::SigningIdentity,
    method: &Method,
    uri: &http::Uri,
    headers: &mut http::HeaderMap,
    version: Option<u32>,
) {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use ed25519_dalek::Signer;
    let input = headers["signature-input"].to_str().unwrap();
    let (_, params) = input.split_once(')').unwrap();
    let params = params.to_string();
    let mut names = vec![
        "@method",
        "@path",
        "@query",
        "content-type",
        "content-digest",
        "x-tasks-server-id",
    ];
    if let Some(version) = version {
        headers.insert(
            "x-tasks-protocol-version",
            version.to_string().parse().unwrap(),
        );
        names.push("x-tasks-protocol-version");
    } else {
        headers.remove("x-tasks-protocol-version");
    }
    if headers.contains_key("idempotency-key") {
        names.push("idempotency-key");
    }
    if headers.contains_key("content-length")
        && (tasks_cli::remote::signing::is_upload(method, uri)
            || tasks_cli::remote::signing::is_download(method, uri))
    {
        names.push("content-length");
    }
    let parameters = format!(
        "({}){params}",
        names
            .iter()
            .map(|n| format!("\"{n}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let mut base = format!(
        "\"@method\": {method}\n\"@path\": {}\n\"@query\": ?{}",
        uri.path(),
        uri.query().unwrap_or("")
    );
    for name in &names[3..] {
        base.push_str(&format!(
            "\n\"{name}\": {}",
            headers[*name].to_str().unwrap()
        ));
    }
    base.push_str(&format!("\n\"@signature-params\": {parameters}"));
    headers.insert(
        "signature-input",
        format!("tasks={parameters}").parse().unwrap(),
    );
    headers.insert(
        "signature",
        format!(
            "tasks=:{}:",
            STANDARD.encode(identity.key.sign(base.as_bytes()).to_bytes())
        )
        .parse()
        .unwrap(),
    );
}
impl Drop for TlsFixture {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            if !std::thread::panicking() {
                worker.join().unwrap();
            } else {
                let _ = worker.join();
            }
        }
    }
}
