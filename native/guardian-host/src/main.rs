//! External evidence adapter; never starts an executing agent turn.
mod bootstrap;
use anyhow::{Context, ensure};
use codex_core_api::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

const PROTOCOL: &str = "ag-guardian-v4";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const UPSTREAM: &str = "3d86e43b075adeba2193ec5c22ac92f55afd82e6";
const MAX_FRAME: usize = 12 * 1024 * 1024;
const MAX_SESSIONS: usize = 8;
const MAX_PARENT_REVIEWS: usize = 64;
const MAX_REVIEW_INPUT_GROWTH: i64 = 96_000;
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct UserInstruction {
    position: u64,
    text: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Authorization {
    user_instructions: Vec<UserInstruction>,
    project_rules: Vec<serde_json::Map<String, Value>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    id: String,
    operation: String,
    #[serde(default)] scope: String,
    #[serde(default)] conversation_id: Option<String>,
    #[serde(default)] history: Vec<Value>,
    authorization: Option<Authorization>,
    #[serde(default)] action: Value,
    #[serde(default)] host_facts: Value,
    #[serde(default)] extra_policy: String,
    #[serde(default = "default_timeout")] timeout_ms: u64,
}
fn default_timeout() -> u64 { 80_000 }
struct Parent { thread: Arc<CodexThread>, id: ThreadId, conversation_id: Option<String>, history: Vec<Value>, policy: String, touched: Instant, reviews: usize, base_input: Option<i64>, last_input: i64 }
fn needs_checkpoint(reviews: usize, base_input: Option<i64>, last_input: i64) -> bool {
    reviews >= MAX_PARENT_REVIEWS
        || base_input.is_some_and(|base| last_input.saturating_sub(base) >= MAX_REVIEW_INPUT_GROWTH)
}
fn record_review_input(
    base_input: &mut Option<i64>,
    last_input: &mut i64,
    usage_input: Option<i64>,
    attempts: Option<i64>,
    dispatches: Option<i64>,
) {
    // Usage covers the final attempt, but dispatches covers the whole review.
    // Only a single attempt with a single dispatch is an unambiguous sample.
    if attempts != Some(1) || dispatches != Some(1) {
        return;
    }
    // A successful response without usage can appear as a zero cumulative delta.
    let Some(input) = usage_input.filter(|&value| value > 0) else {
        return;
    };
    *last_input = input;
    *base_input = Some(base_input.map_or(input, |base| base.min(input)));
}
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
    if let Some(cid) = &r.conversation_id {
        ensure!(!cid.is_empty() && cid.len() <= 128, "invalid conversation id");
    }
    ensure!((100..=codex_guardian_reviewer::REVIEW_TIMEOUT.as_millis() as u64).contains(&r.timeout_ms), "invalid deadline");
    ensure!(r.history.len() <= 50_000 && r.extra_policy.len() <= 131_072, "host input exceeds limits");
    ensure!(r.action["type"] == "function_call" && r.action["name"].as_str().is_some(), "invalid native action");
    let arguments: Value=serde_json::from_str(r.action["arguments"].as_str().context("missing action arguments")?)?;
    ensure!(arguments.is_object(), "action arguments must be an object");
    let authorization = r.authorization.as_ref().context("missing authorization evidence")?;
    let users = &authorization.user_instructions;
    ensure!(!users.is_empty() && users.len() <= 50_000 && users[0].position > 0
        && users.windows(2).all(|pair| pair[0].position < pair[1].position),
        "invalid order or missing source-verified user input");
    for item in &r.history {
        match item["type"].as_str() {
            Some("message") => {
                ensure!(item["role"] == "assistant", "unaccepted evidence role");
                ensure!(item.as_object().is_some_and(|fields| fields.keys().all(|key|
                    matches!(key.as_str(), "type" | "role" | "content"))), "unaccepted evidence metadata");
                ensure!(item["content"].as_array().is_some_and(|parts| !parts.is_empty() && parts.iter().all(|part|
                    part["type"] == "input_text" && part["text"].is_string())), "external evidence must contain text");
            }
            Some("function_call" | "function_call_output") => (),
            _ => anyhow::bail!("unaccepted evidence item"),
        }
    }
    Ok(())
}

fn main() -> anyhow::Result<()> {
    if std::env::args().any(|arg| arg == "--version") {
        emit(json!({"protocol":PROTOCOL,"version":VERSION,"upstreamCommit":UPSTREAM}))?;
        return Ok(());
    }
    if std::env::args().any(|arg| arg == "--check-auth") {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        return runtime.block_on(check_auth(Arg0DispatchPaths::default()));
    }
    arg0_dispatch_or_else(run)
}
async fn check_auth(paths: Arg0DispatchPaths) -> anyhow::Result<()> {
    let mut report = json!({"status":"store_unavailable","codexHome":null,"storeMode":null,"storeError":null});
    let exit_code = match bootstrap::new_config(None, paths).await {
        Ok(config) => {
            report["codexHome"] = json!(config.codex_home.as_path());
            report["storeMode"] = json!(config.cli_auth_credentials_store_mode);
            if config.cli_auth_credentials_store_mode == AuthCredentialsStoreMode::Ephemeral {
                report["storeError"] = json!("ephemeral_store_is_process_local");
                2
            } else {
                match AuthManager::shared_from_config(&config, false).await {
                    Ok(auth) => match auth.reload_with_cached_auth().await {
                        Ok(_) if auth.auth_cached().is_some() => {
                            report["status"] = json!("credentials_found");
                            0
                        }
                        Ok(_) => {
                            report["status"] = json!("credentials_missing");
                            1
                        }
                        Err(error) => {
                            report["storeError"] = json!({"stage":"reload","kind":format!("{:?}",error.kind()),
                                "osError":error.raw_os_error()});
                            2
                        }
                    },
                    Err(_) => {
                        report["storeError"] = json!("credential_manager_initialization_failed");
                        2
                    }
                }
            }
        }
        Err(_) => {
            report["codexHome"] = json!(find_codex_home().ok().map(|path| path.as_path().to_path_buf()));
            report["storeError"] = json!("authentication_configuration_unavailable");
            2
        }
    };
    emit(report)?;
    if exit_code != 0 { std::process::exit(exit_code); }
    Ok(())
}

async fn run(paths: Arg0DispatchPaths) -> anyhow::Result<()> {
    if std::env::args().any(|arg| arg == "--version") {
        emit(json!({"protocol":PROTOCOL,"version":VERSION,"upstreamCommit":UPSTREAM}))?;
        return Ok(());
    }
    if std::env::args().any(|arg| arg == "--check-auth") {
        return check_auth(paths).await;
    }
    ensure!(std::env::var("AG_GUARDIAN_HOST").as_deref()==Ok("1"), "start through the approval host");
    let _ = set_default_originator("antigravity_guardian_host".to_owned());
    let mut config = bootstrap::new_config(Some("codex-auto-review".into()), paths).await?;
    configure_host(&mut config)?;
    let (auth, manager) = start_host(&config).await?;
    serve(config, auth, manager).await
}

fn configure_host(config: &mut Config) -> anyhow::Result<()> {
    config.model_reasoning_effort = Some(serde_json::from_str("\"low\"")?);
    config.model_provider.supports_websockets = false;
    config.project_doc_max_bytes = 0;
    // External host supplies fresh bounded history; avoid a paid compaction turn.
    config.model_auto_compact_token_limit = Some(100_000_000);
    config.model_post_turn_compact_threshold_percent = 0;
    for f in [Feature::Apps, Feature::Plugins, Feature::CodexHooks, Feature::MultiAgentV2,
        Feature::CodeMode, Feature::CodeModeHost, Feature::ShellTool, Feature::GuardianConversationHistoryTools,
        Feature::GuardianV3, Feature::GuardianV2DecisionsComparison, Feature::BrowserUse,
        Feature::BrowserUseExternal, Feature::ComputerUse, Feature::ImageGeneration,
        Feature::WebSearchRequest, Feature::WebSearchCached, Feature::ApplyPatchFreeform] {
        config.features.set_enabled(f, false)?;
    }
    config.features.set_enabled(Feature::SkipHostSkillDiscovery, true)?;
    Ok(())
}

async fn start_host(config: &Config) -> anyhow::Result<(Arc<AuthManager>, Arc<ThreadManager>)> {
    let db = init_state_db(config).await;
    let auth = AuthManager::shared_from_config(config, false).await?;
    let runtime = ExecServerRuntimeOptions::from_optional_paths(config.codex_self_exe.clone(), config.codex_linux_sandbox_exe.clone())?;
    let store = ThreadStoreBuilder::from_config(config, db.clone()).build();
    let environments = Arc::new(EnvironmentManager::from_codex_home(config.codex_home.clone(), Some(runtime), config.http_client_factory()).await?);
    let installation = resolve_installation_id(&config.codex_home).await?;
    let startup = build_startup_models(config, Arc::clone(&auth), installation,
        Arc::new(ModelCatalogSettings::disk(config.codex_home.to_path_buf())));
    let manager = Arc::new_cyclic(|weak| {
        let mut extensions = ExtensionRegistryBuilder::<Config>::new();
        codex_guardian_v2::install_reviewer(&mut extensions, weak.clone());
        ThreadManager::new(config, startup, CodexAppsToolsCache::default(),
            SessionSource::Exec, Arc::clone(&environments), Arc::new(extensions.build()), Arc::new(NoUserInstructions),
            None, passthrough_image_store(), Arc::clone(&store), local_agent_graph_store_from_state_db(db.as_ref()), None, None)
    });
    Ok((auth, manager))
}

async fn serve(config: Config, auth: Arc<AuthManager>, manager: Arc<ThreadManager>) -> anyhow::Result<()> {
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
            if let Err(error) = validate(&request).and_then(|()| {
                ensure!(request.operation == "assess", "unknown operation");
                Ok(())
            }) {
                return Ok(json!({"id":request.id,"ok":false,"sessionRetired":false,
                    "error":error.to_string(),
                    "failure":{"reasonCode":"context_invalid","rawErrorKind":"invalid_guardian_evidence","retryable":false},
                    "inferenceDispatchCount":0,"attemptCount":0}));
            }
            // Codex can select a different account while this host is running.
            if auth.reload_with_cached_auth().await.is_err() {
                for (_, parent) in parents.drain() { retire(&manager, parent).await; }
                return Ok(json!({"id":request.id,"ok":false,"sessionRetired":true,
                    "error":"Could not verify the current credential store.",
                    "failure":{"reasonCode":"action_invalidated","rawErrorKind":"credential_store_unavailable","retryable":false},
                    "inferenceDispatchCount":0,"attemptCount":0}));
            }
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
            let compatible = parents.get(&request.scope).is_some_and(|p|
                p.touched.elapsed() < Duration::from_secs(1800) && !needs_checkpoint(p.reviews, p.base_input, p.last_input) && request.extra_policy == p.policy && request.history.starts_with(&p.history));
            if !compatible {
                if let Some(old) = parents.remove(&request.scope) { reset = if needs_checkpoint(old.reviews, old.base_input, old.last_input) {"review_budget_checkpoint"} else {"history_rewrite_or_idle"}; retire(&manager, old).await; }
                if let Some(cid) = &request.conversation_id {
                    let stale_scopes: Vec<String> = parents.iter()
                        .filter(|(key, parent)| *key != &request.scope && parent.conversation_id.as_deref() == Some(cid.as_str()))
                        .map(|(key, _)| key.clone())
                        .collect();
                    for stale_scope in stale_scopes {
                        if let Some(old) = parents.remove(&stale_scope) {
                            retire(&manager, old).await;
                        }
                    }
                }
                if parents.len() >= MAX_SESSIONS {
                    let oldest = parents.iter().min_by_key(|(_, p)| p.touched).map(|(key, _)| key.clone()).context("missing oldest session")?;
                    retire(&manager, parents.remove(&oldest).unwrap()).await;
                }
                let mut parent_config = config.clone();
                parent_config.guardian_extra_policy = Some(request.extra_policy.clone());
                let NewThread {thread_id, thread, ..} = manager.start_thread(StartThreadOptions::new(parent_config)).await?;
                parents.insert(request.scope.clone(), Parent {thread, id: thread_id, conversation_id: request.conversation_id.clone(), history: Vec::new(), policy: request.extra_policy.clone(), touched: Instant::now(), reviews: 0, base_input: None, last_input: 0});
            } else { reset = "continued"; }
            let parent = parents.get_mut(&request.scope).unwrap();
            let delta = request.history[parent.history.len()..].to_vec();
            let remaining = request.timeout_ms.saturating_sub(started.elapsed().as_millis() as u64);
            if remaining == 0 {
                return Ok(json!({"id":request.id,"ok":false,"error":"Native Guardian deadline expired before assessment",
                    "failure":{"reasonCode":"review_timeout","rawErrorKind":"timeout","retryable":false},
                    "inferenceDispatchCount":0,"attemptCount":0}));
            }
            let cancellation = CancellationToken::new();
            let authorization = serde_json::to_value(request.authorization.as_ref().context("missing validated authorization")?)?;
            let review = parent.thread.assess_external_guardian(
                Value::Array(delta), request.action.clone(), request.host_facts.clone(), authorization, remaining, cancellation.clone(),
            );
            let watch_login = async {
                loop {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    let unavailable = auth.reload_with_cached_auth().await.is_err();
                    let changed = auth_changes.borrow().owner_generation != owner_generation;
                    if unavailable || changed { return (unavailable, changed); }
                }
            };
            let (result, store_error_during, owner_changed_during) = {
                tokio::pin!(review);
                tokio::select! {
                    outcome = &mut review => (outcome, false, false),
                    (unavailable, changed) = watch_login => {
                        cancellation.cancel();
                        (review.await, unavailable, changed)
                    }
                }
            };
            let result = result?;
            let store_unavailable = auth.reload_with_cached_auth().await.is_err() || store_error_during;
            let account_changed = owner_changed_during || auth_changes.borrow().owner_generation != owner_generation
                || result["failure"]["reasonCode"] == "action_invalidated"
                    && result["failure"]["rawErrorKind"] == "review_account_changed";
            if account_changed || store_unavailable || result["error"].is_string() {
                let (error, failure) = if account_changed {
                    reset = "account_changed";
                    ("The Codex account or workspace changed during review. Submit the action again under the current login.",
                        json!({"reasonCode":"action_invalidated","rawErrorKind":"review_account_changed","retryable":false}))
                } else if store_unavailable {
                    ("Could not verify the credential store after review.",
                        json!({"reasonCode":"action_invalidated","rawErrorKind":"credential_store_unavailable","retryable":false}))
                } else {
                    (result["error"].as_str().unwrap_or("Native Guardian failed"), result["failure"].clone())
                };
                let failed = json!({"id":request.id,"ok":false,"error":error,"sessionRetired":true,
                    "inferenceDispatchCount":result["inferenceDispatchCount"],"attemptCount":result["attemptCount"],
                    "failure":failure,"usage":result["usage"],"httpRequestCount":result["httpRequestCount"],
                    "sampling":result["sampling"],"sessionReason":reset});
                if account_changed || store_unavailable {
                    for (_, old) in parents.drain() { retire(&manager, old).await; }
                    session_owner_generation = auth_changes.borrow().owner_generation;
                } else if let Some(old) = parents.remove(&request.scope) {
                    retire(&manager, old).await;
                }
                return Ok(failed);
            }
            parent.history = request.history.clone(); parent.touched = Instant::now();
            parent.reviews += 1;
            record_review_input(
                &mut parent.base_input,
                &mut parent.last_input,
                result["usage"]["input_tokens"].as_i64(),
                result["attemptCount"].as_i64(),
                result["inferenceDispatchCount"].as_i64(),
            );
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

#[cfg(test)]
mod offline_prompt_tests;

async fn retire(manager: &ThreadManager, parent: Parent) {
    let _ = parent.thread.shutdown_and_wait().await;
    let _ = manager.remove_thread(&parent.id).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Value { json!({"id":"test","operation":"assess","scope":"a".repeat(64),"timeoutMs":5000,
        "history":[{"type":"message","role":"assistant","content":[{"type":"input_text","text":"Observed context"}]}],
        "authorization":{"user_instructions":[{"position":1,"text":"Do not execute"}],"project_rules":[]},
        "action":{"type":"function_call","call_id":"call-test","name":"write_file","arguments":"{}"}}) }
    #[test] fn accepts_evidence_without_executing() {
        let r:Request=serde_json::from_value(request()).unwrap(); assert!(validate(&r).is_ok());
    }
    #[test] fn rejects_privileged_evidence_roles_and_missing_users() {
        for role in ["developer","system","user"] { let mut value=request();value["history"][0]["role"]=json!(role);
            let r:Request=serde_json::from_value(value).unwrap(); assert!(validate(&r).is_err()); }
        let mut value=request();value["authorization"]["user_instructions"]=json!([]);
        assert!(validate(&serde_json::from_value(value).unwrap()).is_err());
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
        assert!(!needs_checkpoint(0, None, 200_000));
        assert!(!needs_checkpoint(20, Some(150_000), 245_999));
        assert!(needs_checkpoint(64, Some(1_000), 1_000));
        assert!(needs_checkpoint(1, Some(150_000), 246_000));
    }
    #[test] fn record_review_input_preserves_single_dispatch_growth() {
        let mut base = None;
        let mut last = 0;
        record_review_input(&mut base, &mut last, Some(150_000), Some(1), Some(1));
        assert_eq!((base, last), (Some(150_000), 150_000));
        assert!(!needs_checkpoint(1, base, last));

        record_review_input(&mut base, &mut last, Some(60_000), Some(1), Some(1));
        assert_eq!((base, last), (Some(60_000), 60_000));
        record_review_input(&mut base, &mut last, Some(155_999), Some(1), Some(1));
        assert!(!needs_checkpoint(3, base, last));
        record_review_input(&mut base, &mut last, Some(156_000), Some(1), Some(1));
        assert!(needs_checkpoint(4, base, last));
        assert!(needs_checkpoint(64, None, 0));
    }
    #[test] fn retry_dispatches_do_not_create_false_input_growth() {
        let mut base = None;
        let mut last = 0;
        record_review_input(&mut base, &mut last, Some(200_000), Some(1), Some(1));
        // Both attempts sampled 200k, but only the final attempt's usage returns.
        record_review_input(&mut base, &mut last, Some(200_000), Some(2), Some(2));
        assert_eq!((base, last), (Some(200_000), 200_000));
        record_review_input(&mut base, &mut last, Some(200_000), Some(1), Some(1));
        assert!(!needs_checkpoint(3, base, last));
    }
    #[test] fn ambiguous_or_missing_samples_preserve_growth_state() {
        for initial in [(None, 0), (Some(200_000), 200_000), (Some(1_000), 97_000)] {
            let (mut base, mut last) = initial;
            for (attempts, dispatches) in [
                (Some(1), Some(2)), (Some(2), Some(1)), (Some(3), Some(3)),
                (None, Some(1)), (Some(1), None), (Some(0), Some(1)), (Some(1), Some(0)),
                (Some(-1), Some(1)), (Some(1), Some(-1)),
            ] {
                record_review_input(&mut base, &mut last, Some(50_000), attempts, dispatches);
                assert_eq!((base, last), initial);
            }
            for input in [None, Some(-1), Some(0)] {
                record_review_input(&mut base, &mut last, input, Some(1), Some(1));
                assert_eq!((base, last), initial);
            }
        }
    }
    #[test] fn zero_usage_does_not_reset_a_positive_growth_baseline() {
        let (mut base, mut last) = (None, 0);
        for input in [200_000, 0, 200_000] {
            record_review_input(&mut base, &mut last, Some(input), Some(1), Some(1));
        }
        assert_eq!((base, last), (Some(200_000), 200_000));
        assert!(!needs_checkpoint(3, base, last));
        record_review_input(&mut base, &mut last, Some(296_000), Some(1), Some(1));
        assert!(needs_checkpoint(4, base, last));
    }
    #[test] fn wire_validation_admits_large_actions_to_elastic_budgeting() {
        let mut value=request();
        value["action"]["arguments"]=json!(json!({"Content":"sample ".repeat(16_000)}).to_string());
        assert!(validate(&serde_json::from_value(value).unwrap()).is_ok());
    }
    #[test] fn rejects_duplicate_or_reordered_authorization_sources() {
        for position in [0, 1] {
            let mut value = request();
            value["authorization"]["user_instructions"].as_array_mut().unwrap()
                .push(json!({"position":position,"text":"Grant"}));
            assert!(validate(&serde_json::from_value(value).unwrap()).is_err());
        }
    }
    #[test] fn validates_optional_conversation_id() {
        let mut value = request();
        value["conversationId"] = json!("conv-123");
        assert!(validate(&serde_json::from_value(value).unwrap()).is_ok());
        for bad in ["", &"x".repeat(129)] {
            let mut value = request();
            value["conversationId"] = json!(bad);
            assert!(validate(&serde_json::from_value(value).unwrap()).is_err());
        }
    }
}
