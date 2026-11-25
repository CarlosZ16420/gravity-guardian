using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public interface IReviewer
{
    Task<string> ReviewAsync(ReviewInput input, CancellationToken ct);
    Task InvalidateAsync(ReviewInput input,CancellationToken ct)=>Task.CompletedTask;
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
                input = await ReviewContext.BuildAsync(payload, settings, deadline.Token,id,policy.NativeHash,includeNativeState:false);
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
                if(settings.EnableNativeState)
                {
                    var bound=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.NativeHash);
                    if(bound.ActionFingerprint!=input!.ActionFingerprint||bound.MaterialRevision!=input.MaterialRevision||bound.AuthorizationRevision!=input.AuthorizationRevision)
                        throw new InvalidDataException("Evidence changed before the native state was bound; submit a current request");
                    input=bound;
                }
                else if(waited)
                {
                    var fresh=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.NativeHash);
                    if(fresh.ActionFingerprint!=input!.ActionFingerprint||fresh.MaterialRevision!=input.MaterialRevision||fresh.AuthorizationRevision!=input.AuthorizationRevision)
                        throw new InvalidDataException("Evidence changed while this request was queued; submit a current request");
                    input=fresh;
                }
            }
            else queueMs=0;
            phase="audit";
            if(input!=null && settings.DetailedLogsActive)
                await Audit.TryAppendAsync(settings,new { at=DateTimeOffset.UtcNow, @event="review_context",requestId=id,actionHash,model=route.Route=="model"?settings.Model:null,effort=route.Route=="model"?settings.Effort:null,policyHash=policy.NativeHash,adapterInstructionHash=ReviewAdapter.Hash,reviewInput=JsonNode.Parse(input.Prompt),sourceUserRecords=input.SourceUserRecords },deadline.Token);
            if(route.Route=="native") result=GateResponse.Delegate(id,actionHash,route);
            else
            {
                var modelInput=input??throw new InvalidDataException("Missing review input");
                phase="denial_guard";
                guard=await DenialGuard.AcquireAsync(settings,modelInput,policy.NativeHash,deadline.Token);
                guardState=guard.Snapshot();
                if(guard.IsBlocked(modelInput))result=GateResponse.Repeated(id,actionHash,guard.RecordedReason(modelInput)??"Recorded policy denial");
                else
                {
                    await guard.BeginAsync(modelInput,deadline.Token);
                    phase = "reviewer";reviewerStartedMs=watch.ElapsedMilliseconds;
                    modelInvoked=true;
                    assessmentText = await reviewer.ReviewAsync(modelInput with{ReviewBudgetMs=Math.Max(1,settings.ReviewTimeoutSeconds*1000-(int)watch.ElapsedMilliseconds)}, deadline.Token);
                    assessmentReadyMs = watch.ElapsedMilliseconds;reviewerMs=assessmentReadyMs-reviewerStartedMs;
                    phase = "assessment";
                    result = policy.Apply(assessmentText, id, actionHash);policyResult=result;
                    phase="denial_guard";
                    try
                    {
                        using var persistCt=new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
                        await guard.RecordAsync(modelInput,result.Decision=="auto_approve",result.Reason,persistCt.Token);
                    }
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
            if(policyResult?.Decision!="deny"&&IsOversizedSingleRequest(e,input?.Tool??Json.Text(payload["toolCall"],"name")))
                result=GateResponse.OversizedForAgentRetry(id,actionHash,e.Message);
            // Antigravity applies its own Always Allow, Ask and Deny rules after
            // this opt-in handoff. A stored Guardian denial never reaches this branch.
            else if(input!=null&&phase is ("reviewer" or "assessment")&&policyResult==null&&(e is NativeReviewFailure||code=="assessment_invalid")&&
                settings.EnableNativeAskHandoff&&code is ("upstream_unavailable" or "rate_limited" or "assessment_invalid" or "reviewer_unavailable"))
                result=GateResponse.NativeAsk(id,actionHash,e.Message,code);
            else
                result=policyResult?.Decision=="deny"?policyResult:code is "action_invalidated" or "action_mismatch" or "adapter_incompatible" or "context_invalid" or
                    "state_not_ready" or "upstream_policy_blocked" or "review_cancelled" or "review_timeout" or "audit_failed" or
                    "native_action_budget_exceeded" or "review_input_budget_exceeded" or "review_authorization_budget_exceeded" or "native_frame_invalid"
                    ?GateResponse.Failure(id,actionHash,e.Message,code)
                    :GateResponse.NeedsHuman(id,actionHash,e.Message,code);
        }
        finally {
            if(guard!=null)
            {
                if(guard.HasPending&&policyResult==null)
                    try
                    {
                        using var cancelCt=new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
                        await guard.CancelPendingAsync(cancelCt.Token);
                    }
                    catch(Exception e)when(e is IOException or UnauthorizedAccessException or OperationCanceledException){Console.Error.WriteLine("Interrupted request left for recovery");}
                await guard.DisposeAsync();
            }
            if (acquired) serial.Release();
            if (queued) Interlocked.Decrement(ref waiting);
        }
        reviewerMs??=reviewerStartedMs.HasValue?watch.ElapsedMilliseconds-reviewerStartedMs:null;
        // Record the candidate, then validate evidence after the final asynchronous write.
        var record = new { at = DateTimeOffset.UtcNow, @event="review_completed",requestId = id, actionHash, conversationId = input?.Conversation??Json.Text(payload,"conversationId"),
            tool = input?.Tool??Json.Text(payload["toolCall"],"name"), stepIdx=payload["stepIdx"]?.DeepClone(),status = result.Status,decision=result.Decision,reason=result.Reason,reasonCode=result.ReasonCode,assessmentText,hookResponse=result.HookOutput, policyHash = policy.NativeHash, evidenceHash = input?.EvidenceHash,
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
        using(var completedAuditDeadline=new CancellationTokenSource(TimeSpan.FromMilliseconds(500)))
            await Audit.TryAppendAsync(settings, record, completedAuditDeadline.Token);
        if(result.Decision is "allow" or "auto_approve" or "ask"||result.Decision=="force_ask"&&modelInvoked)
        {
            // The audit write is itself a wait; revocations arriving during it also invalidate approval.
            try
            {
                if(input!=null)
                {
                    var final=await ReviewContext.BuildAsync(payload,settings,deadline.Token,id,policy.NativeHash,includeNativeState:route?.Route!="native");
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
    private static bool IsOversizedSingleRequest(Exception e,string? tool)=>
        tool is ("write_file" or "edit_file" or "write_to_file" or "replace_file_content" or "multi_replace_file_content") &&
        (e.Message=="Input too large" || e is NativeReviewFailure { Code: "native_action_budget_exceeded" or "native_tool_call_limit" });
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
