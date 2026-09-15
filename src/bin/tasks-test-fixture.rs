use clap::Parser;
use rusqlite::TransactionBehavior;
use tasks_cli::store::Store;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    data_root: std::path::PathBuf,
    #[arg(long)]
    project: String,
    #[arg(long, default_value_t = 10_000)]
    tasks: u64,
    #[arg(long, default_value_t = 50_000)]
    events: u64,
}

fn run(args: Args) -> Result<(), tasks_cli::AppError> {
    let mut store = Store::open_rw(&args.data_root, &args.project)?;
    let tx = store
        .conn
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let body = "fixture body ".repeat(160);
    for id in 1..=args.tasks {
        tx.execute(
            "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms)
             VALUES (?1,?2,?3,'backlog',1,?4,?4)",
            rusqlite::params![id as i64, format!("Performance task {id}"), body, id as i64],
        )?;
    }
    for index in 0..args.events {
        let task_id = (index % args.tasks.max(1)) + 1;
        tx.execute(
            "INSERT INTO events(task_id,entity_type,operation,resulting_version,created_ms,snapshot_json)
             VALUES (?1,'task','fixture',1,?2,'{}')",
            rusqlite::params![task_id as i64, index as i64],
        )?;
    }
    tx.execute(
        "UPDATE project SET next_task_number=?1",
        [args.tasks as i64 + 1],
    )?;
    tx.commit()?;
    Ok(())
}

fn main() {
    if let Err(error) = run(Args::parse()) {
        eprintln!("{error}");
        std::process::exit(error.exit_code());
    }
}
