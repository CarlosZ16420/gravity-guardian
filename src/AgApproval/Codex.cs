using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public interface IReviewer
{
    Task<string> ReviewAsync(ReviewInput input, CancellationToken ct);
    Task InvalidateAsync(ReviewInput input,CancellationToken ct)=>Task.CompletedTask;
}

public sealed class CodexReviewer : IReviewer
{
    private readonly Settings settings;
    private readonly Policy policy;
    private readonly ReviewerSessions sessions;
    private readonly bool forceIsolated;
    private readonly SemaphoreSlim invocationLock=new(1);
    public CodexReviewer(Settings settings, Policy policy, bool forceIsolated = false) { this.settings = settings; this.policy = policy; this.forceIsolated = forceIsolated; sessions=new(settings); }

    public async Task<string> ReviewAsync(ReviewInput input, CancellationToken ct)
    {
        await invocationLock.WaitAsync(ct);
        ReviewerInvocation? invocation=null;
        try
        {
            if(!forceIsolated&&settings.EnableReviewerSessions&&Json.Text(JsonNode.Parse(input.Prompt),"schema_version")=="2.0")
            {
                invocation=sessions.Prepare(input);
                var reconstructed=ReviewerSessions.Reconstruct(JsonNode.Parse(invocation.Prompt)!.AsObject(),invocation.State.Evidence);
                if(!JsonNode.DeepEquals(reconstructed,invocation.Snapshot))throw new InvalidDataException("Reviewer transport did not preserve the review input");
                if(settings.DetailedLogsActive)
                    await Audit.AppendAsync(settings,new{at=DateTimeOffset.UtcNow,@event="review_transport",requestId=input.Id,conversationId=input.Conversation,
                        version=ReviewerSessions.Version,mode=invocation.Mode,sequence=invocation.Sequence,expectedThreadId=invocation.ExpectedThreadId,
                        activeEvidence=invocation.ActiveEvidence,addedEvidence=invocation.AddedEvidence,wire=JsonNode.Parse(invocation.Prompt)},ct);
            }
            var result=await RunAsync(input,invocation,ct);
            if(invocation!=null&&(invocation.ThreadIdentityConflict||!Guid.TryParse(invocation.ReportedThreadId,out _)||invocation.ExpectedThreadId!=null&&invocation.ExpectedThreadId!=invocation.ReportedThreadId))
                throw new InvalidDataException("Reviewer returned an unexpected session identity");
            _=policy.Apply(result,input.Id,input.Hash);
            if(invocation!=null)sessions.Commit(invocation,result);
            return result;
        }
        catch{if(invocation!=null)sessions.Retire(invocation.State);throw;}
        finally{invocationLock.Release();}
    }

    private async Task<string> RunAsync(ReviewInput input,ReviewerInvocation? invocation, CancellationToken ct)
    {
        var watch = Stopwatch.StartNew();
        long? processStartedMs = null, inputSentMs = null;
        string completionSource = "none";
        bool terminatedAfterCompletedTurn = false;
        var parent = Path.GetFullPath(Path.Combine(settings.DataDirectory, "runtime"));
        var run = invocation?.State.Directory??Path.Combine(parent, Guid.NewGuid().ToString("N"));
        var document=JsonNode.Parse(invocation?.Prompt??input.Prompt)!.AsObject();
        var currentReview=invocation==null?document:document["current_review"]!.AsObject();
        // The authoritative copy is already in model_instructions_file. Keep the original
        // document for bindings, audit, and session reconstruction.
        if(Json.Text(currentReview,"schema_version")=="2.0"&&currentReview["adapter"] is JsonObject adapter)
            adapter.Remove("instructions");
        var prompt=document.ToJsonString(Json.PromptOptions);
        Directory.CreateDirectory(run);
        var instructionPath = Path.Combine(run, "reviewer.md");
        var schemaPath = Path.Combine(run, "output.schema.json");
        var outputPath = Path.Combine(run, "result.json");
        if(File.Exists(outputPath))File.Delete(outputPath);
        // Codex exec's strict response-format transport requires every property to be required.
        // Preserve the upstream decision fields and policy; only expand the low-risk shorthand on the wire.
        var transportSchema = policy.Schema.DeepClone();
        transportSchema["required"] = new JsonArray("risk_level", "user_authorization", "outcome", "rationale");
        var transportNote = "\n\nCLI transport requirement: include all four assessment fields (risk_level, user_authorization, outcome, rationale) in every final JSON response, including low-risk allows. This only expands the low-risk shorthand; the security policy and allow/deny rules are unchanged.\n";
        var legacyReplay=Json.Text(JsonNode.Parse(input.Prompt),"schema_version")=="1.0";
        await File.WriteAllTextAsync(instructionPath, policy.Instructions + transportNote + (legacyReplay?"":"\n\nIntegration adapter ("+ReviewAdapter.Version+"): "+ReviewAdapter.Instructions)+(invocation==null?"":"\n\n"+ReviewerSessions.Instructions), ct);
        await File.WriteAllTextAsync(schemaPath, transportSchema.ToJsonString(), ct);
        var start = new ProcessStartInfo(settings.CodexPath) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), WorkingDirectory = run
        };
        foreach (var arg in settings.CodexPrefixArguments) start.ArgumentList.Add(arg);
        foreach (var arg in new[] { "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", "read-only", "--model", settings.Model, "--output-schema", schemaPath,
            "--output-last-message", outputPath, "--json", "--color", "never" }) start.ArgumentList.Add(arg);
        if(invocation==null)start.ArgumentList.Add("--ephemeral");
        void Config(string key, object value) { start.ArgumentList.Add("-c"); start.ArgumentList.Add(key + "=" + Json.Encode(value)); }
        Config("model_reasoning_effort", settings.Effort);
        Config("model_instructions_file", instructionPath);
        Config("developer_instructions", "");
        Config("approval_policy", "never");
        Config("project_doc_max_bytes", 0);
        Config("web_search", "disabled");
        Config("notify", Array.Empty<string>());
        Config("shell_environment_policy.inherit", "core");
        Config("shell_environment_policy.ignore_default_excludes", false);
        foreach (var feature in new[] { "apps", "plugins", "hooks", "memories", "multi_agent", "multi_agent_v2", "computer_use", "browser_use",
            "in_app_browser", "image_generation", "code_mode", "code_mode_host", "workspace_dependencies", "sleep_tool", "skill_search", "shell_snapshot" })
            Config("features." + feature, false);
        Config("features.skip_host_skill_discovery", true);
        // No user/project execpolicy is loaded; investigation remains inside Codex's read-only sandbox.
        Config("sandbox_workspace_write.network_access", false);
        if(invocation?.ExpectedThreadId!=null){start.ArgumentList.Add("resume");start.ArgumentList.Add(invocation.ExpectedThreadId);}
        start.ArgumentList.Add("-");
        start.Environment["CODEX_HOME"] = settings.CodexHome;
        if (!string.IsNullOrWhiteSpace(settings.Proxy))
        { start.Environment["HTTP_PROXY"] = settings.Proxy; start.Environment["HTTPS_PROXY"] = settings.Proxy; }
        using var process = new Process { StartInfo = start };
        var usage = new CliUsage();
        var errors = new BoundedTextCapture();
        Task? stdout = null, stderr = null;
        bool started = false;
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Cannot start Codex");
            started = true;
            processStartedMs = watch.ElapsedMilliseconds;
            stdout = usage.ReadAsync(process.StandardOutput);
            stderr = errors.ReadAsync(process.StandardError);
            await process.StandardInput.WriteAsync(prompt.AsMemory(), ct);
            process.StandardInput.Close();
            inputSentMs = watch.ElapsedMilliseconds;
            var exit = process.WaitForExitAsync(CancellationToken.None);
            await Task.WhenAny(exit, usage.Completion).WaitAsync(ct);
            if (usage.Completion.IsCompletedSuccessfully && !await usage.Completion)
                throw new InvalidOperationException("Codex reported a failed turn; no approval was applied. "+usage.TerminalError);
            if (usage.Completion.IsCompletedSuccessfully && await usage.Completion && usage.CompletedAssessment != null)
            {
                // A successful terminal event plus its final agent message is the review result.
                // CLI telemetry/shutdown may outlive the completed turn. Do not discard a valid
                // assessment merely because that cleanup has not exited yet.
                await Task.WhenAny(exit, Task.Delay(TimeSpan.FromSeconds(2), ct)).WaitAsync(ct);
                ct.ThrowIfCancellationRequested();
                if (usage.HasTurnFailure || (process.HasExited && process.ExitCode != 0))
                    throw new InvalidOperationException("Codex failed after reporting a completed review; no approval was applied");
                completionSource = "completed_turn_agent_message";
                terminatedAfterCompletedTurn = !process.HasExited;
                return usage.CompletedAssessment;
            }
            await exit.WaitAsync(ct);
            await Task.WhenAll(stdout, stderr);
            if (process.ExitCode != 0) throw new InvalidOperationException($"Codex review process exited with code {process.ExitCode}; no approval was applied");
            if (usage.HasTurnFailure) throw new InvalidOperationException("Codex reported a failed turn; no approval was applied");
            if (!File.Exists(outputPath) || new FileInfo(outputPath).Length > 16384)
                throw new InvalidDataException("Codex final assessment is missing or too large");
            completionSource = "successful_exit_output_file";
            return await File.ReadAllTextAsync(outputPath, ct);
        }
        finally
        {
            try { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } }
            catch (InvalidOperationException) { }
            if (started)
            {
                // Drain after exit/kill too, so a reported usage event survives a later failure or timeout.
                try { await Task.WhenAll(stdout!, stderr!); }
                catch (Exception e) when (e is IOException or ObjectDisposedException) { }
                var nativeUsage=usage.Snapshot();var billedUsage=(JsonObject)nativeUsage.DeepClone();
                bool accountingValid=true;
                if(invocation?.ExpectedThreadId!=null)
                {
                    try{billedUsage=CliUsage.SessionDelta(nativeUsage,invocation.State.NativeUsage??throw new InvalidDataException("Missing session usage baseline"));}
                    catch(Exception e)when(e is InvalidDataException or OverflowException)
                    {
                        accountingValid=false;billedUsage["status"]="invalid";billedUsage["source"]="codex_exec.turn.completed.cumulative_difference";billedUsage["accountingError"]=e.Message;
                        foreach(var field in new[]{"inputTokens","cachedInputTokens","outputTokens","reasoningOutputTokens","totalTokens"})billedUsage[field]=null;
                    }
                }
                if(invocation!=null)
                {
                    var snapshot=nativeUsage;invocation.ReportedThreadId=usage.ThreadId;invocation.NativeUsage=nativeUsage;
                    invocation.ThreadIdentityConflict=usage.ThreadIdConflict;
                    invocation.LastInputTokens=billedUsage["inputTokens"]?.GetValue<long>()??long.MaxValue;
                    invocation.Reusable=completionSource!="none"&&!terminatedAfterCompletedTurn&&!usage.HasTurnFailure&&!usage.ThreadIdConflict&&
                        accountingValid&&process.HasExited&&process.ExitCode==0&&Json.Text(snapshot,"status")=="reported"&&snapshot["reportedTurns"]!.GetValue<int>()==1;
                }
                try { await Audit.AppendAsync(settings, new { at = DateTimeOffset.UtcNow,
                    @event = "review_usage", requestId = input.Id, conversationId = input.Conversation,
                    tool = input.Tool, model = settings.Model, effort = settings.Effort,
                    processExitCode = process.HasExited ? (int?)process.ExitCode : null, usage = billedUsage,cliCumulativeUsage=invocation==null?null:nativeUsage,
                    modelCallEvidence=usage.HasStartedTurn||nativeUsage["observedEvents"]!.GetValue<int>()>0||usage.CompletedAssessment!=null,
                    process = new { processStartedMs, inputSentMs, elapsedMs = watch.ElapsedMilliseconds,
                        promptBytes = Encoding.UTF8.GetByteCount(prompt), completionSource, terminatedAfterCompletedTurn,
                        reviewerThreadId=usage.ThreadId,transportMode=invocation?.Mode??"isolated",transportSequence=invocation?.Sequence,
                        stream = usage.Diagnostics(), stderr = errors.Snapshot() } }, CancellationToken.None); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { Console.Error.WriteLine("Cannot persist CLI token usage log"); }
            }
            // Only this invocation's generated directory, after verifying containment.
            if (run.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                try { Directory.Delete(run, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

}

public sealed class ReviewGate(Settings settings, Policy policy, IReviewer reviewer)
{
    private readonly SemaphoreSlim serial = new(1);
    private int waiting;
    public async Task<GateResponse> ReviewAsync(JsonNode payload, CancellationToken ct)
    {
        string id = Guid.NewGuid().ToString("N"), actionHash = "";
        var watch = Stopwatch.StartNew();
        GateResponse result;
        bool acquired = false, queued=false;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(settings.ReviewTimeoutSeconds));
        ReviewInput? input = null;
        string? assessmentText=null;
        string phase = "context";
        long? queueMs = null, contextReadyMs = null, assessmentReadyMs = null;
        ReviewRoute? route = null;
        bool modelInvoked=false;
        long? reviewerStartedMs=null,reviewerMs=null;
        object? guardState=null;
        DenialGuard? guard=null;
        GateResponse? policyResult=null;
        JsonObject? failure=null;
        try
        {
            object receivedEvent = settings.DetailedLogsActive
                ? new { at=DateTimeOffset.UtcNow, @event="review_received", requestId=id, payload }
                : new { at=DateTimeOffset.UtcNow, @event="review_received", requestId=id, conversationId=Json.Text(payload,"conversationId"), stepIdx=payload["stepIdx"]?.DeepClone(), tool=Json.Text(payload["toolCall"],"name") };
            await Audit.TryAppendAsync(settings, receivedEvent, deadline.Token);
            try
            {
                input = await ReviewContext.BuildAsync(payload, settings, deadline.Token,id,policy.HashFor(settings),includeNativeState:false);
                contextReadyMs = watch.ElapsedMilliseconds;
                id = input.Id; actionHash = input.Hash;
                phase = "routing";
                route = await ReviewRouting.EvaluateAsync(input,settings,deadline.Token);
            }
            catch(InvalidDataException e)when(IsRecoverableTranscriptAnomaly(e.Message))
            {
                var fallback=await TryEvaluateFallbackNativeRouteAsync(payload,settings,deadline.Token);
                if(fallback is not {Route.Route:"native"})throw;
                contextReadyMs = watch.ElapsedMilliseconds;
                actionHash = fallback.Value.ActionHash;
                route = fallback.Value.Route;
            }
            if(settings.DetailedLogsActive || route.Route != "native")
                await Audit.TryAppendAsync(settings,new {at=DateTimeOffset.UtcNow,@event="review_route",requestId=id,
                    conversationId=input?.Conversation??Json.Text(payload,"conversationId"),tool=input?.Tool??Json.Text(payload["toolCall"],"name"),route=route.Route,ruleId=route.RuleId,ruleVersion=ReviewRoute.Version,reason=route.Reason},deadline.Token);
            if(route.Route!="native")
            {
                phase="queue";
                queued=true;
                if(Interlocked.Increment(ref waiting)>settings.MaxQueue)
                    throw new NativeReviewFailure("Review queue is full.",new JsonObject{["reasonCode"]="queue_overload"});
                bool waited=await serial.WaitAsync(0,deadline.Token)==false;
                var queueWatch=Stopwatch.StartNew();
                if(waited)await serial.WaitAsync(deadline.Token);
                acquired=true;queueMs=queueWatch.ElapsedMilliseconds;
                if(settings.ReviewerBackend=="NativeGuardian"&&settings.EnableNativeState)
                {
                    var bound=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.HashFor(settings));
                    if(bound.ActionFingerprint!=input!.ActionFingerprint||bound.MaterialRevision!=input.MaterialRevision||bound.AuthorizationRevision!=input.AuthorizationRevision)
                        throw new InvalidDataException("Evidence changed before the native state was bound; submit a current request");
                    input=bound;
                }
                else if(waited)
                {
                    var fresh=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.HashFor(settings));
                    if(fresh.ActionFingerprint!=input!.ActionFingerprint||fresh.MaterialRevision!=input.MaterialRevision||fresh.AuthorizationRevision!=input.AuthorizationRevision)
                        throw new InvalidDataException("Evidence changed while this request was queued; submit a current request");
                    input=fresh;
                }
            }
            else queueMs=0;
            phase="audit";
            if(input!=null && settings.DetailedLogsActive)
                await Audit.TryAppendAsync(settings,new { at=DateTimeOffset.UtcNow, @event="review_context",requestId=id,actionHash,model=route.Route=="model"?settings.Model:null,effort=route.Route=="model"?settings.Effort:null,policyHash=policy.HashFor(settings),adapterInstructionHash=ReviewAdapter.Hash,reviewInput=JsonNode.Parse(input.Prompt),sourceUserRecords=input.SourceUserRecords },deadline.Token);
            if(route.Route=="native") result=GateResponse.Delegate(id,actionHash,route);
            else
            {
                var modelInput=input??throw new InvalidDataException("Missing review input");
                phase="denial_guard";
                guard=await DenialGuard.AcquireAsync(settings,modelInput,policy.HashFor(settings),deadline.Token);
                guardState=guard.Snapshot();
                if(guard.IsBlocked(modelInput))result=GateResponse.Repeated(id,actionHash,guard.RecordedReason(modelInput)??"Recorded policy denial");
                else
                {
                    await guard.BeginAsync(modelInput,deadline.Token);
                    phase = "reviewer";reviewerStartedMs=watch.ElapsedMilliseconds;
                    modelInvoked=true;
                    try
                    {
                        assessmentText = await reviewer.ReviewAsync(modelInput with{ReviewBudgetMs=Math.Max(1,settings.ReviewTimeoutSeconds*1000-(int)watch.ElapsedMilliseconds)}, deadline.Token);
                    }
                    catch(NativeReviewFailure nrf) when (IsNativeSectionLimitFailure(nrf) && File.Exists(settings.CodexPath))
                    {
                        var cliInput = ReviewContext.PrepareCliFallback(modelInput, settings);
                        assessmentText = await new CodexReviewer(settings, policy, forceIsolated: true)
                            .ReviewAsync(cliInput with{ReviewBudgetMs=Math.Max(1,settings.ReviewTimeoutSeconds*1000-(int)watch.ElapsedMilliseconds)}, deadline.Token);
                    }
                    assessmentReadyMs = watch.ElapsedMilliseconds;reviewerMs=assessmentReadyMs-reviewerStartedMs;
                    phase = "assessment";
                    result = policy.Apply(assessmentText, id, actionHash);policyResult=result;
                    phase="denial_guard";
                    try{await guard.RecordAsync(modelInput,result.Decision=="auto_approve",result.Reason,deadline.Token);}
                    catch(Exception e)when(e is IOException or UnauthorizedAccessException or OperationCanceledException)
                    {Console.Error.WriteLine("Could not persist duplicate verdict record");}
                    guardState=guard.Snapshot();
                }
            }
        }
        catch (OperationCanceledException) { result=policyResult?.Decision=="deny"?policyResult:
            GateResponse.Failure(id,actionHash,"Review deadline expired or the request was cancelled.",ct.IsCancellationRequested?"review_cancelled":"review_timeout"); }
        catch (Exception e) when (e is IOException or InvalidDataException or InvalidOperationException or System.Text.Json.JsonException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or FormatException or ArgumentException)
        {
            failure=(e as NativeReviewFailure)?.Details;
            var code=e switch{
                NativeReviewFailure native=>native.Code,
                NativeStateUnavailableException state=>state.Code,
                _=>phase switch {"reviewer" when e is InvalidDataException=>"adapter_incompatible","reviewer"=>"reviewer_unavailable",
                    "assessment"=>"assessment_invalid","queue" when acquired=>"action_invalidated","denial_guard"=>"audit_failed",_=>"context_invalid"}
            };
            if(policyResult?.Decision!="deny"&&IsOversizedSingleRequest(e))
                result=GateResponse.OversizedForAgentRetry(id,actionHash,e.Message);
            else
                result=policyResult?.Decision=="deny"?policyResult:code is "action_invalidated" or "action_mismatch" or "adapter_incompatible" or "context_invalid" or
                    "state_not_ready" or "upstream_policy_blocked" or "review_cancelled" or "review_timeout" or "audit_failed"
                    ?GateResponse.Failure(id,actionHash,e.Message,code)
                    :GateResponse.NeedsHuman(id,actionHash,e.Message,code);
            // Antigravity applies its own Always Allow, Ask and Deny rules after
            // this opt-in handoff. A stored Guardian denial never reaches this branch.
            if(input!=null&&phase is ("reviewer" or "assessment")&&policyResult==null&&(e is NativeReviewFailure||code=="assessment_invalid")&&
                settings.EnableNativeAskHandoff&&code is ("upstream_unavailable" or "rate_limited" or "assessment_invalid" or "reviewer_unavailable"))
                result=GateResponse.NativeAsk(id,actionHash,e.Message,code);
        }
        finally {
            if(guard!=null)
            {
                if(guard.HasPending&&policyResult==null)
                    try{await guard.CancelPendingAsync(deadline.Token);}
                    catch(Exception e)when(e is IOException or UnauthorizedAccessException or OperationCanceledException){Console.Error.WriteLine("Interrupted request left for recovery");}
                await guard.DisposeAsync();
            }
            if (acquired) serial.Release();
            if (queued) Interlocked.Decrement(ref waiting);
        }
        reviewerMs??=reviewerStartedMs.HasValue?watch.ElapsedMilliseconds-reviewerStartedMs:null;
        // Record the candidate, then validate evidence after the final asynchronous write.
        var record = new { at = DateTimeOffset.UtcNow, @event="review_completed",requestId = id, actionHash, conversationId = input?.Conversation??Json.Text(payload,"conversationId"),
            tool = input?.Tool??Json.Text(payload["toolCall"],"name"), stepIdx=payload["stepIdx"]?.DeepClone(),status = result.Status,decision=result.Decision,reason=result.Reason,reasonCode=result.ReasonCode,assessmentText,hookResponse=result.HookOutput, policyHash = policy.HashFor(settings), evidenceHash = input?.EvidenceHash,
            actionFingerprint=input?.ActionFingerprint,authorizationRevision=input?.AuthorizationRevision,evidenceRevision=input?.EvidenceRevision,bindingHash=input?.BindingHash,
            materialRevision=input?.MaterialRevision,authorizationSources=input?.AuthorizationSources,nativeSegment=input?.NativeSegment,
            inputVersion=ReviewAdapter.InputVersion,adapterVersion=ReviewAdapter.Version,adapterInstructionHash=ReviewAdapter.Hash,transportVersion=ReviewAdapter.TransportVersion,
            reviewerInvoked=modelInvoked,modelCallEvidence=assessmentText!=null,reviewerMs,reviewMs=reviewerMs,guardState,
            decisionSource=policyResult!=null?"guardian":result.ReasonCode=="duplicate_policy_denial"?"recorded_guardian":route?.Route=="native"?"native_delegation":result.Decision=="ask"?"native_ask":"bridge",
            verdict=policyResult?.Decision=="auto_approve"?"allow":policyResult?.Decision??(result.ReasonCode=="duplicate_policy_denial"?"deny":null),
            hookDecision=result.Decision,rawErrorKind=failure?["rawErrorKind"],httpStatus=failure?["httpStatus"],
            retryable=failure?["retryable"],retryAfterMs=failure?["retryAfterMs"],
            model = route?.Route=="native"?null:settings.Model, effort = route?.Route=="native"?null:settings.Effort,
            route=route?.Route,ruleId=route?.RuleId,ruleVersion=ReviewRoute.Version,phase, queueMs, contextReadyMs, assessmentReadyMs,
            reviewTimeoutSeconds = settings.ReviewTimeoutSeconds, elapsedMs = watch.ElapsedMilliseconds };
        await Audit.TryAppendAsync(settings, record, deadline.Token);
        if(result.Decision is "allow" or "auto_approve" or "ask"||result.Decision=="force_ask"&&modelInvoked)
        {
            // The audit write is itself a wait; revocations arriving during it also invalidate approval.
            try
            {
                if(input!=null)
                {
                    var final=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.HashFor(settings),includeNativeState:route?.Route!="native");
                    if(final.ActionFingerprint!=input.ActionFingerprint||final.AuthorizationRevision!=input.AuthorizationRevision||final.MaterialRevision!=input.MaterialRevision)
                        throw new InvalidDataException("Review binding changed during audit commit");
                }
                else
                {
                    var finalRoute=await TryEvaluateFallbackNativeRouteAsync(payload,settings,deadline.Token);
                    if(finalRoute is not {Route.Route:"native"}||finalRoute.Value.ActionHash!=actionHash)
                        throw new InvalidDataException("Fallback native delegation binding changed during audit commit");
                }
            }
            catch(Exception e)when(e is IOException or InvalidDataException or UnauthorizedAccessException or OperationCanceledException or InvalidOperationException or System.Text.Json.JsonException)
            {
                result=GateResponse.Failure(id,actionHash,e.Message,e is OperationCanceledException?"review_timeout":"action_invalidated");
                using var auditDeadline=new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
                await Audit.TryAppendAsync(settings,new{at=DateTimeOffset.UtcNow,@event="review_invalidated",requestId=id,reasonCode=result.ReasonCode,decision=result.Decision,reason=result.Reason},auditDeadline.Token);
            }
        }
        if(input!=null&&(result.ReasonCode is "action_invalidated" or "action_mismatch" or "audit_failed")&&!deadline.IsCancellationRequested)
            await InvalidateAsync(input);
        return result;
    }
    private static bool IsNativeSectionLimitFailure(NativeReviewFailure failure)=>
        failure.Code=="native_tool_call_limit"
        ||failure.Message.Contains("evidence exceeds limits for section native_tool_call",StringComparison.Ordinal)
        ||(failure.Code=="context_invalid"&&(Json.Text(failure.Details,"rawErrorKind") is string kind&&(kind.Contains("PromptBuild",StringComparison.OrdinalIgnoreCase)||kind.Contains("InputBudget",StringComparison.OrdinalIgnoreCase))));
    private static bool IsOversizedSingleRequest(Exception e)=>
        e.Message is "Input too large"
            or "Complete action, user restrictions and rules exceed input budget"
            or "Complete review input exceeds budget"
            or "Native local history exceeds host budget; no history was silently dropped"
        ||(e is NativeReviewFailure nrf&&IsNativeSectionLimitFailure(nrf));
    private static bool IsRecoverableTranscriptAnomaly(string message)=>
        message is "Unexplained transcript step rollback; current retry segment cannot be established"
            or "Overlapping native tool proposals cannot be uniquely bound"
            or "Current request cannot be uniquely bound to the active native segment"
            or "No authenticated user task in transcript";
    private static async Task<(string ActionHash,ReviewRoute Route)?> TryEvaluateFallbackNativeRouteAsync(JsonNode payload,Settings settings,CancellationToken ct)
    {
        if(payload["toolCall"] is not JsonObject call||Json.Text(call,"name") is not string tool||call["args"] is not JsonObject args)return null;
        if(Json.Text(payload,"conversationId") is not string conversation||!Guid.TryParse(conversation,out _))return null;
        if((payload["stepIdx"]?.GetValue<int>()??-1)<0)return null;
        if(Json.Text(payload,"transcriptPath") is not string transcriptPath)return null;
        ReviewContext.ValidateTranscriptPath(transcriptPath,conversation,settings.TranscriptRoots);
        if(payload["workspacePaths"] is not JsonArray workspace||workspace.Count==0||
            workspace.Any(w=>w is not JsonValue||!w.AsValue().TryGetValue<string>(out var p)||!Path.IsPathFullyQualified(p)))return null;
        var cwd=Json.Text(args,"Cwd")??Json.Text(args,"cwd")??workspace[0]!.GetValue<string>();
        if(!Path.IsPathFullyQualified(cwd))return null;
        cwd=Path.GetFullPath(cwd);
        var action=new JsonObject{["toolCall"]=call.DeepClone(),["stepIdx"]=payload["stepIdx"]?.DeepClone(),["conversationId"]=conversation,["workspacePaths"]=workspace.DeepClone(),["cwd"]=cwd};
        var permissions=PermissionSnapshot.Read(settings,workspace);
        var workspaces=workspace.Select(w=>w!.GetValue<string>()).ToArray();
        var route=await ReviewRouting.EvaluateRawAsync(tool,conversation,cwd,workspaces,args,permissions,settings,ct);
        return (Json.Hash(ReviewAdapter.Canonical(action)+ReviewAdapter.Canonical(permissions)),route);
    }
    private async Task InvalidateAsync(ReviewInput? input)
    {
        if(input==null)return;
        using var cleanup=new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try{await reviewer.InvalidateAsync(input,cleanup.Token);}
        catch(Exception e)when(e is IOException or OperationCanceledException){Console.Error.WriteLine("Could not invalidate reviewer state; current request remains blocked");}
    }
}

public static class Audit
{
    private static readonly SemaphoreSlim Lock = new(1);
    private static readonly Dictionary<string,(string Prefix,int Segment)> ActiveSegments = new(StringComparer.OrdinalIgnoreCase);

    public static Task TryAppendAsync(Settings settings,object value,CancellationToken ct)=>
        TryAppendAsync(settings.DataDirectory,value,ct,settings.MaxLogSegmentBytes);

    public static Task AppendAsync(Settings settings,object value,CancellationToken ct)=>
        AppendAsync(settings.DataDirectory,value,ct,settings.MaxLogSegmentBytes);

    public static async Task TryAppendAsync(string directory,object value,CancellationToken ct,int maxSegmentBytes=16*1024*1024)
    {
        try{await AppendAsync(directory,value,ct,maxSegmentBytes);}
        catch(Exception e)when(e is IOException or UnauthorizedAccessException or OperationCanceledException)
        {Console.Error.WriteLine("Cannot persist approval audit event");}
    }
    public static async Task AppendAsync(string directory, object value, CancellationToken ct, int maxSegmentBytes=16*1024*1024)
    {
        await Lock.WaitAsync(ct);
        try
        {
            var logs = Path.GetFullPath(Path.Combine(directory, "logs")); Directory.CreateDirectory(logs);
            var prefix=DateTime.UtcNow.ToString("yyyy-MM-dd");
            if(!ActiveSegments.TryGetValue(logs,out var active)||active.Prefix!=prefix)
            {
                int initial=0;
                foreach(var existing in Directory.EnumerateFiles(logs,prefix+".*.jsonl"))
                {
                    var name=Path.GetFileNameWithoutExtension(existing);
                    int dot=name.LastIndexOf('.');
                    if(dot>0&&int.TryParse(name[(dot+1)..],out int parsed)&&parsed>=initial)initial=parsed;
                }
                active=(prefix,initial);
            }
            int segment=active.Segment;
            string path=Path.Combine(logs,prefix+$".{segment:D3}.jsonl");
            while(File.Exists(path)&&new FileInfo(path).Length>=maxSegmentBytes)
            {
                segment++;
                path=Path.Combine(logs,prefix+$".{segment:D3}.jsonl");
            }
            ActiveSegments[logs]=(prefix,segment);
            await using var file = await OpenAppendAsync(path,ct);
            var record=JsonNode.Parse(Json.Encode(value))!;
            record["log_schema_version"]="2.0";
            var bytes = Encoding.UTF8.GetBytes(record.ToJsonString(Json.Options) + "\n");
            await file.WriteAsync(bytes, ct); await file.FlushAsync(ct);
        }
        finally { Lock.Release(); }
    }

    private static async Task<FileStream> OpenAppendAsync(string path,CancellationToken ct)
    {
        for(int attempt=0;;attempt++)
        {
            try { return new FileStream(path,FileMode.Append,FileAccess.Write,FileShare.Read,4096,FileOptions.WriteThrough); }
            catch(IOException e) when((e.HResult&0xffff) is 32 or 33 && attempt<80)
            { await Task.Delay(25,ct); }
        }
    }
}
