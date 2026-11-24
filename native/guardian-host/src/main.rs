//! External evidence adapter; never starts an executing agent turn.
mod bootstrap;
use anyhow::{Context, ensure};
use codex_core_api::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

const PROTOCOL: &str = "ag-guardian-v3";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const UPSTREAM: &str = "6ff1e1ca3b30fc8b914720681fcf5fe62e95f856";
const MAX_FRAME: usize = 12 * 1024 * 1024;
const MAX_SESSIONS: usize = 8;
const MAX_PARENT_REVIEWS: usize = 64;
const MAX_REVIEW_INPUT: i64 = 96_000;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    id: String,
    operation: String,
    #[serde(default)] scope: String,
    #[serde(default)] history: Vec<Value>,
    #[serde(default)] action: Value,
    #[serde(default)] host_facts: Value,
    #[serde(default)] extra_policy: String,
    #[serde(default = "default_timeout")] timeout_ms: u64,
}
fn default_timeout() -> u64 { 80_000 }
struct Parent { thread: Arc<CodexThread>, id: ThreadId, history: Vec<Value>, policy: String, touched: Instant, reviews: usize, last_input: i64 }
fn needs_checkpoint(reviews: usize, input: i64) -> bool { reviews >= MAX_PARENT_REVIEWS || input >= MAX_REVIEW_INPUT }
struct NoUserInstructions;
impl UserInstructionsProvider for NoUserInstructions {
    fn load_user_instructions(&self) -> LoadInstructionsFuture<'_> {
        Box::pin(async { LoadedUserInstructions::default() })
    }
}
fn emit(value: Value) -> anyhow::Result<()> {
    println!("{value}"); std::io::stdout().flush()?; Ok(())
}
fn read_request(input: &mut impl BufRead) -> anyhow::Result<Option<Request>> {
    // Take bounds allocation even for a malicious/misconfigured local sender.
    let mut frame = Vec::new();
    let n = std::io::Read::take(input, (MAX_FRAME + 1) as u64).read_until(b'\n', &mut frame)?;
    if n == 0 { return Ok(None); }
    ensure!(n <= MAX_FRAME && frame.last() == Some(&b'\n'), "oversized or incomplete request frame");
    Ok(Some(serde_json::from_slice(&frame)?))
}
fn validate(r: &Request) -> anyhow::Result<()> {
    ensure!(!r.id.is_empty() && r.id.len() <= 128, "invalid request id");
    ensure!(r.scope.len() == 64 && r.scope.bytes().all(|b| b.is_ascii_hexdigit()), "invalid scope");
    ensure!((100..=codex_guardian_reviewer::REVIEW_TIMEOUT.as_millis() as u64).contains(&r.timeout_ms), "invalid deadline");
    ensure!(r.history.len() <= 50_000 && r.extra_policy.len() <= 131_072, "host input exceeds limits");
    ensure!(r.action["type"] == "function_call" && r.action["name"].as_str().is_some(), "invalid native action");
    let arguments: Value=serde_json::from_str(r.action["arguments"].as_str().context("missing action arguments")?)?;
    ensure!(arguments.is_object(), "action arguments must be an object");
    let mut users = 0;
    for item in &r.history {
        match item["type"].as_str() {
            Some("message") => {
                ensure!(matches!(item["role"].as_str(), Some("user" | "assistant")), "unaccepted evidence role");
                if item["role"] == "user" { users += 1; }
            }
            Some("function_call" | "function_call_output") => (),
            _ => anyhow::bail!("unaccepted evidence item"),
        }
    }
    ensure!(users > 0, "no source-verified user input");
    Ok(())
}
fn main() -> anyhow::Result<()> { arg0_dispatch_or_else(run) }
async fn run(paths: Arg0DispatchPaths) -> anyhow::Result<()> {
    if std::env::args().any(|arg| arg == "--version") {
        emit(json!({"protocol":PROTOCOL,"version":VERSION,"upstreamCommit":UPSTREAM}))?;
        return Ok(());
    }
    ensure!(std::env::var("AG_GUARDIAN_HOST").as_deref()==Ok("1"), "start through the approval host");
    let _ = set_default_originator("antigravity_guardian_host".to_owned());
    let mut config = bootstrap::new_config(Some("codex-auto-review".into()), paths).await?;
    config.model_reasoning_effort = Some(serde_json::from_str("\"low\"")?);
    config.model_provider.supports_websockets = false;
    config.project_doc_max_bytes = 0;
    // External host supplies fresh bounded history; avoid a paid compaction turn.
    config.model_auto_compact_token_limit = Some(100_000_000);
    config.model_post_turn_compact_threshold_percent = 0;
    for f in [Feature::Apps, Feature::Plugins, Feature::CodexHooks, Feature::MultiAgentV2,
        Feature::CodeMode, Feature::CodeModeHost, Feature::ShellTool, Feature::GuardianConversationHistoryTools] {
        config.features.set_enabled(f, false)?;
    }
    config.features.set_enabled(Feature::SkipHostSkillDiscovery, true)?;
    let db = init_state_db(&config).await;
    let auth = AuthManager::shared_from_config(&config, false).await?;
    let runtime = ExecServerRuntimeOptions::from_optional_paths(config.codex_self_exe.clone(), config.codex_linux_sandbox_exe.clone())?;
    let store = thread_store_from_config(&config, db.clone());
    let environments = Arc::new(EnvironmentManager::from_codex_home(config.codex_home.clone(), Some(runtime), config.http_client_factory()).await?);
    let installation = resolve_installation_id(&config.codex_home).await?;
    let models = build_models_manager(&config, Arc::clone(&auth));
    let manager = Arc::new_cyclic(|weak| {
        let mut extensions = ExtensionRegistryBuilder::<Config>::new();
        codex_guardian_v2::install_reviewer(&mut extensions, weak.clone());
        ThreadManager::new(&config, Arc::clone(&auth), Arc::clone(&models), CodexAppsToolsCache::default(),
            SessionSource::Exec, Arc::clone(&environments), Arc::new(extensions.build()), Arc::new(NoUserInstructions),
            None, passthrough_image_store(), Arc::clone(&store), local_agent_graph_store_from_state_db(db.as_ref()), installation.clone(), None, None)
    });
    emit(json!({"type":"ready","protocol":PROTOCOL,"version":VERSION,"upstreamCommit":UPSTREAM,
        "toolsEnabled":false,"investigationMode":"host_workspace_script_snapshots",
        "inferenceDispatchCap":null,"maxAttempts":codex_guardian_reviewer::MAX_REVIEW_ATTEMPTS,
        "nativeTimeoutMs":codex_guardian_reviewer::REVIEW_TIMEOUT.as_millis(),
        "requestMaxRetries":config.model_provider.request_max_retries(),
        "streamMaxRetries":config.model_provider.stream_max_retries()}))?;
    let mut parents: HashMap<String, Parent> = HashMap::new();
    let auth_changes = auth.auth_change_state_receiver();
    let mut session_owner_generation = auth_changes.borrow().owner_generation;
    let mut input = std::io::BufReader::new(std::io::stdin());
    while let Some(request) = read_request(&mut input)? {
        let started = Instant::now();
        if request.operation == "shutdown" { break; }
        if request.operation == "invalidate" {
            if let Some(old) = parents.remove(&request.scope) { retire(&manager, old).await; }
            emit(json!({"id":request.id,"ok":true,"invalidated":true}))?; continue;
        }
        let result = async {
            ensure!(request.operation == "assess", "unknown operation"); validate(&request)?;
            // Codex can select a different account while this host is running.
            auth.reload().await;
            let owner_generation = auth_changes.borrow().owner_generation;
            let mut reset = "new_scope";
            if owner_generation != session_owner_generation {
                for (_, parent) in parents.drain() {
                    retire(&manager, parent).await;
                }
                session_owner_generation = owner_generation;
                reset = "account_changed";
            }
            if auth.auth_cached().is_none() {
                return Ok(json!({"id":request.id,"ok":false,"sessionRetired":true,
                    "error":"No active Codex login is available. Sign in to Codex to resume automatic review.",
                    "failure":{"reasonCode":"entitlement_unavailable","rawErrorKind":"missing_codex_auth","retryable":false},
                    "inferenceDispatchCount":0,"attemptCount":0,"sessionReason":reset}));
            }
            // Check before selecting or mutating the parent. The bridge may use its
            // CLI backend for this action and keep the native reviewer warm.
            if let Some(reply) = preflight(&request)? {
                return Ok(reply);
            }
            let compatible = parents.get(&request.scope).is_some_and(|p|
                p.touched.elapsed() < Duration::from_secs(1800) && !needs_checkpoint(p.reviews,p.last_input) && request.extra_policy == p.policy && request.history.starts_with(&p.history));
            if !compatible {
                if let Some(old) = parents.remove(&request.scope) { reset = if needs_checkpoint(old.reviews,old.last_input) {"review_budget_checkpoint"} else {"history_rewrite_or_idle"}; retire(&manager, old).await; }
                if parents.len() >= MAX_SESSIONS {
                    let oldest = parents.iter().min_by_key(|(_, p)| p.touched).map(|(key, _)| key.clone()).context("missing oldest session")?;
                    retire(&manager, parents.remove(&oldest).unwrap()).await;
                }
                let mut parent_config = config.clone();
                parent_config.guardian_extra_policy = Some(request.extra_policy.clone());
                let NewThread {thread_id, thread, ..} = manager.start_thread(StartThreadOptions::new(parent_config)).await?;
                parents.insert(request.scope.clone(), Parent {thread, id: thread_id, history: Vec::new(), policy: request.extra_policy.clone(), touched: Instant::now(), reviews:0,last_input:0});
            } else { reset = "continued"; }
            let parent = parents.get_mut(&request.scope).unwrap();
            let delta = request.history[parent.history.len()..].to_vec();
            let remaining = request.timeout_ms.saturating_sub(started.elapsed().as_millis() as u64);
            if remaining == 0 {
                return Ok(json!({"id":request.id,"ok":false,"error":"Native Guardian deadline expired before assessment",
                    "failure":{"reasonCode":"review_timeout","rawErrorKind":"timeout","retryable":false},
                    "inferenceDispatchCount":0,"attemptCount":0}));
            }
            let result = parent.thread.assess_external_guardian(
                Value::Array(delta), request.action.clone(), request.host_facts.clone(), remaining,
            ).await?;
            auth.reload().await;
            let account_changed = auth_changes.borrow().owner_generation != owner_generation;
            if account_changed || result["error"].is_string() {
                let (error, failure) = if account_changed {
                    reset = "account_changed";
                    ("The Codex account or workspace changed during review. Submit the action again under the current login.",
                        json!({"reasonCode":"action_invalidated","rawErrorKind":"review_account_changed","retryable":false}))
                } else {
                    (result["error"].as_str().unwrap_or("Native Guardian failed"), result["failure"].clone())
                };
                let failed = json!({"id":request.id,"ok":false,"error":error,"sessionRetired":true,
                    "inferenceDispatchCount":result["inferenceDispatchCount"],"attemptCount":result["attemptCount"],
                    "failure":failure,"usage":result["usage"],"httpRequestCount":result["httpRequestCount"],
                    "sampling":result["sampling"],"sessionReason":reset});
                if let Some(old) = parents.remove(&request.scope) { retire(&manager, old).await; }
                return Ok(failed);
            }
            parent.history = request.history.clone(); parent.touched = Instant::now();
            parent.reviews += 1; parent.last_input=result["usage"]["input_tokens"].as_i64().unwrap_or(MAX_REVIEW_INPUT);
            Ok::<_, anyhow::Error>(json!({"id":request.id,"ok":true,"result":result,"sessionReason":reset}))
        }.await;
        match result {
            Ok(value) => emit(value)?,
            Err(error) => {
                if let Some(old) = parents.remove(&request.scope) { retire(&manager, old).await; }
                emit(json!({"id":request.id,"ok":false,"error":error.to_string(),"sessionRetired":true}))?;
            }
        }
    }
    for (_, parent) in parents { retire(&manager, parent).await; }
    Ok(())
}

fn preflight(request: &Request) -> anyhow::Result<Option<Value>> {
    let action = serde_json::from_value(request.action.clone())?;
    match codex_guardian_context::validate_native_tool_call(&action) {
        Ok(()) => Ok(None),
        Err(error @ codex_guardian_context::SectionError::EvidenceLimitExceeded { section: "native_tool_call" }) =>
            Ok(Some(json!({"id":request.id,"ok":false,"error":error.to_string(),"sessionRetired":false,
                "failure":{"reasonCode":"native_tool_call_limit","rawErrorKind":"PromptBuildError","retryable":false},
                "inferenceDispatchCount":0,"attemptCount":0}))),
        Err(error) => Err(error.into()),
    }
}
async fn retire(manager: &ThreadManager, parent: Parent) {
    let _ = parent.thread.shutdown_and_wait().await;
    let _ = manager.remove_thread(&parent.id).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Value { json!({"id":"test","operation":"assess","scope":"a".repeat(64),"timeoutMs":5000,
        "history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Do not execute"}]}],
        "action":{"type":"function_call","call_id":"call-test","name":"write_file","arguments":"{}"}}) }
    #[test] fn accepts_evidence_without_executing() {
        let r:Request=serde_json::from_value(request()).unwrap(); assert!(validate(&r).is_ok());
    }
    #[test] fn rejects_privileged_evidence_roles_and_missing_users() {
        for role in ["developer","system","assistant"] { let mut value=request();value["history"][0]["role"]=json!(role);
            let r:Request=serde_json::from_value(value).unwrap(); assert!(validate(&r).is_err()); }
    }
    #[test] fn rejects_nonobject_action_arguments_and_unknown_fields() {
        let mut value=request();value["action"]["arguments"]=json!("[]");assert!(validate(&serde_json::from_value(value).unwrap()).is_err());
        let mut value=request();value["execute"]=json!(true);assert!(serde_json::from_value::<Request>(value).is_err());
    }
    #[test] fn framing_requires_newline_and_bounds_allocation() {
        let bytes=request().to_string();assert!(read_request(&mut std::io::Cursor::new(bytes.as_bytes())).is_err());
        assert!(read_request(&mut std::io::Cursor::new(format!("{bytes}\n"))).unwrap().is_some());
        assert!(read_request(&mut std::io::Cursor::new(vec![b'x';MAX_FRAME+1])).is_err());
    }
    #[test] fn sustained_reviews_checkpoint_before_unbounded_growth() {
        assert!(!needs_checkpoint(63,95_999));assert!(needs_checkpoint(64,100));assert!(needs_checkpoint(1,96_000));
    }
    #[test] fn oversize_preflight_leaves_parent_untouched_and_dispatches_nothing() {
        let mut value=request();
        assert!(preflight(&serde_json::from_value(value.clone()).unwrap()).unwrap().is_none());
        value["action"]["arguments"]=json!(json!({"Content":"sample ".repeat(16_000)}).to_string());
        let reply=preflight(&serde_json::from_value(value).unwrap()).unwrap().unwrap();
        assert_eq!(reply["sessionRetired"],false);
        assert_eq!(reply["inferenceDispatchCount"],0);
        assert_eq!(reply["failure"]["reasonCode"],"native_tool_call_limit");
    }
}
