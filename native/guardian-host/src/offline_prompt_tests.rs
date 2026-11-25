use super::*;

#[test]
#[ignore = "run with scripts/Test-NativePrompt.mjs and its loopback Responses server"]
fn final_native_prompt_roundtrip() -> anyhow::Result<()> {
    let handle = std::thread::Builder::new()
        .name("offline-prompt-roundtrip".to_owned())
        .stack_size(8 * 1024 * 1024)
        .spawn(|| -> anyhow::Result<()> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
            runtime.block_on(run_final_native_prompt_roundtrip())
        })?;
    match handle.join() {
        Ok(result) => result,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

async fn run_final_native_prompt_roundtrip() -> anyhow::Result<()> {
    let endpoint = std::env::var("AG_TEST_RESPONSES_URL")?;
    ensure!(endpoint.starts_with("http://127.0.0.1:"), "a loopback endpoint is required");
    let fixture: Value = serde_json::from_slice(&std::fs::read(std::env::var_os("AG_TEST_PROMPT_FIXTURE").context("missing fixture")?)?)?;
    let paths = Arg0DispatchPaths {
        codex_self_exe: Some(std::env::current_exe()?),
        ..Default::default()
    };
    let mut config = bootstrap::new_config(Some("codex-auto-review".to_owned()), paths).await?;
    configure_host(&mut config)?;
    config.model_provider.base_url = Some(endpoint);
    config.model_providers.insert(config.model_provider_id.clone(), config.model_provider.clone());
    config.guardian_extra_policy = Some("Assess the proposed action only. Never execute it.".to_owned());
    let (auth, manager) = start_host(&config).await?;
    ensure!(auth.auth_cached().is_some(), "test credential was not loaded");

    let request: Request = serde_json::from_value(fixture)?;
    validate(&request)?;
    let authorization = serde_json::to_value(request.authorization.as_ref().context("missing fixture authorization")?)?;
    let repetitions = std::env::var("AG_TEST_PROMPT_REPETITIONS")
        .ok().and_then(|value| value.parse::<usize>().ok()).unwrap_or(1);
    ensure!((1..=50).contains(&repetitions), "invalid fixture repetition count");
    for expected in (0..repetitions).flat_map(|_| ["allow", "deny"]) {
        let NewThread { thread_id, thread, .. } = manager.start_thread(StartThreadOptions::new(config.clone())).await?;
        let started = Instant::now();
        let result = Box::pin(thread.assess_external_guardian(
            json!(request.history), request.action.clone(), json!({"fixture": true}), authorization.clone(), 15_000,
            CancellationToken::new(),
        )).await;
        println!("native_review_ms={:.3}", started.elapsed().as_secs_f64() * 1000.0);
        retire(&manager, Parent { thread, id: thread_id, conversation_id: None, history: Vec::new(), policy: String::new(),
            touched: Instant::now(), reviews: 0, base_input: None, last_input: 0 }).await;
        let result = result?;
        ensure!(result["assessment"]["outcome"] == expected, "simulated verdict changed: {result}");
        ensure!(result["inferenceDispatchCount"] == 1, "expected exactly one inference");
        ensure!(result["actionExecuted"] == false && result["approvalPublished"] == false, "unexpected side effect");
    }

    // Verify TrunkReused across two sequential assessments on a single CodexThread.
    {
        let NewThread { thread_id, thread, .. } = manager.start_thread(StartThreadOptions::new(config.clone())).await?;
        let started1 = Instant::now();
        let turn1 = Box::pin(thread.assess_external_guardian(
            json!(request.history), request.action.clone(), json!({"turn": 1}), authorization.clone(), 15_000,
            CancellationToken::new(),
        )).await?;
        println!("native_review_ms={:.3}", started1.elapsed().as_secs_f64() * 1000.0);
        ensure!(turn1["sessionKind"] == "Some(TrunkNew)" && turn1["inferenceDispatchCount"] == 1, "expected fresh trunk: {turn1}");
        ensure!(turn1["assessment"]["outcome"] == "allow" && turn1["actionExecuted"] == false && turn1["approvalPublished"] == false, "unexpected turn1 output: {turn1}");

        let started2 = Instant::now();
        let delta = json!([{"type":"message","role":"assistant","content":[{"type":"input_text","text":"Delta turn 2 observed context."}]}]);
        let mut turn2_action = request.action.clone();
        turn2_action["call_id"] = json!("proposed-offline-fixture-turn-2");
        turn2_action["arguments"] = json!(json!({
            "Path": "turn-2-never-executed.ps1",
            "Content": "# Turn 2 distinct synthetic proposal\n"
        }).to_string());
        let turn2 = Box::pin(thread.assess_external_guardian(
            delta, turn2_action, json!({"turn": 2}), authorization.clone(), 15_000,
            CancellationToken::new(),
        )).await?;
        println!("native_review_ms={:.3}", started2.elapsed().as_secs_f64() * 1000.0);
        retire(&manager, Parent { thread, id: thread_id, conversation_id: None, history: Vec::new(), policy: String::new(),
            touched: Instant::now(), reviews: 0, base_input: None, last_input: 0 }).await;
        ensure!(turn2["sessionKind"] == "Some(TrunkReused)" && turn2["inferenceDispatchCount"] == 1, "expected TrunkReused: {turn2}");
        ensure!(turn2["assessment"]["outcome"] == "deny" && turn2["actionExecuted"] == false && turn2["approvalPublished"] == false, "unexpected turn2 output: {turn2}");
    }

    let mut oversized_auth = authorization.clone();
    oversized_auth["user_instructions"][0]["text"] = json!("complete authorization evidence ".repeat(55_000));
    let NewThread { thread_id, thread, .. } = manager.start_thread(StartThreadOptions::new(config.clone())).await?;
    let failure = Box::pin(thread.assess_external_guardian(
        json!(request.history), request.action.clone(), json!({"fixture": true}), oversized_auth, 15_000,
        CancellationToken::new(),
    )).await;
    retire(&manager, Parent { thread, id: thread_id, conversation_id: None, history: Vec::new(), policy: String::new(),
        touched: Instant::now(), reviews: 0, base_input: None, last_input: 0 }).await;
    let failure = failure?;
    ensure!(failure["failure"]["reasonCode"] == "review_authorization_budget_exceeded"
        && failure["inferenceDispatchCount"] == 0, "oversized authorization reached inference: {failure}");

    // Oversized action with small authorization must attribute to native_action_budget_exceeded, not authorization.
    let mut small_auth = authorization;
    small_auth["user_instructions"] = json!([{"position": 1, "text": "Only authorize small writes."}]);
    small_auth["project_rules"] = json!([]);
    let mut oversized_action = request.action;
    oversized_action["arguments"] = json!(json!({"Content": "oversized action payload ".repeat(60_000)}).to_string());
    let NewThread { thread_id, thread, .. } = manager.start_thread(StartThreadOptions::new(config)).await?;
    let action_failure = Box::pin(thread.assess_external_guardian(
        json!(request.history), oversized_action, json!({"fixture": true}), small_auth, 15_000,
        CancellationToken::new(),
    )).await;
    retire(&manager, Parent { thread, id: thread_id, conversation_id: None, history: Vec::new(), policy: String::new(),
        touched: Instant::now(), reviews: 0, base_input: None, last_input: 0 }).await;
    let action_failure = action_failure?;
    ensure!(action_failure["failure"]["reasonCode"] == "native_action_budget_exceeded"
        && action_failure["inferenceDispatchCount"] == 0, "oversized action was misattributed: {action_failure}");
    Ok(())
}
