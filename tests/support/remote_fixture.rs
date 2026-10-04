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
pub fn ok(output: Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}
pub struct Fixture {
    pub root: tempfile::TempDir,
    pub clients: [PathBuf; 2],
    _backend: HttpBackend,
    pub gateway: TlsFixture,
    pub drop_write: Arc<AtomicBool>,
    pub truncate_export: Arc<AtomicBool>,
    pub substitute_write: Arc<AtomicBool>,
}
impl Fixture {
    pub fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
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
        let backend = HttpBackend::new(ServiceState::new(server));
        let drop_write = Arc::new(AtomicBool::new(false));
        let truncate_export = Arc::new(AtomicBool::new(false));
        let substitute_write = Arc::new(AtomicBool::new(false));
        let gateway = TlsFixture::new(
            "localhost",
            false,
            Reply::ProxyWithLoss {
                address: backend.address,
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
