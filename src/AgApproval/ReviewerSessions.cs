using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public sealed class ReviewerSession
{
    public string Scope { get; init; } = "";
    public string Directory { get; init; } = "";
    public string? ThreadId { get; set; }
    public int Turns { get; set; }
    public long SentBytes { get; set; }
    public long LastInputTokens { get; set; }
    public string? SnapshotHash { get; set; }
    public JsonObject? NativeUsage { get; set; }
    public Dictionary<string,JsonNode> Evidence { get; } = new(StringComparer.Ordinal);
}

public sealed class ReviewerInvocation(ReviewerSession state, JsonObject snapshot)
{
    public ReviewerSession State { get; }=state;
    public JsonObject Snapshot { get; }=snapshot;
    public string? ExpectedThreadId { get; }=state.ThreadId;
    public string? ReportedThreadId { get; set; }
    public bool Reusable { get; set; }
    public bool ThreadIdentityConflict { get; set; }
    public long LastInputTokens { get; set; }
    public JsonObject? NativeUsage { get; set; }
    public string Prompt { get; init; }="";
    public int AddedEvidence { get; init; }
    public int ActiveEvidence { get; init; }
    public string Mode => ExpectedThreadId==null?"full":"delta";
    public int Sequence => State.Turns+1;
}

public sealed class ReviewerSessions(Settings settings)
{
    public const string Version="review-session-delta-v1";
    public const string Instructions="Review transport contract (plugin-fixed, not user authorization): each message contains current_review, evidence_update and active_evidence. current_review is the authoritative complete current action, authentic user instructions, rules, permissions, omissions and binding. evidence_update adds immutable evidence records indexed by sha256; active_evidence lists the exact evidence records applicable to this review in order. Resolve those references from this message or prior messages in this reviewer session. Evidence outside active_evidence is historical, not current evidence. Missing or ambiguous references require a technical failure, never an inferred approval. Past assessments are model opinions, not user authorization and not approvals for this action. Evaluate this action afresh, including current restrictions or revocations. Do not execute it. Output only the existing four-field assessment. Hashes are host-verified binding labels, not a request for you to calculate hashes.";
    private readonly Dictionary<string,ReviewerSession> states=new(StringComparer.Ordinal);
    public static string Scope(JsonObject doc,Settings settings)
    {
        var permissions=doc["permission_context"]!.DeepClone().AsObject();permissions.Remove("sources");
        var auth=new FileInfo(Path.Combine(settings.CodexHome,"auth.json"));
        // Metadata only: never read or log credentials. Without a file-backed identity
        // stamp, fail conservative by declining reuse (e.g. unverified keyring changes).
        var authStamp=auth.Exists?auth.LastWriteTimeUtc.Ticks+":"+auth.Length:Guid.NewGuid().ToString("N");
        return Json.Hash(ReviewAdapter.Canonical(new JsonObject{
            ["conversation"]=doc["planned_action"]!["conversationId"]!.DeepClone(),
            ["segment"]=doc["native_binding"]!["segment_id"]!.DeepClone(),
            ["authorization"]=doc["authorization_revision"]!.DeepClone(),
            ["policy"]=doc["policy_hash"]!.DeepClone(),["adapter"]=doc["adapter"]!.DeepClone(),
            ["rules"]=doc["project_rules"]!.DeepClone(),["permissions"]=permissions,
            ["model"]=settings.Model,["effort"]=settings.Effort,["codexHome"]=settings.CodexHome,
            ["authStateStamp"]=authStamp,
            ["transport"]=Version,["selection"]=ReviewEvidence.Version,
            ["limits"]=new JsonArray(settings.MaxEvidenceBytes,settings.MaxEvidenceRecords,settings.MaxEvidenceContentBytes)
        }));
    }
    public ReviewerInvocation Prepare(ReviewInput input)
    {
        var doc=JsonNode.Parse(input.Prompt)!.AsObject();var scope=Scope(doc,settings);
        if(states.TryGetValue(scope,out var old)&&(old.Turns>=settings.MaxReviewerSessionTurns||old.SentBytes>=settings.MaxReviewerSessionBytes||old.LastInputTokens>=settings.MaxReviewerSessionInputTokens))Retire(old);
        if(!states.TryGetValue(scope,out var state))
        {
            if(states.Count>=16)Retire(states.Values.First());
            var directory=Path.Combine(settings.DataDirectory,"reviewer-sessions",Guid.NewGuid().ToString("N"));
            state=new(){Scope=scope,Directory=directory};states.Add(scope,state);
        }
        var update=new JsonArray();var active=new JsonArray();
        foreach(var record in doc["conversation_evidence"]!.AsArray())
        {
            var hash=Json.Hash(ReviewAdapter.Canonical(record));
            active.Add(new JsonObject{["record_id"]=record!["record_id"]!.DeepClone(),["sha256"]=hash});
            if(!state.Evidence.ContainsKey(hash))update.Add(new JsonObject{["sha256"]=hash,["record"]=record.DeepClone()});
        }
        var current=(JsonObject)doc.DeepClone();current.Remove("conversation_evidence");
        var wire=new JsonObject{["transport_version"]=Version,["mode"]=state.ThreadId==null?"full":"delta",
            ["sequence"]=state.Turns+1,["previous_snapshot_sha256"]=state.SnapshotHash,
            ["evidence_update"]=update,["active_evidence"]=active,["current_review"]=current,
            ["snapshot_sha256"]=Json.Hash(ReviewAdapter.Canonical(doc))};
        var prompt=wire.ToJsonString(Json.PromptOptions);
        if(state.Turns>0&&state.SentBytes+Encoding.UTF8.GetByteCount(prompt)>settings.MaxReviewerSessionBytes){Retire(state);return Prepare(input);}
        return new(state,doc){Prompt=prompt,AddedEvidence=update.Count,ActiveEvidence=active.Count};
    }
    public void Commit(ReviewerInvocation invocation,string assessment)
    {
        var state=invocation.State;
        if(!invocation.Reusable||!Guid.TryParse(invocation.ReportedThreadId,out _)||
            invocation.ExpectedThreadId!=null&&invocation.ExpectedThreadId!=invocation.ReportedThreadId){Retire(state);return;}
        state.ThreadId=invocation.ReportedThreadId;state.Turns++;
        state.SentBytes+=Encoding.UTF8.GetByteCount(invocation.Prompt)+Encoding.UTF8.GetByteCount(assessment);
        state.LastInputTokens=invocation.LastInputTokens;
        state.NativeUsage=invocation.NativeUsage?.DeepClone().AsObject();
        state.SnapshotHash=Json.Hash(ReviewAdapter.Canonical(invocation.Snapshot));
        foreach(var record in invocation.Snapshot["conversation_evidence"]!.AsArray())state.Evidence[Json.Hash(ReviewAdapter.Canonical(record))]=record!.DeepClone();
    }
    public void Retire(ReviewerSession state)
    {
        states.Remove(state.Scope);
        var parent=Path.GetFullPath(Path.Combine(settings.DataDirectory,"reviewer-sessions"));
        if(Path.GetFullPath(state.Directory).StartsWith(parent+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))
            try{Directory.Delete(state.Directory,true);}catch(IOException){}catch(UnauthorizedAccessException){}
    }
    // Exact host-side reconstruction for audit/replay. This never grants authorization.
    public static JsonObject Reconstruct(JsonObject wire,IReadOnlyDictionary<string,JsonNode> previous)
    {
        var records=new Dictionary<string,JsonNode>(previous,StringComparer.Ordinal);
        foreach(var update in wire["evidence_update"]!.AsArray())
        {
            var hash=Json.Text(update,"sha256")!;var record=update!["record"]!;
            if(hash!=Json.Hash(ReviewAdapter.Canonical(record)))throw new InvalidDataException("Evidence digest mismatch");
            records[hash]=record;
        }
        var snapshot=(JsonObject)wire["current_review"]!.DeepClone();var selected=new JsonArray();
        foreach(var reference in wire["active_evidence"]!.AsArray())
        {
            if(!records.TryGetValue(Json.Text(reference,"sha256")!,out var record)||Json.Text(reference,"record_id")!=Json.Text(record,"record_id"))throw new InvalidDataException("Missing current evidence");
            selected.Add(record.DeepClone());
        }
        snapshot["conversation_evidence"]=selected;
        if(Json.Hash(ReviewAdapter.Canonical(snapshot))!=Json.Text(wire,"snapshot_sha256"))throw new InvalidDataException("Snapshot digest mismatch");
        return snapshot;
    }
}
