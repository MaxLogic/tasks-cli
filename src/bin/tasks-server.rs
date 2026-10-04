use clap::{Parser, Subcommand};
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use tasks_cli::server::{maintenance, transport::ServiceState, OwnedServer, Registration};
use uuid::Uuid;

#[derive(Parser)]
#[command(about = "Private task service; terminate HTTPS at a trusted reverse proxy")]
struct Cli {
    #[arg(long)]
    data_root: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long, default_value = "0.0.0.0:8080")]
        listen: SocketAddr,
    },
    Admin {
        #[command(subcommand)]
        command: Admin,
    },
}
#[derive(Subcommand)]
enum Admin {
    Init,
    Migrate,
    Info,
    Register {
        #[arg(long)]
        registration_file: PathBuf,
    },
    Revoke {
        credential_id: Uuid,
    },
    Backup {
        #[arg(long)]
        out: PathBuf,
    },
    Restore {
        #[arg(long)]
        backup: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    ImportProject {
        #[arg(long)]
        database: PathBuf,
        #[arg(long)]
        name: String,
    },
}
fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("{error}");
        std::process::exit(5);
    }
}
fn run(cli: Cli) -> Result<(), Box<dyn std::error::Error>> {
    match cli.command {
        Command::Admin { command } => {
            if matches!(command, Admin::Migrate) {
                let backup = OwnedServer::migrate(&cli.data_root)?;
                println!(
                    "{}",
                    serde_json::json!({"schema_version":2,"backup_path":backup})
                );
                return Ok(());
            }
            if matches!(command, Admin::Init) {
                let server = OwnedServer::initialize(&cli.data_root)?;
                println!("{}", serde_json::json!({"server_id":server.server_id()}));
                return Ok(());
            }
            if let Admin::Restore { backup, out } = command {
                let result = maintenance::restore(&backup, &out)?;
                println!("{}", serde_json::to_string(&result)?);
                return Ok(());
            }
            let server = OwnedServer::open(&cli.data_root)?;
            match command {
                Admin::Info => println!("{}", serde_json::json!({"server_id":server.server_id()})),
                Admin::Register { registration_file } => {
                    use std::io::Read;
                    let mut bytes = Vec::new();
                    std::fs::File::open(registration_file)?
                        .take(16_385)
                        .read_to_end(&mut bytes)?;
                    if bytes.len() > 16_384 {
                        return Err("registration file exceeds 16 KiB".into());
                    }
                    let registration: Registration = serde_json::from_slice(&bytes)
                        .map_err(|_| "invalid enrollment JSON; export a public registration from client setup")?;
                    let credential = server.register(&registration)?;
                    println!(
                        "{}",
                        serde_json::json!({"server_id":server.server_id(),"credential_id":credential})
                    );
                }
                Admin::Revoke { credential_id } => {
                    server.revoke(credential_id)?;
                    println!(
                        "{}",
                        serde_json::json!({"credential_id":credential_id,"revoked":true})
                    );
                }
                Admin::Backup { out } => {
                    println!(
                        "{}",
                        serde_json::to_string(&maintenance::backup(&server, &out)?)?
                    );
                }
                Admin::ImportProject { database, name } => {
                    println!(
                        "{}",
                        serde_json::to_string(&maintenance::import_project(
                            &server, &database, &name
                        )?)?
                    );
                }
                Admin::Init | Admin::Migrate | Admin::Restore { .. } => {}
            }
        }
        Command::Serve { listen } => {
            let server = OwnedServer::open(&cli.data_root)?;
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .max_blocking_threads(8)
                .enable_all()
                .build()?;
            runtime.block_on(async move {
                let state=ServiceState::new(server);
                let listener=tokio::net::TcpListener::bind(listen).await?;
                let (stop_send,stop_receive)=tokio::sync::oneshot::channel::<()>();
                let app=state.router();
                let mut service=tokio::spawn(async move {axum::serve(listener,app).with_graceful_shutdown(async {let _=stop_receive.await;}).await});
                tokio::select! {
                    result=&mut service => { result??; return Ok::<_,Box<dyn std::error::Error>>(()); },
                    result=shutdown_signal()=>{ result?; },
                }
                state.begin_shutdown();
                let _=stop_send.send(());
                match tokio::time::timeout(Duration::from_secs(30),service).await {
                    Ok(result)=>{result??;Ok(())},
                    Err(_)=> {
                        // Exit terminates this service's own outstanding workers. SQLite
                        // recovery, rather than an assumed rollback, owns write outcome.
                        eprintln!("shutdown deadline exceeded; inspect pending request outcomes after restart");
                        std::process::exit(5);
                    },
                }
            })?;
        }
    }
    Ok(())
}
async fn shutdown_signal() -> Result<(), std::io::Error> {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! { result=tokio::signal::ctrl_c()=>result, _=terminate.recv()=>Ok(()) }
    }
    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c().await
    }
}
