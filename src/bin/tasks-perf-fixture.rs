//! Seeds deterministic performance fixtures for `viewer/tool/measure.ps1`.
//!
//! The profiles match viewer/spec.md section 10: 100 projects with 1000 tasks
//! each, one project with 100000 tasks (one 1 MiB body and 1000 dependency
//! edges), 1000 empty projects for the project-virtualization measurement and
//! a tiny probe profile that proves the recorded seed reproduces the same
//! logical content. The generator never reads the clock or the environment;
//! every choice comes from the SplitMix64 stream seeded by `--seed`, and the
//! printed digest covers the canonical content stream.

use clap::{Parser, ValueEnum};
use rusqlite::{params, Transaction, TransactionBehavior};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use tasks_cli::registry;
use tasks_cli::store::Store;
use tasks_cli::AppError;

#[derive(Parser, Debug)]
#[command(
    name = "tasks-perf-fixture",
    about = "Seed deterministic viewer performance fixtures (test support)."
)]
struct Args {
    /// Data root that receives the registry and the per-project databases.
    #[arg(long)]
    data_root: PathBuf,

    /// Directory that receives one root directory per project.
    #[arg(long)]
    roots_root: PathBuf,

    #[arg(long, value_enum)]
    profile: Profile,

    /// Recorded seed; the same seed reproduces the same logical content.
    #[arg(long, default_value_t = 20_260_922)]
    seed: u64,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq, ValueEnum)]
enum Profile {
    /// Three projects with five tasks each (cheap determinism probe).
    #[value(name = "perf-probe")]
    PerfProbe,
    /// 100 projects with 1000 tasks each.
    #[value(name = "perf-100x1000")]
    Perf100x1000,
    /// One project with 100000 tasks, one 1 MiB body and 1000 dependencies.
    #[value(name = "perf-100k")]
    Perf100k,
    /// 1000 projects with no tasks.
    #[value(name = "perf-empty-1000")]
    PerfEmpty1000,
}

impl Profile {
    fn as_str(self) -> &'static str {
        match self {
            Profile::PerfProbe => "perf-probe",
            Profile::Perf100x1000 => "perf-100x1000",
            Profile::Perf100k => "perf-100k",
            Profile::PerfEmpty1000 => "perf-empty-1000",
        }
    }
}

const STATUSES: [&str; 6] = [
    "draft",
    "todo",
    "in-progress",
    "blocked",
    "done",
    "cancelled",
];
const PRIORITIES: [&str; 4] = ["P0", "P1", "P2", "P3"];
const LABELS: [&str; 8] = [
    "perf",
    "alpha",
    "beta",
    "ops",
    "ui",
    "rust",
    "za\u{17c}\u{f3}\u{142}\u{107}",
    "docs",
];
const TITLE_SUFFIXES: [&str; 6] = [
    "za\u{17c}\u{f3}\u{142}\u{107} g\u{119}\u{15b}l\u{105} ja\u{17a}\u{144}",
    "\u{6771}\u{4eac} task",
    "\u{645}\u{647}\u{645}\u{629}",
    "emoji \u{1F680} ship",
    "'quoted' %_ literal",
    "\u{dc}ber task",
];
const BODY_SUFFIXES: [&str; 4] = [
    " koniec \u{17c}\u{f3}\u{142}\u{107}",
    " \u{6771}\u{4eac}",
    " \u{645}\u{647}\u{645}\u{629}",
    " %_ literal",
];
const BODY_FILLER: &str = "perf body filler text with repeated sort values and labels ";
const BODY_SIZE: usize = 2048;
const BIG_BODY_SIZE: usize = 1024 * 1024;
const BASE_MS: i64 = 1_770_000_000_000;

struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

struct ProjectSpec {
    name: String,
    tasks: usize,
    big_body: bool,
    dependencies: usize,
}

struct DependencyPlan {
    last_id: usize,
    target: usize,
    stride: u64,
}

fn build_body(id: usize, seed: u64, big: bool) -> String {
    let suffix = BODY_SUFFIXES[(id + seed as usize) % BODY_SUFFIXES.len()];
    if big {
        let mut body = String::with_capacity(BIG_BODY_SIZE + suffix.len());
        body.push_str("big body ");
        body.push_str(&id.to_string());
        body.push(' ');
        while body.len() < BIG_BODY_SIZE {
            body.push_str(BODY_FILLER);
        }
        body.truncate(BIG_BODY_SIZE);
        body.push_str(suffix);
        return body;
    }
    let mut body = String::with_capacity(BODY_SIZE);
    body.push_str("body ");
    body.push_str(&id.to_string());
    body.push(' ');
    if id.is_multiple_of(5000) {
        body.push_str("needle-%_ literal marker ");
    }
    let ascii_target = BODY_SIZE - suffix.len();
    while body.len() < ascii_target {
        body.push_str(BODY_FILLER);
    }
    body.truncate(ascii_target);
    body.push_str(suffix);
    body
}

fn labels_for(id: usize, seed: u64) -> Vec<String> {
    let mut set = BTreeSet::new();
    set.insert(LABELS[(id + seed as usize) % LABELS.len()].to_string());
    if id.is_multiple_of(10) {
        set.insert("perf".to_string());
    }
    if id.is_multiple_of(37) {
        set.insert("needs-human".to_string());
    }
    set.into_iter().collect()
}

fn seed_dependencies(
    tx: &Transaction<'_>,
    plan: &DependencyPlan,
    hasher: &mut Sha256,
) -> Result<usize, AppError> {
    let mut stmt = tx.prepare_cached(
        "INSERT OR IGNORE INTO dependencies(task_id,depends_on_id) VALUES (?1,?2)",
    )?;
    let mut inserted = 0usize;
    let mut step: u64 = 0;
    let cap = plan.target as u64 * 64 + 1024;
    while inserted < plan.target && step < cap {
        let task = 2 + ((step.wrapping_mul(plan.stride) as usize) % (plan.last_id - 1));
        let dep = 1 + ((step.wrapping_mul(31) as usize) % (task - 1));
        let changed = stmt.execute(params![task as i64, dep as i64])?;
        if changed == 1 {
            hasher.update(b"dep\n");
            hasher.update((task as u64).to_le_bytes());
            hasher.update((dep as u64).to_le_bytes());
            inserted += 1;
        }
        step += 1;
    }
    if inserted < plan.target {
        return Err(AppError::usage(format!(
            "the fixture dependency plan placed {inserted} of {} edges; choose another seed",
            plan.target
        )));
    }
    Ok(inserted)
}

fn seed_project(
    data_root: &Path,
    roots_root: &Path,
    spec: &ProjectSpec,
    seed: u64,
    stride: u64,
    hasher: &mut Sha256,
) -> Result<(), AppError> {
    let root_dir = roots_root.join(&spec.name);
    std::fs::create_dir_all(&root_dir)
        .map_err(|error| AppError::io_path("create the fixture project root", &root_dir, error))?;
    let info = registry::init_root(data_root, &root_dir, None)?;
    let mut store = Store::open_rw(data_root, &info.project_id.to_string())?;
    let tx = store
        .conn
        .transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut dependency_count = 0usize;
    {
        let mut task_stmt = tx.prepare_cached(
            "INSERT INTO tasks(id,title,body,status,version,created_ms,updated_ms,priority)
             VALUES (?1,?2,?3,?4,1,?5,?5,?6)",
        )?;
        let mut label_stmt =
            tx.prepare_cached("INSERT OR IGNORE INTO task_labels(task_id,label) VALUES (?1,?2)")?;
        for id in 1..=spec.tasks {
            let title = format!(
                "perf task {id:06} {}",
                TITLE_SUFFIXES[(id + seed as usize) % TITLE_SUFFIXES.len()]
            );
            let status = STATUSES[(id + seed as usize) % STATUSES.len()];
            let priority = PRIORITIES[(id * 3 + seed as usize) % PRIORITIES.len()];
            let body = build_body(id, seed, spec.big_body && id == 1);
            let stamp = BASE_MS + (((id + seed as usize) % 97) as i64) * 1_000;
            task_stmt.execute(params![id as i64, title, body, status, stamp, priority])?;
            hasher.update(b"task\n");
            hasher.update((id as u64).to_le_bytes());
            hasher.update(title.as_bytes());
            hasher.update(b"\n");
            hasher.update(status.as_bytes());
            hasher.update(b"\n");
            hasher.update(priority.as_bytes());
            hasher.update(b"\n");
            hasher.update(stamp.to_le_bytes());
            hasher.update(body.as_bytes());
            hasher.update(b"\n");
            for label in labels_for(id, seed) {
                label_stmt.execute(params![id as i64, label.as_str()])?;
                hasher.update(b"label\n");
                hasher.update((id as u64).to_le_bytes());
                hasher.update(label.as_bytes());
            }
        }
        if spec.dependencies > 0 {
            dependency_count = seed_dependencies(
                &tx,
                &DependencyPlan {
                    last_id: spec.tasks,
                    target: spec.dependencies,
                    stride,
                },
                hasher,
            )?;
        }
    }
    tx.execute(
        "UPDATE project SET next_task_number=?1",
        [spec.tasks as i64 + 1],
    )?;
    tx.commit()?;
    eprintln!(
        "seeded {}: {} tasks, {} dependency edges",
        spec.name, spec.tasks, dependency_count
    );
    Ok(())
}

fn seed_empty_projects(
    data_root: &Path,
    roots_root: &Path,
    count: usize,
    hasher: &mut Sha256,
) -> Result<(), AppError> {
    for index in 0..count {
        let name = format!("perf-empty-{index:04}");
        let root_dir = roots_root.join(&name);
        std::fs::create_dir_all(&root_dir).map_err(|error| {
            AppError::io_path("create the fixture project root", &root_dir, error)
        })?;
        registry::init_root(data_root, &root_dir, None)?;
        hasher.update(b"project\n");
        hasher.update(name.as_bytes());
        if index % 100 == 99 || index + 1 == count {
            eprintln!("seeded empty project {}/{}", index + 1, count);
        }
    }
    Ok(())
}

fn run(args: Args) -> Result<(), AppError> {
    let mut rng = SplitMix64::new(args.seed);
    let stride = 2 * (rng.next_u64() % 500) + 3;
    let mut hasher = Sha256::new();
    let (projects, tasks, dependencies) = match args.profile {
        Profile::PerfProbe => {
            let mut total = 0usize;
            let mut edges = 0usize;
            for index in 0..3u64 {
                let spec = ProjectSpec {
                    name: format!("perf-probe-{index:02}"),
                    tasks: 5,
                    big_body: false,
                    dependencies: 2,
                };
                seed_project(
                    &args.data_root,
                    &args.roots_root,
                    &spec,
                    args.seed.wrapping_add(index),
                    stride,
                    &mut hasher,
                )?;
                total += spec.tasks;
                edges += spec.dependencies;
            }
            (3usize, total, edges)
        }
        Profile::Perf100x1000 => {
            for index in 0..100u64 {
                let spec = ProjectSpec {
                    name: format!("perf-project-{index:03}"),
                    tasks: 1_000,
                    big_body: index == 0,
                    dependencies: 10,
                };
                seed_project(
                    &args.data_root,
                    &args.roots_root,
                    &spec,
                    args.seed.wrapping_add(index),
                    stride,
                    &mut hasher,
                )?;
            }
            (100usize, 100_000usize, 1_000usize)
        }
        Profile::Perf100k => {
            let spec = ProjectSpec {
                name: "perf-huge".to_string(),
                tasks: 100_000,
                big_body: true,
                dependencies: 1_000,
            };
            seed_project(
                &args.data_root,
                &args.roots_root,
                &spec,
                args.seed,
                stride,
                &mut hasher,
            )?;
            (1usize, 100_000usize, 1_000usize)
        }
        Profile::PerfEmpty1000 => {
            seed_empty_projects(&args.data_root, &args.roots_root, 1_000, &mut hasher)?;
            (1_000usize, 0usize, 0usize)
        }
    };
    let digest = hasher.finalize();
    let digest_hex = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let payload = serde_json::json!({
        "profile": args.profile.as_str(),
        "seed": args.seed,
        "projects": projects,
        "tasks": tasks,
        "dependencies": dependencies,
        "digest": digest_hex,
    });
    println!("{payload}");
    Ok(())
}

fn main() {
    let args = Args::parse();
    if let Err(error) = run(args) {
        eprintln!("{error}");
        std::process::exit(error.exit_code());
    }
}
