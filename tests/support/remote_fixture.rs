#![allow(dead_code)]
use super::https::{HttpBackend, Reply, TlsFixture};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::{atomic::AtomicBool, Arc},
};
use tasks_cli::server::{transport::ServiceState, OwnedServer, Registration};
use uuid::Uuid;

enum Backend {
    InProcess(HttpBackend),
    Binary(BinaryServer),
}

impl Backend {
    fn address(&self) -> std::net::SocketAddr {
        match self {
            Self::InProcess(server) => server.address,
            Self::Binary(server) => server.address,
        }
    }
}

struct BinaryServer {
    child: std::process::Child,
    address: std::net::SocketAddr,
}

impl BinaryServer {
    fn new(root: &Path) -> Self {
        use std::{net::TcpStream, time::Duration};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let log = root.join("server.log");
        let mut server = Self {
            child: super::process::command(env!("CARGO_BIN_EXE_tasks-server"))
                .args(["--data-root", root.to_str().unwrap(), "serve", "--listen"])
                .arg(address.to_string())
                .stdout(std::process::Stdio::null())
                .stderr(std::fs::File::create(&log).unwrap())
                .spawn()
                .unwrap(),
            address,
        };
        let deadline = std::time::Instant::now() + super::https::FIXTURE_IO_TIMEOUT;
        loop {
            assert!(
                server.child.try_wait().unwrap().is_none(),
                "tasks-server exited before readiness: {}",
                std::fs::read_to_string(&log).unwrap()
            );
            if TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_ok() {
                return server;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "server readiness deadline"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for BinaryServer {
    fn drop(&mut self) {
        // A kill can race an already-exited child; waiting still reaps it and
        // releases its database handles before the checked fixture root closes.
        let _ = self.child.kill();
        self.child.wait().expect("wait for fixture tasks-server");
    }
}

pub fn run(root: &Path, args: &[&str]) -> Output {
    command(root, args).output().unwrap()
}
pub fn command(root: &Path, args: &[&str]) -> Command {
    let mut command = super::process::command(env!("CARGO_BIN_EXE_tasks"));
    command
        .args(["--data-root", root.to_str().unwrap(), "--format", "json"])
        .args(args)
        .env_remove("TASKS_WINDOWS_EXE")
        .env_remove("TASKS_PROJECT")
        .env_remove("TASKS_DELEGATED")
        .env_remove("TASKS_ORIGIN_CONTEXT")
        .env("TASKS_CLIENT_DIR", root.join("client"));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}
#[track_caller]
pub fn ok(output: Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}
pub struct Fixture {
    pub clients: [PathBuf; 2],
    pub gateway: TlsFixture,
    _backend: Backend,
    pub drop_write: Arc<AtomicBool>,
    pub truncate_export: Arc<AtomicBool>,
    pub substitute_write: Arc<AtomicBool>,
    // Fields drop in declaration order: stop proxies and join the server before
    // removing files held by its persistent catalog and nonce connections.
    pub root: super::temp::TempDir,
}
impl Fixture {
    pub fn backend_address(&self) -> std::net::SocketAddr {
        self._backend.address()
    }

    pub fn new() -> Self {
        Self::with_backend(false)
    }

    /// Exercise the shipped server executable behind the same signed TLS proxy.
    pub fn new_binary() -> Self {
        Self::with_backend(true)
    }

    fn with_backend(binary: bool) -> Self {
        let root = super::temp::TempDir::new();
        let clients = [root.path().join("client-a"), root.path().join("client-b")];
        let server = OwnedServer::initialize(&root.path().join("server")).unwrap();
        let server_id = server.server_id();
        let mut credentials = vec![];
        for client in &clients {
            std::fs::create_dir(client).unwrap();
            let keydir = client.join("client");
            let public = ok(run(
                client,
                &["remote", "keygen", "--directory", keydir.to_str().unwrap()],
            ));
            let registration: Registration = serde_json::from_value(public).unwrap();
            credentials.push(server.register(&registration).unwrap());
        }
        let backend = if binary {
            // Do not retain library-owned connections while the process owns
            // this synthetic store, or while the checked root is removed.
            drop(server);
            Backend::Binary(BinaryServer::new(&root.path().join("server")))
        } else {
            Backend::InProcess(HttpBackend::new(ServiceState::new(server)))
        };
        let drop_write = Arc::new(AtomicBool::new(false));
        let truncate_export = Arc::new(AtomicBool::new(false));
        let substitute_write = Arc::new(AtomicBool::new(false));
        let gateway = TlsFixture::new(
            "localhost",
            false,
            Reply::ProxyWithLoss {
                address: backend.address(),
                drop_next_mutation: drop_write.clone(),
                truncate_next_export: truncate_export.clone(),
                substitute_next_mutation: substitute_write.clone(),
            },
        );
        for (client, credential) in clients.iter().zip(credentials) {
            ok(run(
                client,
                &[
                    "remote",
                    "configure",
                    "--server-url",
                    &gateway.url(),
                    "--server-id",
                    &server_id.to_string(),
                    "--credential-id",
                    &credential.to_string(),
                    "--credential-file",
                    client.join("client/signing-key.pem").to_str().unwrap(),
                    "--private-ca",
                    gateway.options().private_ca.unwrap().to_str().unwrap(),
                ],
            ));
        }
        Self {
            root,
            clients,
            _backend: backend,
            gateway,
            drop_write,
            truncate_export,
            substitute_write,
        }
    }
    pub fn project(&self) -> Uuid {
        let workspace = self.root.path().join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let response = ok(run(
            &self.clients[0],
            &[
                "init",
                "--root",
                workspace.to_str().unwrap(),
                "--key",
                "FIX",
            ],
        ));
        Uuid::parse_str(response["project_id"].as_str().unwrap()).unwrap()
    }
    pub fn body(&self, body: &str) -> PathBuf {
        let path = self.root.path().join("body.txt");
        std::fs::write(&path, body).unwrap();
        path
    }
}
