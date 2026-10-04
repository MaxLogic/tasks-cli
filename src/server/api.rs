//! Typed API operations over the same store used by local commands.
use super::{
    receipts::{self, ReceiptIdentity, ReceiptResponse},
    signatures::AuthenticatedRequest,
    OwnedServer, ServiceError,
};
use crate::{
    model::{Attribution, ListCursor},
    output::{CommandPayload, Envelope, ShowPayload},
    store::Store,
    AppError,
};
use axum::http::{Method, Uri};
use rusqlite::params;
use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub use crate::remote::protocol::*;

pub const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
pub(crate) fn bounded_json(value: &impl Serialize) -> Result<Vec<u8>, AppError> {
    struct Bounded {
        bytes: Vec<u8>,
        exceeded: bool,
    }
    impl std::io::Write for Bounded {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > MAX_RESPONSE_BYTES.saturating_sub(self.bytes.len()) {
                self.exceeded = true;
                return Err(std::io::Error::other("response byte budget"));
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut out = Bounded {
        bytes: vec![],
        exceeded: false,
    };
    if let Err(error) = serde_json::to_writer(&mut out, value) {
        if out.exceeded {
            return Err(AppError::ResponseLimit("response exceeds 16 MiB. Split the read into smaller requests or use streamed export".into()));
        }
        return Err(error.into());
    }
    Ok(out.bytes)
}
fn output(store: &Store, data: CommandPayload) -> Result<Value, AppError> {
    output_with_project(Some(store), data)
}

fn output_with_project(store: Option<&Store>, data: CommandPayload) -> Result<Value, AppError> {
    let envelope = Envelope {
        schema_version: 1,
        project_id: store.map(|store| store.project_id.to_string()),
        id_key: store.and_then(|store| store.project_key.clone()),
        data,
    };
    let json = bounded_json(&envelope)?;
    let text = envelope.text();
    if text.len() > MAX_RESPONSE_BYTES {
        return Err(AppError::ResponseLimit(
            "text response exceeds 16 MiB. Split the read".into(),
        ));
    }
    let bytes = bounded_json(&ApiOutput {
        output: serde_json::from_slice(&json)?,
        text,
        catalog_name: None,
    })?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn parse<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, AppError> {
    serde_json::from_slice(bytes)
        .map_err(|_| AppError::validation("invalid API JSON or unsupported fields"))
}
fn response(result: Result<Value, AppError>) -> Result<ReceiptResponse, ServiceError> {
    match result {
        Ok(body) => Ok(ReceiptResponse {
            status: 200,
            body,
            receipt: None,
        }),
        Err(error) => match receipts::refusal(&error) {
            Some(response) => Ok(response),
            None => Err(error.into()),
        },
    }
}
fn not_found() -> AppError {
    AppError::NotFound("unknown server project".into())
}
fn catalogued(server: &OwnedServer, id: Uuid) -> Result<bool, ServiceError> {
    Ok(server.connect()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM projects WHERE project_id=?1)",
        [id.to_string()],
        |r| r.get(0),
    )?)
}
fn identity(
    auth: &AuthenticatedRequest,
    method: &Method,
    uri: &Uri,
) -> Result<ReceiptIdentity, ServiceError> {
    Ok(ReceiptIdentity {
        request_id: auth
            .idempotency_key
            .ok_or(ServiceError::Validation("mutation requires a request UUID"))?,
        actor_id: auth.registration.actor_id.clone(),
        installation_id: auth.registration.installation_id,
        route: format!("{method} {uri}"),
    })
}
fn canonical(bytes: &[u8]) -> Result<Vec<u8>, AppError> {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(value) => Ok(serde_json::to_vec(&value)?),
        Err(_) => Ok(bytes.to_vec()),
    }
}
fn context(
    auth: &AuthenticatedRequest,
    mut attribution: Attribution,
) -> Result<Attribution, AppError> {
    auth.apply_identity(&mut attribution);
    attribution.validated_json()?;
    Ok(attribution)
}
fn unique_key(server: &OwnedServer, project: Uuid, key: &str) -> Result<(), AppError> {
    if let Some(owner) = crate::keys::find_owner(server.data_root(), key)? {
        if owner.project_id != project {
            return Err(AppError::Conflict(format!(
                "project key {key} is already used by {}",
                owner.project_id
            )));
        }
    }
    Ok(())
}

fn query(server: &OwnedServer, store: &mut Store, request: ReadRequest) -> Result<Value, AppError> {
    let data = match request {
        ReadRequest::List {
            status,
            after,
            limit,
            label,
            open,
            needs_human,
        } => {
            if open && needs_human {
                return Err(AppError::validation(
                    "open and needs_human cannot be combined",
                ));
            }
            let after = after
                .map(|v| v.parse::<ListCursor>().map_err(AppError::validation))
                .transpose()?;
            let page = store.select_tasks(
                status.as_ref().map(ToString::to_string).as_deref(),
                after,
                limit,
                label.as_deref(),
                open,
                needs_human,
            )?;
            CommandPayload::List {
                items: page.items,
                has_more: page.has_more,
                next_after: page.next_after,
            }
        }
        ReadRequest::Unlocks { offset, limit } => {
            let page = store.unlocks(offset, limit)?;
            CommandPayload::Unlocks {
                items: page.items,
                has_more: page.has_more,
                next_offset: page.next_after,
            }
        }
        ReadRequest::Search {
            text,
            ranked,
            prefix,
            label,
            after,
            offset,
            limit,
        } => {
            if ranked && after.is_some() || !ranked && (prefix || offset != 0) {
                return Err(AppError::validation(
                    "invalid search cursor or prefix combination",
                ));
            }
            if ranked {
                let page = store.search_ranked(&text, prefix, label.as_deref(), offset, limit)?;
                CommandPayload::SearchRanked {
                    items: page.items,
                    has_more: page.has_more,
                    next_offset: page.next_after,
                }
            } else {
                let page = store.search_tasks_with_label(&text, after, limit, label.as_deref())?;
                CommandPayload::Search {
                    items: page.items,
                    has_more: page.has_more,
                    next_after: page.next_after,
                }
            }
        }
        ReadRequest::Show { ids, rules } => {
            let (mut items, rules) =
                store.show_tasks_with_budget(&ids, rules, Some(4 * 1024 * 1024))?;
            let (rule_version, rules) = rules
                .map(|r| (Some(r.version), Some(r.body)))
                .unwrap_or((None, None));
            if items.len() == 1 {
                CommandPayload::Show(ShowPayload {
                    task: items.remove(0),
                    rule_version,
                    rules,
                })
            } else {
                CommandPayload::ShowMany {
                    items,
                    rule_version,
                    rules,
                }
            }
        }
        ReadRequest::History {
            id,
            after,
            limit,
            event,
        } => {
            let id = store.resolve_ref(&id)?;
            let (mut page, selected) = store.history(id, after, limit, event)?;
            if let Some(event) = selected {
                page.items = vec![event];
                page.has_more = false;
                page.next_after = None;
            }
            CommandPayload::History {
                id,
                display_id: store.display_id(id),
                items: page.items,
                has_more: page.has_more,
                next_after: page.next_after,
            }
        }
        ReadRequest::ProjectHistory { after, limit } => {
            let page = store.metadata_history_with_budget(after, limit, Some(4 * 1024 * 1024))?;
            CommandPayload::ProjectHistory {
                items: page.items,
                has_more: page.has_more,
                next_after: page.next_after,
            }
        }
        ReadRequest::Rules => CommandPayload::RulesShow(store.rules_show()?),
        ReadRequest::ProjectKey => CommandPayload::ProjectKey {
            project_key: store.project_key.clone(),
            previous_key: None,
        },
        ReadRequest::Titles { references } => {
            if references.len() > 500 {
                return Err(AppError::validation(
                    "title lookup accepts at most 500 references",
                ));
            }
            let mut by_slot = std::collections::BTreeMap::<Option<String>, Vec<u64>>::new();
            for reference in references {
                let reference =
                    crate::model::parse_task_ref(&reference).map_err(AppError::validation)?;
                if reference.id == 0 || reference.id > i64::MAX as u64 {
                    return Err(AppError::validation("invalid title lookup ID"));
                }
                let key = reference
                    .key
                    .filter(|key| Some(key.as_str()) != store.project_key.as_deref());
                by_slot.entry(key).or_default().push(reference.id);
            }
            let mut titles = std::collections::HashMap::new();
            let mut known_keys = Vec::new();
            if let Some(ids) = by_slot.get(&None) {
                crate::enrich::read_titles_with_budget(
                    &store.conn,
                    ids,
                    &mut titles,
                    &None,
                    Some(4 * 1024 * 1024),
                )?;
            }
            if by_slot.keys().any(Option::is_some) {
                let projects = crate::keys::scan(server.data_root(), false)?;
                for (key, ids) in by_slot.iter().filter(|(key, _)| key.is_some()) {
                    let Some(project) = projects.iter().find(|project| &project.key == key) else {
                        continue;
                    };
                    if !catalogued(server, project.project_id)
                        .map_err(|_| AppError::Database("server catalog is unavailable".into()))?
                    {
                        continue;
                    }
                    let foreign =
                        Store::open_readonly(server.data_root(), &project.project_id.to_string())?;
                    let used = titles.values().map(|title| title.len() as u64).sum::<u64>();
                    crate::enrich::read_titles_with_budget(
                        &foreign.conn,
                        ids,
                        &mut titles,
                        key,
                        Some((4 * 1024 * 1024u64).saturating_sub(used)),
                    )?;
                    if let Some(key) = key {
                        known_keys.push(key.clone());
                    }
                }
            }
            let mut titles = titles
                .into_iter()
                .map(|((key, id), title)| TitleMatch { key, id, title })
                .collect::<Vec<_>>();
            titles.sort_by(|a, b| (&a.key, a.id).cmp(&(&b.key, b.id)));
            return Ok(serde_json::to_value(TitlesResult { titles, known_keys })?);
        }
        ReadRequest::ViewerTasks { request } => {
            CommandPayload::ViewerTasks(crate::viewer::tasks_in_store(store, request)?)
        }
        ReadRequest::ViewerShow { id } => {
            CommandPayload::ViewerShow(crate::viewer::show_in_store(store, &id)?)
        }
    };
    output(store, data)
}

enum Mutation {
    Create(CreateTask),
    Update(u64, UpdateTask),
    Rules(SetRules),
    Key(SetKey),
    ViewerUpdate(ViewerUpdate),
    Archive(SetArchive),
}
impl Mutation {
    fn attribution(&self) -> &Attribution {
        match self {
            Self::Create(v) => &v.attribution,
            Self::Update(_, v) => &v.attribution,
            Self::Rules(v) => &v.attribution,
            Self::Key(v) => &v.attribution,
            Self::ViewerUpdate(v) => &v.attribution,
            Self::Archive(v) => &v.attribution,
        }
    }
    fn apply(self, store: &mut Store, server: &OwnedServer) -> Result<Value, AppError> {
        let data = match self {
            Self::Create(v) => {
                let deps = v
                    .deps
                    .iter()
                    .map(|s| store.resolve_ref(s))
                    .collect::<Result<_, _>>()?;
                let status = v.status.to_string();
                let (id, version, event_id) = store.create_task_with_priority_labels(
                    &v.title, &v.body, v.status, deps, v.labels, v.priority,
                )?;
                CommandPayload::Create {
                    id,
                    display_id: store.display_id(id),
                    status,
                    version,
                    event_id,
                }
            }
            Self::Update(id, mut v) => {
                if store.resolve_ref(&v.task_ref)? != id {
                    return Err(AppError::validation(
                        "task reference does not match the route ID",
                    ));
                }
                if let Some(refs) = v.dependency_refs {
                    if v.changes.deps.is_some() || v.changes.clear_deps {
                        return Err(AppError::validation("conflicting dependency changes"));
                    }
                    v.changes.deps = Some(
                        refs.iter()
                            .map(|s| store.resolve_ref(s))
                            .collect::<Result<_, _>>()?,
                    );
                }
                let (id, status, version, event_id) =
                    store.update_task(id, v.expect_version, v.changes)?;
                CommandPayload::Update {
                    id,
                    display_id: store.display_id(id),
                    status: status.to_string(),
                    version,
                    event_id,
                }
            }
            Self::Rules(v) => CommandPayload::RulesSet {
                version: store.rules_set(&v.body, v.expect_version)?,
            },
            Self::Key(v) => {
                let key = crate::model::parse_project_key(&v.project_key)
                    .map_err(AppError::validation)?;
                unique_key(server, store.project_id, &key)?;
                let previous_key = store.set_project_key(&key)?;
                CommandPayload::ProjectKey {
                    project_key: Some(key),
                    previous_key: Some(previous_key),
                }
            }
            Self::ViewerUpdate(v) => {
                CommandPayload::ViewerUpdate(crate::viewer::update_in_store(store, v.request)?)
            }
            Self::Archive(v) => {
                CommandPayload::ViewerArchive(crate::viewer::ViewerArchivePayload {
                    protocol_version: crate::viewer::PROTOCOL_VERSION,
                    archived_at_ms: store.set_archive(v.archived)?,
                })
            }
        };
        output(store, data)
    }
}

fn create_project(
    server: &OwnedServer,
    auth: &AuthenticatedRequest,
    method: &Method,
    uri: &Uri,
    bytes: &[u8],
) -> Result<ReceiptResponse, ServiceError> {
    // Without a usable UUID there is no affected project receipt store.
    let value: Value = match parse(bytes) {
        Ok(v) => v,
        Err(error) => return response(Err(error)),
    };
    let project = value
        .get("project_id")
        .and_then(Value::as_str)
        .and_then(|s| Uuid::parse_str(s).ok())
        .filter(|id| !id.is_nil());
    let Some(project) = project else {
        return response(Err(AppError::validation(
            "project creation requires a non-nil UUID",
        )));
    };
    let prepared: Result<CreateProject, AppError> =
        parse(bytes).and_then(|mut request: CreateProject| {
            request.attribution = context(auth, request.attribution)?;
            if request.name.trim().is_empty() || request.name.len() > 1024 {
                return Err(AppError::validation(
                    "project name must contain 1-1024 bytes",
                ));
            }
            Ok(request)
        });
    let attribution = match &prepared {
        Ok(v) => v.attribution.clone(),
        Err(_) => context(auth, Attribution::default())?,
    };
    let id = identity(auth, method, uri)?;
    let canonical = canonical(bytes)?;
    let _lock = crate::storage::acquire_exclusive_lock(&server.data_root().join("registry.lock"))?;
    crate::store::prepare_server_project(server.data_root(), &project, &attribution)?;
    let mut store = Store::open_rw(server.data_root(), &project.to_string())?;
    store.set_attribution(&attribution)?;
    let result = receipts::execute(store, &id, &canonical, |store| {
        let request = prepared?;
        let key = request
            .project_key
            .as_deref()
            .map(crate::model::parse_project_key)
            .transpose()
            .map_err(AppError::validation)?;
        if let Some(key) = &key {
            unique_key(server, request.project_id, key)?;
        }
        store.complete_server_project_creation(&request.name, key.as_deref())?;
        let mut value = output(
            store,
            CommandPayload::Init {
                project_id: store.project_id.to_string(),
                project_key: key,
                db_path: format!("server:{}", server.server_id()),
            },
        )?;
        value["catalog_name"] = json!(request.name);
        Ok(value)
    })?;
    if result.status == 200 {
        let name = result
            .body
            .get("catalog_name")
            .and_then(Value::as_str)
            .ok_or(ServiceError::Validation("damaged project creation receipt"))?;
        let conn = server.connect()?;
        conn.execute("INSERT INTO projects(project_id,name) VALUES(?1,?2) ON CONFLICT(project_id) DO NOTHING",params![project.to_string(),name])?;
        let published: String = conn.query_row(
            "SELECT name FROM projects WHERE project_id=?1",
            [project.to_string()],
            |r| r.get(0),
        )?;
        if published != name {
            return Err(ServiceError::Validation(
                "project catalog disagrees with its creation receipt",
            ));
        }
    }
    Ok(result)
}

fn projects(server: &OwnedServer, uri: &Uri) -> Result<ReceiptResponse, ServiceError> {
    let mut after = String::new();
    let mut limit = 20usize;
    if let Some(query) = uri.query() {
        let mut seen = std::collections::HashSet::new();
        for part in query.split('&') {
            let (key, value) = part
                .split_once('=')
                .ok_or(ServiceError::Validation("invalid catalog cursor"))?;
            if !seen.insert(key) {
                return Err(ServiceError::Validation("duplicate catalog parameter"));
            }
            match key {
                "after" => {
                    after = Uuid::parse_str(value)
                        .map_err(|_| ServiceError::Validation("invalid catalog cursor"))?
                        .to_string()
                }
                "limit" => {
                    limit = value
                        .parse()
                        .map_err(|_| ServiceError::Validation("invalid catalog limit"))?
                }
                _ => return Err(ServiceError::Validation("unknown catalog parameter")),
            }
        }
    }
    if !(1..=100).contains(&limit) {
        return Err(ServiceError::Validation("catalog limit must be 1-100"));
    }
    let conn = server.connect()?;
    let mut stmt = conn.prepare(
        "SELECT project_id,name FROM projects WHERE project_id>?1 ORDER BY project_id LIMIT ?2",
    )?;
    let mut rows = stmt
        .query_map(params![after, limit + 1], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = rows.len() > limit;
    if has_more {
        rows.pop();
    }
    let mut items = Vec::new();
    for (id, name) in rows {
        let store = Store::open_readonly(server.data_root(), &id)?;
        let (tasks, open): (u64, u64) = store.conn.query_row(
            "SELECT count(*),coalesce(sum(status NOT IN ('done','cancelled')),0) FROM tasks",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        items.push(json!({"project_id":id,"name":name,"project_key":store.project_key,"task_count":tasks,"open_count":open}));
    }
    let next_after = items.last().and_then(|v| v.get("project_id")).cloned();
    Ok(ReceiptResponse {
        receipt: None,
        status: 200,
        body: json!({"items":items,"has_more":has_more,"next_after":next_after}),
    })
}

fn viewer_projects(server: &OwnedServer, bytes: &[u8]) -> Result<ReceiptResponse, ServiceError> {
    let input: ViewerProjectsRequest = match parse(bytes) {
        Ok(input) => input,
        Err(error) => return response(Err(error)),
    };
    if input.root_matches.len() > 10_000 {
        return response(Err(AppError::validation("too many root matches")));
    }
    let conn = server.connect()?;
    let mut statement =
        conn.prepare("SELECT project_id,name FROM projects ORDER BY project_id LIMIT 10001")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut catalog = Vec::new();
    for row in rows {
        let (id, name) = row?;
        let id = Uuid::parse_str(&id)
            .map_err(|_| ServiceError::Validation("invalid server catalog project UUID"))?;
        catalog.push((id, name));
    }
    let result = crate::viewer::projects_in_store(
        server.data_root(),
        input.request,
        catalog,
        &input.root_matches,
    )
    .and_then(|payload| output_with_project(None, CommandPayload::ViewerProjects(payload)));
    response(result)
}

/// Called only after signature verification, nonce admission and body digest.
pub fn handle(
    server: &OwnedServer,
    auth: &AuthenticatedRequest,
    method: &Method,
    uri: &Uri,
    bytes: &[u8],
) -> Result<ReceiptResponse, ServiceError> {
    if *method == Method::GET && uri.path() == "/v1/info" {
        if uri.query().is_some() {
            return Err(ServiceError::Validation(
                "info does not accept query parameters",
            ));
        }
        return Ok(ReceiptResponse {
            receipt: None,
            status: 200,
            body: json!({"protocol_version":1,"server_id":server.server_id(),"ready":true,"capabilities":["typed-task-api","project-catalog","atomic-receipts","request-bound-receipts","ed25519-signatures","persistent-replay-protection"]}),
        });
    }
    if *method == Method::GET && uri.path() == "/v1/viewer/info" {
        if uri.query().is_some() {
            return response(Err(AppError::validation(
                "viewer info does not accept query parameters",
            )));
        }
        let result = output_with_project(None, CommandPayload::ViewerInfo(crate::viewer::info()))
            .map(|mut value| {
                value["output"]["data"]["backend"] = json!("remote");
                value["output"]["data"]["receipt_recovery"] = json!(true);
                value
            });
        return response(result);
    }
    if *method == Method::POST && uri.path() == "/v1/viewer/projects" && uri.query().is_none() {
        return viewer_projects(server, bytes);
    }
    if uri.path() == "/v1/projects" {
        if *method == Method::GET {
            return match projects(server, uri) {
                Err(ServiceError::Validation(message)) => {
                    response(Err(AppError::validation(message)))
                }
                other => other,
            };
        }
        if *method == Method::POST && uri.query().is_none() {
            return create_project(server, auth, method, uri, bytes);
        }
    }
    let parts = uri.path().split('/').collect::<Vec<_>>();
    if parts.len() < 5 || parts[1] != "v1" || parts[2] != "projects" {
        return response(Err(AppError::NotFound("unknown API route".into())));
    }
    let project = match Uuid::parse_str(parts[3]) {
        Ok(id) if !id.is_nil() && id.to_string() == parts[3] => id,
        _ => {
            return response(Err(AppError::validation(
                "project route requires a canonical non-nil UUID",
            )))
        }
    };
    if uri.query().is_some() {
        return response(Err(AppError::validation(
            "project route does not accept query parameters",
        )));
    }
    if !catalogued(server, project)? {
        if super::signatures::is_mutation(method, uri) {
            // Keep a terminal missing-project refusal under the same UUID, so
            // a later project creation cannot turn its replay into a write.
            let _lock =
                crate::storage::acquire_exclusive_lock(&server.data_root().join("registry.lock"))?;
            let attribution = context(auth, Attribution::default())?;
            crate::store::prepare_server_project(server.data_root(), &project, &attribution)?;
            let store = Store::open_rw(server.data_root(), &project.to_string())?;
            return Ok(receipts::execute(
                store,
                &identity(auth, method, uri)?,
                &canonical(bytes)?,
                |_| Err(not_found()),
            )?);
        }
        return response(Err(not_found()));
    }
    if parts.len() == 5 && parts[4] == "query" && *method == Method::POST {
        let input = match parse(bytes) {
            Ok(v) => v,
            Err(error) => return response(Err(error)),
        };
        let mut store = Store::open_readonly(server.data_root(), &project.to_string())?;
        return response(query(server, &mut store, input));
    }
    if parts.len() == 5 && parts[4] == "export" && *method == Method::GET {
        return Err(ServiceError::Validation(
            "exports require the streaming HTTP transport",
        ));
    }
    let prepared: Result<Mutation, AppError> = match (method.as_str(), parts.len(), parts[4]) {
        ("POST", 5, "tasks") => parse(bytes).map(Mutation::Create),
        ("PATCH", 6, "tasks") => match parts[5].parse::<u64>() {
            Ok(id) if id > 0 && id <= i64::MAX as u64 && id.to_string() == parts[5] => {
                parse(bytes).map(|v| Mutation::Update(id, v))
            }
            _ => {
                return response(Err(AppError::validation(
                    "task route requires a positive numeric ID",
                )))
            }
        },
        ("PUT", 5, "rules") => parse(bytes).map(Mutation::Rules),
        ("PUT", 5, "key") => parse(bytes).map(Mutation::Key),
        ("PATCH", 6, "viewer") if parts[5] == "update" => parse(bytes).map(Mutation::ViewerUpdate),
        ("PUT", 5, "archive") => parse(bytes).map(Mutation::Archive),
        _ => return response(Err(AppError::NotFound("unknown API route".into()))),
    };
    let attribution = prepared
        .as_ref()
        .ok()
        .map(|v| context(auth, v.attribution().clone()))
        .transpose();
    let id = identity(auth, method, uri)?;
    let canonical = canonical(bytes)?;
    let _key_lock = if parts[4] == "key" {
        Some(crate::storage::acquire_exclusive_lock(
            &server.data_root().join("registry.lock"),
        )?)
    } else {
        None
    };
    let mut store = Store::open_rw(server.data_root(), &project.to_string())?;
    let attribution = match attribution {
        Ok(Some(v)) => {
            store.set_attribution(&v)?;
            Ok(())
        }
        Ok(None) => Ok(()),
        Err(error) => Err(error),
    };
    Ok(receipts::execute(store, &id, &canonical, |store| {
        attribution?;
        prepared?.apply(store, server)
    })?)
}

pub(crate) enum ExportPreparation {
    Ready(Box<Store>),
    Refused(ReceiptResponse),
}
pub(crate) fn prepare_export(
    server: &OwnedServer,
    uri: &Uri,
) -> Result<ExportPreparation, ServiceError> {
    let parts = uri.path().split('/').collect::<Vec<_>>();
    let refusal = |status, code, message| {
        ExportPreparation::Refused(ReceiptResponse {
            receipt: None,
            status,
            body: json!({"schema_version":1,"error":{"code":code,"message":message,"exit_code":if status==404{3}else{2}}}),
        })
    };
    if parts.len() != 5 || parts[1] != "v1" || parts[2] != "projects" || parts[4] != "export" {
        return Ok(refusal(404, "not_found", "unknown API route"));
    }
    let project = match Uuid::parse_str(parts[3]) {
        Ok(id) if !id.is_nil() && id.to_string() == parts[3] => id,
        _ => {
            return Ok(refusal(
                400,
                "validation",
                "project route requires a canonical non-nil UUID",
            ))
        }
    };
    if uri.query().is_some() {
        return Ok(refusal(
            400,
            "validation",
            "export does not accept query parameters",
        ));
    }
    if !catalogued(server, project)? {
        return Ok(refusal(404, "not_found", "unknown server project"));
    }
    Ok(ExportPreparation::Ready(Box::new(Store::open_readonly(
        server.data_root(),
        &project.to_string(),
    )?)))
}
