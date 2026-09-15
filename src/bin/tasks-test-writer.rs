use clap::Parser;
use tasks_cli::model::TaskUpdate;
use tasks_cli::store::Store;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    data_root: std::path::PathBuf,
    #[arg(long)]
    project: String,
    #[arg(long)]
    id: String,
    #[arg(long)]
    expect_version: u64,
    #[arg(long)]
    title: String,
}

fn main() {
    let args = Args::parse();
    let result = (|| {
        let mut store = Store::open_rw(&args.data_root, &args.project)?;
        store.update_task(
            tasks_cli::model::parse_task_id(&args.id).map_err(tasks_cli::AppError::Validation)?,
            args.expect_version,
            TaskUpdate {
                title: Some(args.title),
                ..TaskUpdate::default()
            },
        )?;
        Ok::<(), tasks_cli::AppError>(())
    })();
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(error.exit_code());
    }
}
