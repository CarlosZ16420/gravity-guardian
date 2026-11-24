using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public sealed record NativeRow(JsonObject Value,int Position,int Step,int Segment,bool IsUser);
public sealed record NativeEvidence(List<NativeRow> Rows,int Segment,int Cutoff,int UserCutoff,string Method,string RawHash,HashSet<int>? ActiveNonUserPositions=null);

public static class NativeTranscript
{
    // Native transcripts omit empty args and may omit the Hook's transport-only ID.
    // Keep every other field so unknown action data cannot silently compare equal.
    public static JsonObject NormalizeToolCall(JsonObject call)
    {
        if(call["name"] is not JsonValue name||!name.TryGetValue<string>(out var text)||string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException("Unknown native tool-call name contract");
        if(call.ContainsKey("args")&&call["args"] is not JsonObject)
            throw new InvalidDataException("Unknown native tool-call arguments contract");
        if(call.ContainsKey("id")&&(call["id"] is not JsonValue id||!id.TryGetValue<string>(out var value)||string.IsNullOrWhiteSpace(value)))
            throw new InvalidDataException("Unknown native tool-call ID contract");
        var normalized=call.DeepClone().AsObject();
        normalized.Remove("id");
        if(!normalized.ContainsKey("args"))normalized["args"]=new JsonObject();
        return normalized;
    }

    public static async Task<NativeEvidence> ReadAsync(string path,int step,JsonObject call,CancellationToken ct)
    {
        // One bounded reread allows an append in progress to complete; never repair JSON.
        for(int attempt=0;;attempt++)try{return await ReadOnceAsync(path,step,call,ct);}
        catch(Exception e)when(attempt==0&&e is IOException or InvalidDataException){await Task.Delay(50,ct);}
    }
    private static async Task<NativeEvidence> ReadOnceAsync(string path,int step,JsonObject call,CancellationToken ct)
    {
        using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        if(stream.Length>32*1024*1024)throw new InvalidDataException("Transcript exceeds supported size");
        using var reader=new StreamReader(stream,new UTF8Encoding(false,true));var raw=await reader.ReadToEndAsync(ct);
        using var verify=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        using var verifier=new StreamReader(verify,new UTF8Encoding(false,true));
        if(await verifier.ReadToEndAsync(ct)!=raw)throw new IOException("Transcript changed during snapshot read");
        if(raw.Length>0&&!raw.EndsWith('\n'))throw new InvalidDataException("Transcript has an incomplete final physical record");
        var rows=new List<NativeRow>();var activeNonUser=new List<NativeRow>();int previous=-1,segment=1,position=0;
        foreach(var line in raw.Split('\n'))
        {
            position++;if(line.Length==0)continue;
            JsonObject row;try{row=JsonNode.Parse(line) as JsonObject??throw new InvalidDataException("Invalid transcript object");}
            catch(System.Text.Json.JsonException e){throw new InvalidDataException("Transcript contains an incomplete or invalid row",e);}
            int index=row["step_index"]?.GetValue<int>()??throw new InvalidDataException("Unknown transcript schema");
            var type=Json.Text(row,"type");var source=Json.Text(row,"source");
            if(index<0||string.IsNullOrWhiteSpace(type)||string.IsNullOrWhiteSpace(source))throw new InvalidDataException("Transcript record has no valid step or role provenance");
            if(row["truncated_fields"] is JsonArray fields&&fields.Any(v=>v is not JsonValue||!v.AsValue().TryGetValue<string>(out _)))throw new InvalidDataException("Unknown truncation marker format");
            if(row.ContainsKey("truncated_fields")&&row["truncated_fields"] is not JsonArray)throw new InvalidDataException("Unknown truncation marker format");
            foreach(var key in new[]{"content","status","error","created_at"})
                if(row[key]!=null&&(row[key] is not JsonValue value||!value.TryGetValue<string>(out _)))throw new InvalidDataException("Unknown native text field contract: "+key);
            if(row["tool_calls"]!=null)
            {
                if(row["tool_calls"] is not JsonArray calls)throw new InvalidDataException("Unknown native tool-call contract");
                foreach(var nativeCall in calls)
                    _=NormalizeToolCall(nativeCall as JsonObject??throw new InvalidDataException("Unknown native tool-call contract"));
            }
            bool user=type=="USER_INPUT"&&source=="USER_EXPLICIT";
            if(index<previous)
            {
                bool validRollback=user||(index>0&&type is ("SYSTEM_MESSAGE" or "PLANNER_RESPONSE" or "ERROR_MESSAGE")&&rows.Any(r=>r.Step<=index));
                if(!validRollback)
                    throw new InvalidDataException("Unexplained transcript step rollback; current retry segment cannot be established");
                segment=position;
                activeNonUser.RemoveAll(r=>r.Step>=index);
            }
            var entry=new NativeRow(row,position,index,segment,user);
            rows.Add(entry);
            if(!user)activeNonUser.Add(entry);
            previous=index;
        }
        var action=ReviewAdapter.Canonical(NormalizeToolCall(call));
        var matches=activeNonUser.Where(r=>r.Step<step&&Json.Text(r.Value,"source")=="MODEL"&&Json.Text(r.Value,"type")=="PLANNER_RESPONSE"&&
            r.Value["tool_calls"] is JsonArray calls&&step-r.Step-1<calls.Count&&ReviewAdapter.Canonical(NormalizeToolCall(calls[step-r.Step-1]!.AsObject()))==action).ToArray();
        int cutoff,userCutoff;string method;
        if(matches.Length==1)
        {
            var proposal=matches[0];
            if(activeNonUser.Any(r=>r.Position>proposal.Position&&r.Step<step&&Json.Text(r.Value,"type")=="PLANNER_RESPONSE"))throw new InvalidDataException("Overlapping native tool proposals cannot be uniquely bound");
            userCutoff=proposal.Position;cutoff=Math.Max(userCutoff,activeNonUser.Where(r=>r.Step<step).Max(r=>r.Position));
            method=proposal.Value["tool_calls"]!.AsArray().Count==1?"exact_tool_arguments_preceding_native_step":"indexed_native_tool_batch";
        }
        else if(matches.Length==0&&activeNonUser.All(r=>r.Step<step))
        {
            var lastBatch=activeNonUser.LastOrDefault(r=>r.Value["tool_calls"] is JsonArray a&&a.Count>0);
            int batchCount=lastBatch?.Value["tool_calls"]?.AsArray().Count??0;
            bool batchCompleted=lastBatch==null||Enumerable.Range(1,batchCount).All(k=>activeNonUser.Any(r=>r.Step==lastBatch.Step+k));
            int frontierStep=rows.Where(r=>r.Segment==segment).Select(r=>r.Step).DefaultIfEmpty(0).Max();
            if(!batchCompleted||step<=lastBatch?.Step+batchCount||step>frontierStep+2)
                throw new InvalidDataException("Current request cannot be uniquely bound to the active native segment");
            cutoff=rows.LastOrDefault()?.Position??0;userCutoff=cutoff;
            method=segment==1&&lastBatch==null?"single_segment_frontier_hook_request":"active_branch_frontier_hook_request";
        }
        else throw new InvalidDataException("Current request cannot be uniquely bound to the active native segment");
        var activePositions=activeNonUser.Where(r=>r.Step<step&&r.Position<=cutoff).Select(r=>r.Position).ToHashSet();
        return new(rows,segment,cutoff,userCutoff,method,Json.Hash(raw),activePositions);
    }
}
