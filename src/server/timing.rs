//! Request-local measurements on synchronous workers. No request data or global
//! aggregation, and no clock reads when called outside a captured worker.
use serde::Serialize;
use std::{cell::Cell, time::Instant};

#[derive(Clone, Copy, Default, Serialize)]
pub(super) struct Timings {
    pub auth_ms: f64,
    pub credential_ms: f64,
    pub signature_ms: f64,
    pub nonce_ms: f64,
    pub nonce_open_ms: f64,
    pub nonce_sql_ms: f64,
    pub nonce_commit_ms: f64,
    pub nonce_close_ms: f64,
    pub open_ms: f64,
    pub schema_ms: f64,
    pub handler_ms: f64,
    pub query_ms: f64,
    pub encode_ms: f64,
    pub queue_ms: f64,
}

thread_local! {
    static ACTIVE: Cell<Option<Timings>> = const { Cell::new(None) };
}

pub(crate) enum Phase {
    Auth,
    Credential,
    Signature,
    Nonce,
    NonceOpen,
    NonceSql,
    NonceCommit,
    NonceClose,
    Open,
    Schema,
    Handler,
    Query,
    Encode,
}
pub(crate) struct Timer {
    phase: Phase,
    started: Option<Instant>,
}
impl Phase {
    pub(crate) fn start(self) -> Timer {
        Timer {
            phase: self,
            started: ACTIVE.with(|active| active.get().map(|_| Instant::now())),
        }
    }
}
impl Drop for Timer {
    fn drop(&mut self) {
        let Some(started) = self.started else { return };
        ACTIVE.with(|active| {
            if let Some(mut timings) = active.get() {
                let field = match self.phase {
                    Phase::Auth => &mut timings.auth_ms,
                    Phase::Credential => &mut timings.credential_ms,
                    Phase::Signature => &mut timings.signature_ms,
                    Phase::Nonce => &mut timings.nonce_ms,
                    Phase::NonceOpen => &mut timings.nonce_open_ms,
                    Phase::NonceSql => &mut timings.nonce_sql_ms,
                    Phase::NonceCommit => &mut timings.nonce_commit_ms,
                    Phase::NonceClose => &mut timings.nonce_close_ms,
                    Phase::Open => &mut timings.open_ms,
                    Phase::Schema => &mut timings.schema_ms,
                    Phase::Handler => &mut timings.handler_ms,
                    Phase::Query => &mut timings.query_ms,
                    Phase::Encode => &mut timings.encode_ms,
                };
                *field += started.elapsed().as_secs_f64() * 1000.0;
                active.set(Some(timings));
            }
        });
    }
}

struct Restore(Option<Timings>);
impl Drop for Restore {
    fn drop(&mut self) {
        ACTIVE.with(|active| active.set(self.0));
    }
}
pub(super) fn capture<T>(queued: Instant, phase: Phase, work: impl FnOnce() -> T) -> (T, Timings) {
    let previous = ACTIVE.with(|active| {
        active.replace(Some(Timings {
            queue_ms: queued.elapsed().as_secs_f64() * 1000.0,
            ..Default::default()
        }))
    });
    let _restore = Restore(previous);
    let timer = phase.start();
    let result = work();
    drop(timer);
    (
        result,
        ACTIVE.with(|active| active.get().unwrap_or_default()),
    )
}

impl Timings {
    pub(super) fn add(&mut self, other: Self) {
        self.auth_ms += other.auth_ms;
        self.credential_ms += other.credential_ms;
        self.signature_ms += other.signature_ms;
        self.nonce_ms += other.nonce_ms;
        self.nonce_open_ms += other.nonce_open_ms;
        self.nonce_sql_ms += other.nonce_sql_ms;
        self.nonce_commit_ms += other.nonce_commit_ms;
        self.nonce_close_ms += other.nonce_close_ms;
        self.open_ms += other.open_ms;
        self.schema_ms += other.schema_ms;
        self.handler_ms += other.handler_ms;
        self.query_ms += other.query_ms;
        self.encode_ms += other.encode_ms;
        self.queue_ms += other.queue_ms;
    }
}
