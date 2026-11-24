using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public sealed class NativeReviewFailure(string message,JsonObject? failure) : IOException(message)
{
    public string Code => Json.Text(failure,"reasonCode")??"reviewer_unavailable";
    public JsonObject? Details => failure;
}

public sealed class NativeGuardianReviewer(Settings settings,Policy policy) : IReviewer,IAsyncDisposable
{
    private readonly SemaphoreSlim serial=new(1);
    private readonly Queue<string> stderr=new();
    private Process? process;
    private Task? drain;
    private long dispatches;
    private string? binaryIdentity;
    private JsonObject? runtime;
    public async Task<string> ReviewAsync(ReviewInput input,CancellationToken ct)
    {
        var budgetMs=Math.Min(input.ReviewBudgetMs??int.MaxValue,settings.ReviewTimeoutSeconds*1000);
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);deadline.CancelAfter(Math.Max(1,budgetMs));ct=deadline.Token;
        var watch=Stopwatch.StartNew();
        await serial.WaitAsync(ct);
        JsonObject? reply=null,result=null,transportFailure=null;long before=Interlocked.Read(ref dispatches);bool started=false,submitted=false;
        try
        {
            lock(stderr)stderr.Clear();
            await EnsureAsync(ct);started=true;before=Interlocked.Read(ref dispatches);
            var request=GuardianFacts.Build(input,settings,budgetMs-(int)watch.ElapsedMilliseconds-500);
            if(settings.DetailedLogsActive)
                await Audit.TryAppendAsync(settings,new{at=DateTimeOffset.UtcNow,@event="guardian_input",requestId=input.Id,conversationId=input.Conversation,
                    protocol=GuardianFacts.Protocol,wire=request,sourceRecordCount=input.NativeRecords?.Count},ct);
            var remaining=budgetMs-(int)watch.ElapsedMilliseconds-500;
            if(remaining<100)throw new OperationCanceledException("No time remains for native assessment.");
            request["timeoutMs"]=Math.Min(remaining,90000);
            submitted=true;reply=await ExchangeAsync(request,ct);
            if(reply["ok"]?.GetValue<bool>()!=true)
            {
                var failure=reply["failure"] as JsonObject;
                // The native client-facing ErrorInfo groups entitlement and quota;
                // preserve the provider's more specific typed sampling error.
                var raw=(reply["sampling"] as JsonArray)?.OfType<JsonObject>().LastOrDefault(o=>Json.Text(o,"event")=="guardian_sampling_failed");
                if(failure!=null&&raw!=null&&Json.Text(failure,"reasonCode") is ("quota_exhausted" or "entitlement_unavailable" or "rate_limited" or "upstream_unavailable" or "reviewer_unavailable"))
                {
                    var kind=Json.Text(raw,"errorKind");
                    if(Json.Text(failure,"reasonCode")=="quota_exhausted"&&kind=="usage_not_included")failure["reasonCode"]="entitlement_unavailable";
                    failure["rawErrorKind"]=raw["errorKind"]?.DeepClone();
                    failure["httpStatus"]??=raw["httpStatus"]?.DeepClone();
                }
                throw new NativeReviewFailure(Json.Text(reply,"error")??"Native Guardian failed",failure);
            }
            result=reply["result"]?.AsObject()??throw new InvalidDataException("Native Guardian result missing");
            if(result["actionExecuted"]?.GetValue<bool>()!=false||result["approvalPublished"]?.GetValue<bool>()!=false||
                result["inferenceDispatchCount"]?.GetValue<int>() is not >0||result["attemptCount"]?.GetValue<int>() is not (>=1 and <=GuardianFacts.MaxReviewAttempts)||
                Json.Text(result,"model")!=settings.Model||Json.Text(result,"effort")!=settings.Effort||
                !Guid.TryParse(Json.Text(result,"guardianThreadId"),out _))throw new InvalidDataException("Native Guardian returned invalid execution or session metadata");
            result["sessionReason"]=reply["sessionReason"]?.DeepClone();
            var text=result["assessment"]?.ToJsonString()??throw new InvalidDataException("Native Guardian assessment missing");
            _=policy.Apply(text,input.Id,input.Hash);
            return text;
        }
        catch(NativeReviewFailure failure) when(reply?["sessionRetired"] is JsonValue status &&
            status.TryGetValue<bool>(out var retired) && (retired || failure.Code is "native_tool_call_limit" or "context_invalid")){throw;}
        catch(NativeReviewFailure failure) { transportFailure=failure.Details; await StopAsync(); throw; }
        catch { await StopAsync();throw; }
        finally
        {
            try
            {
                var frame=result??reply;
                JsonObject usage;string? accountingError=null;
                try{usage=AggregateUsage(frame, result != null);}
                catch(Exception e)when(e is InvalidDataException or InvalidOperationException or OverflowException)
                {usage=AggregateUsage(null, false);usage["status"]="telemetry_invalid";accountingError=e.Message;}
                var observed=Math.Max(0,Interlocked.Read(ref dispatches)-before);
                var reported=frame?["inferenceDispatchCount"];
                long? dispatched=reported is JsonValue count&&count.TryGetValue<int>(out var n)&&n>=0?n:observed>0?observed:submitted?null:0;
                var failure=reply?["failure"]??transportFailure;
                var identity=(frame?["sampling"] as JsonArray)?.LastOrDefault(v=>v is JsonObject o&&Json.Text(o,"event")=="guardian_runtime_identity");
                var modelIdentity=identity?.DeepClone() as JsonObject;
                if(modelIdentity != null)
                {
                    modelIdentity["baseInstructionsHash"] = modelIdentity["effectivePolicyHash"]?.DeepClone();
                    modelIdentity.Remove("effectivePolicyHash");
                }
                string[] errors;lock(stderr)errors=settings.DetailedLogsActive?stderr.ToArray():stderr.TakeLast(8).ToArray();
                using var auditDeadline=new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
                await Audit.TryAppendAsync(settings,new{at=DateTimeOffset.UtcNow,@event="review_usage",requestId=input.Id,conversationId=input.Conversation,
                    backend="native_guardian",model=settings.Model,effort=settings.Effort,usage,rawNativeUsage=frame?["usage"],nativeBinarySha256=binaryIdentity,
                    upstreamCommit=GuardianFacts.UpstreamCommit,runtime=settings.DetailedLogsActive?runtime:null,baseInstructionsHash=modelIdentity?["baseInstructionsHash"],modelIdentity=settings.DetailedLogsActive?modelIdentity:null,
                    reasonCode=failure?["reasonCode"],rawErrorKind=failure?["rawErrorKind"],httpStatus=failure?["httpStatus"],retryable=failure?["retryable"],retryAfterMs=failure?["retryAfterMs"],
                    inferenceDispatchCount=dispatched,inferenceRequestCountStatus=dispatched.HasValue?"reported_or_observed":"unknown_after_submission",
                    attemptCount=frame?["attemptCount"],httpRequestCount=frame?["httpRequestCount"],
                    modelCallEvidence=dispatched>0,processStarted=started,requestSubmitted=submitted,accountingError,
                    diagnostics=new{elapsedMs=watch.ElapsedMilliseconds,completionSource=result!=null?"native_guardian_completed":reply!=null?"native_guardian_failed":"none",
                        reviewerThreadId=Json.Text(result,"guardianThreadId"),sessionKind=Json.Text(result,"sessionKind"),sessionReason=Json.Text(result??reply,"sessionReason"),
                        contextMode=Json.Text(result,"contextMode"),sampling=frame?["sampling"],stderr=errors},nativeResult=settings.DetailedLogsActive?result:null},auditDeadline.Token);
            }
            catch(Exception e)when(e is InvalidOperationException or InvalidDataException or System.Text.Json.JsonException)
            {Console.Error.WriteLine("Native Guardian telemetry could not be decoded");}
            finally{serial.Release();}
        }
    }
    public async Task InvalidateAsync(ReviewInput input,CancellationToken ct)
    {
        await serial.WaitAsync(ct);
        try
        {
            if(process==null||process.HasExited)return;
            var scope=GuardianFacts.Build(input,settings,1000)["scope"]!.DeepClone();
            var reply=await ExchangeAsync(new JsonObject{["id"]=Guid.NewGuid().ToString("N"),["operation"]="invalidate",["scope"]=scope},ct);
            if(reply["ok"]?.GetValue<bool>()!=true)throw new IOException("Native Guardian invalidation failed");
        }
        catch{await StopAsync();}
        finally{serial.Release();}
    }
    public static JsonObject NormalizeUsage(JsonNode? raw)
    {
        var result=new JsonObject{["source"]="native_guardian.last_attempt_delta",["status"]="unknown",["reportedTurns"]=0,["observedEvents"]=0,
            ["inputTokens"]=null,["cachedInputTokens"]=null,["outputTokens"]=null,["reasoningOutputTokens"]=null,["totalTokens"]=null};
        if(raw==null)return result;
        long Count(string key)=>raw[key]?.GetValue<long>() is long v&&v>=0?v:throw new InvalidDataException("Native usage missing or negative: "+key);
        var input=Count("input_tokens");var output=Count("output_tokens");var cached=Count("cached_input_tokens");var reasoning=Count("reasoning_output_tokens");var total=Count("total_tokens");
        if(cached>input||reasoning>output||total!=checked(input+output))throw new InvalidDataException("Native usage counters are inconsistent");
        result["status"]="reported";result["reportedTurns"]=1;result["observedEvents"]=1;
        result["inputTokens"]=input;result["cachedInputTokens"]=cached;result["outputTokens"]=output;result["reasoningOutputTokens"]=reasoning;result["totalTokens"]=total;
        return result;
    }
    public static JsonObject AggregateUsage(JsonObject? frame, bool completed)
    {
        string[] fields = ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"];
        var attempts = new JsonArray();
        var totals = new long[fields.Length];
        var usage = new JsonObject { ["source"] = "native_guardian.attempt_deltas", ["attempts"] = attempts };
        foreach (var field in fields) usage[field] = null;
        var count = frame?["attemptCount"] is JsonValue value && value.TryGetValue<int>(out var n)
            && n is >= 0 and <= GuardianFacts.MaxReviewAttempts ? n : (int?)null;
        usage["attemptCount"] = count;
        var failed = (frame?["sampling"] as JsonArray)?.OfType<JsonObject>()
            .Where(item => Json.Text(item, "event") == "guardian_attempt_failed").ToArray() ?? [];
        // The Rust host emits a diagnostic for every failed attempt, including a terminal
        // failure. The main report always describes the last attempt, even when retry wait expires.
        var aligned = count is > 0 && (failed.Length == count - 1 || !completed && failed.Length == count);
        var reported = 0;
        var invalid = false;
        for (int attempt = 1; attempt <= count.GetValueOrDefault(); attempt++)
        {
            var raw = attempt == count ? frame?["usage"] : aligned ? failed[attempt - 1]["usage"] : null;
            JsonObject entry;
            try { entry = NormalizeUsage(raw); }
            catch (Exception e) when (e is InvalidDataException or InvalidOperationException or OverflowException or FormatException)
            {
                entry = NormalizeUsage(null);
                entry["status"] = "telemetry_invalid";
                invalid = true;
            }
            entry.Remove("source");
            entry["attempt"] = attempt;
            attempts.Add(entry);
            if (Json.Text(entry, "status") != "reported") continue;
            for (int i = 0; i < fields.Length; i++)
                totals[i] = checked(totals[i] + entry[fields[i]]!.GetValue<long>());
            reported++;
        }
        bool complete = aligned && reported == count;
        usage["reportedTurns"] = reported;
        usage["observedEvents"] = reported;
        usage["status"] = complete ? "reported" : invalid ? "telemetry_invalid" : reported > 0 ? "partial" : "unknown";
        if (complete)
            for (int i = 0; i < fields.Length; i++) usage[fields[i]] = totals[i];
        return usage;
    }
    private async Task EnsureAsync(CancellationToken ct)
    {
        if(process is {HasExited:false})return;
        await StopAsync();
        binaryIdentity=settings.GuardianPrefixArguments.Length==0?VerifyBinary(settings.GuardianPath):"test_fixture";
        var workspace=Path.Combine(settings.DataDirectory,"guardian-workspace");Directory.CreateDirectory(workspace);
        var start=new ProcessStartInfo(settings.GuardianPath){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,
            StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8,WorkingDirectory=workspace};
        foreach(var argument in settings.GuardianPrefixArguments)start.ArgumentList.Add(argument);
        start.Environment["CODEX_HOME"]=settings.CodexHome;
        start.Environment["AG_GUARDIAN_HOST"]="1";
        foreach(var key in new[]{"OPENAI_API_KEY","CODEX_API_KEY","CODEX_AUTH_TOKEN","CODEX_GUARDIAN_REPLAY","CODEX_GUARDIAN_REPLAY_ALLOW_INFERENCE"})start.Environment.Remove(key);
        if(!string.IsNullOrWhiteSpace(settings.Proxy)){start.Environment["HTTP_PROXY"]=settings.Proxy;start.Environment["HTTPS_PROXY"]=settings.Proxy;}
        process=Process.Start(start)??throw new IOException("Cannot start native Guardian");
        lock(stderr)stderr.Clear();
        drain=DrainAsync(process.StandardError);
        using var startup=CancellationTokenSource.CreateLinkedTokenSource(ct);startup.CancelAfter(TimeSpan.FromSeconds(20));
        var ready=JsonNode.Parse(await Program.ReadLineAsync(process.StandardOutput,65536,startup.Token));
        if(ready is not JsonObject readyFrame||Json.Text(ready,"type")!="ready"||Json.Text(ready,"protocol")!=GuardianFacts.Protocol||
            Json.Text(ready,"upstreamCommit")!=GuardianFacts.UpstreamCommit||ready["toolsEnabled"]?.GetValue<bool>()!=false||
            !readyFrame.ContainsKey("inferenceDispatchCap")||ready["inferenceDispatchCap"]!=null||ready["maxAttempts"]?.GetValue<int>()!=GuardianFacts.MaxReviewAttempts)
            throw new InvalidDataException("Native Guardian handshake mismatch");
        runtime=readyFrame;
    }
    private async Task<JsonObject> ExchangeAsync(JsonObject request,CancellationToken ct)
    {
        if(process is null||process.HasExited)throw new IOException("Native Guardian process is unavailable");
        await process.StandardInput.WriteLineAsync(request.ToJsonString(Json.PromptOptions).AsMemory(),ct).WaitAsync(ct);
        await process.StandardInput.FlushAsync(ct).WaitAsync(ct);
        try
        {
            var frame=await Program.ReadLineAsync(process.StandardOutput,131072,ct).WaitAsync(ct);
            if(JsonNode.Parse(frame) is not JsonObject reply || Json.Text(reply,"id")!=Json.Text(request,"id"))
                throw new InvalidDataException("Native Guardian response has no matching request ID");
            return reply;
        }
        catch(Exception e) when(e is EndOfStreamException or InvalidDataException or System.Text.Json.JsonException)
        {
            throw new NativeReviewFailure(e.Message,new JsonObject{["reasonCode"]="native_frame_invalid",
                ["rawErrorKind"]=e is EndOfStreamException?"incomplete_frame":"invalid_frame",["retryable"]=false});
        }
    }
    public static string VerifyBinary(string executable)
    {
        ReviewContext.ValidateComponents(executable);
        var path=Path.Combine(Path.GetDirectoryName(executable)!,"SOURCE.json");ReviewContext.ValidateComponents(path);
        if(new FileInfo(path).Length>65536)throw new InvalidDataException("Native source manifest exceeds limit");
        var source=JsonNode.Parse(File.ReadAllText(path));
        if(Json.Text(source,"upstreamCommit")!=GuardianFacts.UpstreamCommit||Json.Text(source,"protocol")!=GuardianFacts.Protocol)throw new InvalidDataException("Native source identity mismatch");
        using var file=new FileStream(executable,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(file.Length>512L*1024*1024)throw new InvalidDataException("Native executable exceeds limit");
        var hash=Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(file));
        if(hash!=Json.Text(source,"binarySha256"))throw new InvalidDataException("Native executable integrity mismatch");
        return hash;
    }
    private async Task DrainAsync(StreamReader reader)
    {
        try
        {
            while(true)
            {
                var line=await Program.ReadLineAsync(reader,16384,CancellationToken.None);
                if(line.Contains("\"event\":\"guardian_inference_dispatch\"",StringComparison.Ordinal))Interlocked.Increment(ref dispatches);
                lock(stderr){stderr.Enqueue(line.Length>2048?line[^2048..]:line);while(stderr.Count>12)stderr.Dequeue();}
            }
        }
        catch(Exception e)when(e is IOException or ObjectDisposedException){ }
    }
    private async Task StopAsync()
    {
        if(process==null)return;
        try{if(!process.HasExited)process.Kill(entireProcessTree:true);await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3));}
        catch(Exception e)when(e is InvalidOperationException or System.ComponentModel.Win32Exception or TimeoutException){ }
        if(drain!=null)try{await drain.WaitAsync(TimeSpan.FromSeconds(1));}catch(TimeoutException){ }
        process.Dispose();process=null;drain=null;
    }
    public async ValueTask DisposeAsync(){await serial.WaitAsync();try{await StopAsync();}finally{serial.Release();}}
}
