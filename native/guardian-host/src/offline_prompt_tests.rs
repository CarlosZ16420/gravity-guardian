use super::*;

#[tokio::test(flavor = "current_thread")]
#[ignore = "run with scripts/Test-NativePrompt.mjs and its loopback Responses server"]
async fn final_native_prompt_roundtrip() -> anyhow::Result<()> {
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

    let mut history = fixture["history"].as_array().context("missing history")?.clone();
    annotate_user_history(&mut history)?;
    let repetitions = std::env::var("AG_TEST_PROMPT_REPETITIONS")
        .ok().and_then(|value| value.parse::<usize>().ok()).unwrap_or(1);
    ensure!((1..=50).contains(&repetitions), "invalid fixture repetition count");
    for expected in (0..repetitions).flat_map(|_| ["allow", "deny"]) {
        let NewThread { thread_id, thread, .. } = manager.start_thread(StartThreadOptions::new(config.clone())).await?;
        let started = Instant::now();
        let result = thread.assess_external_guardian(
            json!(history), fixture["action"].clone(), json!({"fixture": true}), 15_000,
            CancellationToken::new(),
        ).await;
        println!("native_review_ms={:.3}", started.elapsed().as_secs_f64() * 1000.0);
        retire(&manager, Parent { thread, id: thread_id, history: Vec::new(), policy: String::new(),
            touched: Instant::now(), reviews: 0, last_input: 0 }).await;
        let result = result?;
        ensure!(result["assessment"]["outcome"] == expected, "simulated verdict changed: {result}");
        ensure!(result["inferenceDispatchCount"] == 1, "expected exactly one inference");
        ensure!(result["actionExecuted"] == false && result["approvalPublished"] == false, "unexpected side effect");
    }
    Ok(())
}
