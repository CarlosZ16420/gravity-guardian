using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AgApproval;

public sealed class NativeStateUnavailableException(string code,string message,Exception? inner=null) : IOException(message,inner)
{
    public string Code {get;}=code;
}

/// <summary>Read-only, version-sensitive local RPC enhancement. Never supplies user authorization.</summary>
public static class AntigravityState
{
    private sealed class Cache
    {
        public string Origin="",Trajectory="";
        public int Watermark;
        public SortedDictionary<int,string> Checkpoints {get;}=[];
    }
    private static readonly ConcurrentDictionary<string,Cache> Caches=new();
    private static readonly SemaphoreSlim Serial=new(1);
    public static async Task<JsonObject> ReadAsync(Settings settings,string conversation,int step,JsonObject call,CancellationToken ct)
    {
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(settings.NativeStateTimeoutMilliseconds);
        bool acquired=false;
        string phase="discovery";
        try
        {
            await Serial.WaitAsync(deadline.Token);acquired=true;
            var origin=await DiscoverAsync(settings.NativeStateLogPath,deadline.Token);
            using var handler=new HttpClientHandler{UseProxy=false,AllowAutoRedirect=false,
                // The app's local service uses an ephemeral self-signed certificate.
                ServerCertificateCustomValidationCallback=(request,_,_,_)=>request.RequestUri is { } u&&u.Scheme=="https"&&u.Host=="127.0.0.1"};
            using var client=new HttpClient(handler){BaseAddress=origin,Timeout=Timeout.InfiniteTimeSpan};
            phase="bootstrap";
            var bootstrap=await BodyAsync(await client.GetAsync("",HttpCompletionOption.ResponseHeadersRead,deadline.Token),deadline.Token,2*1024*1024);
            var match=Regex.Match(bootstrap,"\"?csrfToken\"?\\s*:\\s*\"([^\"]+)\"");
            if(!match.Success)throw new InvalidDataException("Antigravity local service bootstrap changed");
            client.DefaultRequestHeaders.Add("x-codeium-csrf-token",match.Groups[1].Value);
            client.DefaultRequestHeaders.Add("connect-protocol-version","1");
            var cache=Caches.GetOrAdd(conversation,_=>new());
            phase="trajectory";
            JsonArray steps;int offset;
            if(cache.Origin!=origin.AbsoluteUri||cache.Trajectory.Length==0)
            {
                var response=await RpcAsync(client,"GetCascadeTrajectory",new{cascadeId=conversation,disableRehydration=true},deadline.Token);
                var trajectory=response["trajectory"]??throw new InvalidDataException("Native trajectory missing");
                cache.Trajectory=Json.Text(trajectory,"trajectoryId")??throw new InvalidDataException("Native trajectory ID missing");
                if(!Guid.TryParse(cache.Trajectory,out _))throw new InvalidDataException("Invalid native trajectory ID");
                cache.Origin=origin.AbsoluteUri;cache.Checkpoints.Clear();
                steps=trajectory["steps"] as JsonArray??throw new InvalidDataException("Native steps missing");offset=0;
                if(response["numTotalSteps"]?.GetValue<int>()!=steps.Count)throw new InvalidDataException("Native trajectory is incomplete");
            }
            else
            {
                offset=Math.Min(step,Math.Max(0,cache.Watermark-4));
                var response=await RpcAsync(client,"GetCascadeTrajectorySteps",new{cascadeId=conversation,stepOffset=offset,disableRehydration=true},deadline.Token);
                steps=response["steps"] as JsonArray??throw new InvalidDataException("Native step refresh missing");
            }
            var result=Bind(steps,offset,step,call,cache.Trajectory);
            foreach(var index in cache.Checkpoints.Keys.Where(i=>i>=offset).ToArray())cache.Checkpoints.Remove(index);
            for(int i=0;i<steps.Count;i++)if(steps[i]?["checkpoint"] is JsonNode checkpoint&&offset+i<step)
                cache.Checkpoints[offset+i]=Json.Hash(ReviewAdapter.Canonical(checkpoint));
            cache.Watermark=offset+steps.Count;
            result["checkpoint_revision"]=Json.Hash(string.Join(";",cache.Checkpoints.Select(p=>$"{p.Key}:{p.Value}")));
            if(Caches.Count>32)foreach(var key in Caches.Keys.Where(k=>k!=conversation).Take(Caches.Count-32))Caches.TryRemove(key,out _);
            return result;
        }
        catch(OperationCanceledException e)when(!ct.IsCancellationRequested){Caches.TryRemove(conversation,out _);throw new NativeStateUnavailableException("state_not_ready","Antigravity native state query timed out during "+phase,e);}
        catch(HttpRequestException e)when(e.StatusCode is null or HttpStatusCode.RequestTimeout or HttpStatusCode.ServiceUnavailable)
        {Caches.TryRemove(conversation,out _);throw new NativeStateUnavailableException("state_not_ready","Antigravity native state is unavailable",e);}
        catch(Exception e)when(e is FileNotFoundException or DirectoryNotFoundException)
        {Caches.TryRemove(conversation,out _);throw new NativeStateUnavailableException("state_not_ready","Antigravity native state is unavailable",e);}
        catch(Exception e)when(e is HttpRequestException or InvalidDataException or InvalidOperationException or System.Text.Json.JsonException)
        {Caches.TryRemove(conversation,out _);throw new NativeStateUnavailableException("adapter_incompatible","Antigravity native state contract is incompatible during "+phase,e);}
        catch{Caches.TryRemove(conversation,out _);throw;}
        finally{if(acquired)Serial.Release();}
    }
    public static JsonObject Bind(JsonArray steps,int offset,int step,JsonObject call,string trajectory)
    {
        int index=step-offset;
        if(index<0||index>=steps.Count)throw new NativeStateUnavailableException("state_not_ready","Proposed action is not visible in native trajectory");
        var current=steps[index]??throw new InvalidDataException("Native action step missing");
        var metadata=current["metadata"]??throw new InvalidDataException("Native action metadata missing");
        var native=metadata["toolCall"]??throw new InvalidDataException("Native tool call missing");
        var normalized=new JsonObject{["name"]=Json.Text(native,"name"),["args"]=JsonNode.Parse(Json.Text(native,"argumentsJson")??throw new InvalidDataException("Native arguments missing"))};
        if(ReviewAdapter.Canonical(normalized)!=ReviewAdapter.Canonical(NativeTranscript.NormalizeToolCall(call)))throw new NativeStateUnavailableException("action_mismatch","Hook action differs from native trajectory action");
        if(steps.Skip(index+1).Any(s=>s?["userInput"]!=null||Json.Text(s,"type")=="CORTEX_STEP_TYPE_USER_INPUT"))throw new NativeStateUnavailableException("action_invalidated","New native user guidance follows this action; submit a current request");
        var execution=Json.Text(metadata,"executionId")??throw new InvalidDataException("Native execution ID missing");
        if(!Guid.TryParse(execution,out _))throw new InvalidDataException("Invalid native execution ID");
        return new(){["source"]="antigravity_local_rpc",["trajectory_id"]=trajectory,["execution_id"]=execution,["step_index"]=step,
            ["tool_sha256"]=Json.Hash(ReviewAdapter.Canonical(normalized)),["observed_permissions"]=current["permissions"]?.DeepClone(),
            ["effective_permission_snapshot_complete"]=false};
    }
    private static async Task<Uri> DiscoverAsync(string log,CancellationToken ct)
    {
        ReviewContext.ValidateComponents(log);
        await using var stream=new FileStream(log,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        stream.Seek(Math.Max(0,stream.Length-256*1024),SeekOrigin.Begin);
        using var reader=new StreamReader(stream,Encoding.UTF8);
        var matches=Regex.Matches(await reader.ReadToEndAsync(ct),@"Local:\s+(https://127\.0\.0\.1:\d+/)");
        if(matches.Count==0||!Uri.TryCreate(matches[^1].Groups[1].Value,UriKind.Absolute,out var origin)||!IPAddress.TryParse(origin.Host,out var address)||!IPAddress.IsLoopback(address))
            throw new NativeStateUnavailableException("state_not_ready","No verified loopback Antigravity service found");
        return origin;
    }
    private static async Task<JsonNode> RpcAsync(HttpClient client,string method,object payload,CancellationToken ct)
    {
        using var request=new HttpRequestMessage(HttpMethod.Post,"exa.language_server_pb.LanguageServerService/"+method){Content=JsonContent.Create(payload)};
        var body=await BodyAsync(await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct),ct,40*1024*1024);
        return JsonNode.Parse(body)??throw new InvalidDataException("Invalid native state response");
    }
    private static async Task<string> BodyAsync(HttpResponseMessage response,CancellationToken ct,int limit)
    {
        using(response)
        {
            response.EnsureSuccessStatusCode();
            await using var stream=await response.Content.ReadAsStreamAsync(ct);
            using var output=new MemoryStream();var buffer=new byte[8192];int read;
            while((read=await stream.ReadAsync(buffer,ct))>0){if(output.Length+read>limit)throw new InvalidDataException("Native RPC response exceeds limit");await output.WriteAsync(buffer.AsMemory(0,read),ct);}
            return new UTF8Encoding(false,true).GetString(output.ToArray());
        }
    }
}
