#![cfg(feature = "server")]
use axum::http::Method;
use ed25519_dalek::SigningKey;
use tasks_cli::remote::https::{ClientError, ClientOptions, HttpsClient};
use tasks_cli::server::signatures::SigningIdentity;
use uuid::Uuid;

fn identity() -> SigningIdentity {
    SigningIdentity {
        credential_id: Uuid::new_v4(),
        server_id: Uuid::new_v4(),
        key: SigningKey::from_bytes(&[5; 32]),
    }
}

#[test]
fn configuration_rejects_http_credentials_fragments_and_invalid_timeouts() {
    for url in [
        "http://127.0.0.1",
        "https://user:secret@localhost",
        "https://localhost/path",
        "https://localhost?token=secret",
        "https://localhost#fragment",
    ] {
        assert!(
            matches!(
                HttpsClient::new(url, ClientOptions::default(), identity()),
                Err(ClientError::Configuration(_))
            ),
            "{url}"
        );
    }
    assert!(HttpsClient::new(
        "https://localhost",
        ClientOptions {
            request_timeout: std::time::Duration::ZERO,
            ..Default::default()
        },
        identity()
    )
    .is_err());
}

#[test]
fn trusted_ca_accepts_valid_host_and_rejects_untrusted_wrong_host_and_expired_certificates() {
    let valid = TlsFixture::new("localhost", false, Reply::Ok);
    let client = HttpsClient::new(&valid.url(), valid.options(), identity()).unwrap();
    let response = client.send(Method::GET, "/v1/info", b"", None).unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.body, b"{\"fixture\":true}");
    assert!(matches!(
        HttpsClient::new(&valid.url(), ClientOptions::default(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(valid.requests(), 1);
    let wrong = TlsFixture::new("other.invalid", false, Reply::Ok);
    assert!(matches!(
        HttpsClient::new(&wrong.url(), wrong.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(wrong.requests(), 0);
    let expired = TlsFixture::new("localhost", true, Reply::Ok);
    assert!(matches!(
        HttpsClient::new(&expired.url(), expired.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::Transport)
    ));
    assert_eq!(expired.requests(), 0);
}

#[test]
fn redirects_never_forward_signatures_and_responses_are_bounded() {
    let target = TlsFixture::new("localhost", false, Reply::Ok);
    let redirect = TlsFixture::new("localhost", false, Reply::Redirect(target.url()));
    let response = HttpsClient::new(&redirect.url(), redirect.options(), identity())
        .unwrap()
        .send(Method::GET, "/v1/info", b"", None);
    assert!(matches!(response, Err(ClientError::Redirect)));
    assert_eq!(target.requests(), 0);
    let large = TlsFixture::new("localhost", false, Reply::Large);
    assert!(matches!(
        HttpsClient::new(&large.url(), large.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::ResponseLimit)
    ));
    let streamed = TlsFixture::new("localhost", false, Reply::LargeStream);
    assert!(matches!(
        HttpsClient::new(&streamed.url(), streamed.options(), identity())
            .unwrap()
            .send(Method::GET, "/v1/info", b"", None),
        Err(ClientError::ResponseLimit)
    ));
}

#[test]
fn request_timeout_does_not_resend_an_admitted_write() {
    let fixture = TlsFixture::new("localhost", false, Reply::Stall);
    let mut options = fixture.options();
    options.request_timeout = std::time::Duration::from_millis(500);
    let client = HttpsClient::new(&fixture.url(), options, identity()).unwrap();
    let started = std::time::Instant::now();
    assert!(matches!(
        client.send(Method::POST, "/v1/projects", b"{}", Some(Uuid::new_v4())),
        Err(ClientError::Transport)
    ));
    assert!(started.elapsed() < std::time::Duration::from_millis(1500));
    assert_eq!(fixture.requests(), 1);
}

#[test]
fn signed_https_round_trip_preserves_encoded_components_and_registered_destination() {
    use tasks_cli::server::{OwnedServer, Registration};
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let mut signer = identity();
    signer.server_id = server.server_id();
    signer.credential_id = server
        .register(&Registration {
            public_key: signer.key.verifying_key().to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "fixture".into(),
        })
        .unwrap();
    let fixture = TlsFixture::new("localhost", false, Reply::Authenticate(server));
    let client = HttpsClient::new(&fixture.url(), fixture.options(), signer).unwrap();
    let receipt = Uuid::new_v4();
    let response = client
        .send(
            Method::POST,
            "/v1/projects/abc/tasks?encoded=%2F&empty=",
            b"exact private body",
            Some(receipt),
        )
        .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(fixture.requests(), 1);
    assert!(matches!(
        client.send(Method::GET, "/v1/../other", b"", None),
        Err(ClientError::Configuration(_))
    ));
}

#[test]
fn tls_gateway_forwards_signatures_to_the_actual_private_rust_listener() {
    use tasks_cli::server::{transport::ServiceState, OwnedServer, Registration};
    let root = tempfile::tempdir().unwrap();
    let server = OwnedServer::initialize(root.path()).unwrap();
    let mut signer = identity();
    signer.server_id = server.server_id();
    signer.credential_id = server
        .register(&Registration {
            public_key: signer.key.verifying_key().to_bytes(),
            actor_id: "owner".into(),
            actor_name: "Owner".into(),
            installation_id: Uuid::new_v4(),
            installation_name: "fixture".into(),
        })
        .unwrap();
    let backend = HttpBackend::new(ServiceState::new(server));
    let gateway = TlsFixture::new("localhost", false, Reply::Proxy(backend.address));
    let client = HttpsClient::new(&gateway.url(), gateway.options(), signer).unwrap();
    let info = client
        .send(Method::GET, "/v1/info?encoded=%2F", b"", None)
        .unwrap();
    assert_eq!(info.status, 200);
    let value: serde_json::Value = serde_json::from_slice(&info.body).unwrap();
    assert_eq!(value["ready"], false);
    let target = format!("/v1/projects/{}/tasks?encoded=%2F", Uuid::new_v4());
    let write = client
        .send(
            Method::POST,
            &target,
            b"private exact payload",
            Some(Uuid::new_v4()),
        )
        .unwrap();
    // Authentication/body validation succeeded, and application dispatch (not
    // implemented yet) explicitly refused the route. 401 would expose damage.
    assert_eq!(write.status, 404);
}

struct HttpBackend {
    address: std::net::SocketAddr,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl HttpBackend {
    fn new(state: tasks_cli::server::transport::ServiceState) -> Self {
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
                    axum::serve(listener, state.router())
                        .with_graceful_shutdown(async {
                            let _ = stopped.await;
                        })
                        .await
                        .unwrap();
                });
        });
        Self {
            address: address
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap(),
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

enum Reply {
    Ok,
    Redirect(String),
    Large,
    LargeStream,
    Stall,
    Authenticate(tasks_cli::server::OwnedServer),
    Proxy(std::net::SocketAddr),
}
struct TlsFixture {
    _root: tempfile::TempDir,
    ca: std::path::PathBuf,
    port: u16,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    requests: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl TlsFixture {
    fn new(host: &str, expired: bool, reply: Reply) -> Self {
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
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(std::time::Duration::from_secs(3)))
                    .unwrap();
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
                let uri = first[1].parse().unwrap();
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
                assert!(length <= 8 * 1024 * 1024);
                let mut body = vec![0; length];
                stream.read_exact(&mut body).unwrap();
                match &reply {
                    Reply::Stall => {
                        std::thread::sleep(std::time::Duration::from_secs(2));
                    }
                    Reply::LargeStream => {
                        write!(stream, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").unwrap();
                        // The client deliberately closes after the bounded read.
                        let _ =
                            std::io::copy(&mut std::io::repeat(b'x').take(8388609), &mut stream);
                    }
                    Reply::Proxy(address) => {
                        let mut upstream = std::net::TcpStream::connect(address).unwrap();
                        upstream
                            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                            .unwrap();
                        upstream
                            .set_write_timeout(Some(std::time::Duration::from_secs(3)))
                            .unwrap();
                        write!(upstream, "{method} {uri} HTTP/1.1\r\nConnection: close\r\n")
                            .unwrap();
                        for (name, value) in &headers {
                            if name != "connection" {
                                write!(upstream, "{name}: {}\r\n", value.to_str().unwrap())
                                    .unwrap();
                            }
                        }
                        upstream.write_all(b"\r\n").unwrap();
                        upstream.write_all(&body).unwrap();
                        let mut response = Vec::new();
                        upstream
                            .take(8 * 1024 * 1024 + 16384)
                            .read_to_end(&mut response)
                            .unwrap();
                        stream.write_all(&response).unwrap();
                    }
                    Reply::Redirect(location) => {
                        write!(stream,"HTTP/1.1 302 Found\r\nLocation: {location}/v1/info\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                    }
                    Reply::Large => {
                        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\nConnection: close\r\n\r\n").unwrap();
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
    fn url(&self) -> String {
        format!("https://localhost:{}", self.port)
    }
    fn options(&self) -> ClientOptions {
        ClientOptions {
            private_ca: Some(self.ca.clone()),
            ..Default::default()
        }
    }
    fn requests(&self) -> usize {
        self.requests.load(std::sync::atomic::Ordering::SeqCst)
    }
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
