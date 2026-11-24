using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public sealed record ReviewInput(string Id,string Hash,string Conversation,string Tool,string Cwd,string Prompt,string EvidenceHash)
{
    public string ActionFingerprint { get; init; } = "";
    public string AuthorizationRevision { get; init; } = "";
    public string EvidenceRevision => EvidenceHash;
    public string EnvironmentRevision { get; init; } = "";
    public string MaterialRevision { get; init; } = "";
    public string BindingHash { get; init; } = "";
    public string NativeSegment { get; init; } = "";
    public string[] AuthorizationSources { get; init; } = [];
    public JsonArray? NativeRecords { get; init; }
    public JsonObject? NativeState { get; init; }
    public JsonArray? SourceUserRecords { get; init; }
    public int? ReviewBudgetMs { get; init; }
    public int StepIndex { get; init; }=-1;
}

public static class ReviewContext
{
    public static async Task<ReviewInput> BuildAsync(JsonNode payload,Settings settings,CancellationToken ct,string? requestId=null,string policyHash="",bool includeNativeState=true)
    {
        if(string.IsNullOrEmpty(policyHash))policyHash=new Policy(settings.PolicyDirectory).HashFor(settings);
        var call=payload["toolCall"] as JsonObject??throw new InvalidDataException("Missing toolCall");
        var tool=Json.Text(call,"name")??throw new InvalidDataException("Missing tool name");
        if(call["args"] is not JsonObject args)throw new InvalidDataException("Missing tool arguments");
        var conversation=Json.Text(payload,"conversationId")??throw new InvalidDataException("Missing conversationId");
        if(!Guid.TryParse(conversation,out _))throw new InvalidDataException("Invalid conversationId");
        var step=payload["stepIdx"]?.GetValue<int>()??throw new InvalidDataException("Missing stepIdx");
        if(step<0)throw new InvalidDataException("Invalid stepIdx");
        var path=Json.Text(payload,"transcriptPath")??throw new InvalidDataException("Missing transcriptPath");
        ValidateTranscriptPath(path,conversation,settings.TranscriptRoots);
        var workspace=payload["workspacePaths"] as JsonArray??throw new InvalidDataException("Missing workspacePaths");
        if(workspace.Count==0||workspace.Any(w=>w is not JsonValue||!w.AsValue().TryGetValue<string>(out var p)||!Path.IsPathFullyQualified(p)))throw new InvalidDataException("Workspace paths must be absolute strings");
        var cwd=Json.Text(args,"Cwd")??Json.Text(args,"cwd")??workspace[0]!.GetValue<string>();
        if(!Path.IsPathFullyQualified(cwd))throw new InvalidDataException("Missing absolute working directory");
        cwd=Path.GetFullPath(cwd);
        var action=new JsonObject{["toolCall"]=call.DeepClone(),["stepIdx"]=step,["conversationId"]=conversation,["workspacePaths"]=workspace.DeepClone(),["cwd"]=cwd,
            ["working_directory_source"]=(Json.Text(args,"Cwd")??Json.Text(args,"cwd")) is null?"first_mounted_workspace_fallback_not_runtime_verified":"tool_arguments"};
        var actionHash=Json.Hash(action.ToJsonString());var fingerprint=Json.Hash(ReviewAdapter.Canonical(ReviewAdapter.ActionIdentity(action)));
        var unknownScope=new JsonObject();
        foreach(var pair in payload.AsObject().Where(p=>p.Key is not ("toolCall" or "stepIdx" or "conversationId" or "workspacePaths" or "transcriptPath" or "artifactDirectoryPath" or "lastUserInput" or "modelName")))unknownScope[pair.Key]=pair.Value?.DeepClone();
        fingerprint=Json.Hash(fingerprint+ReviewAdapter.Canonical(unknownScope));
        var permissions=PermissionSnapshot.Read(settings,workspace);var parsed=await NativeTranscript.ReadAsync(path,step,call,ct);
        if(parsed.Rows.Any(r=>r.IsUser&&r.Position>parsed.UserCutoff))throw new InvalidDataException("New user instructions follow this action; a current request is required");
        var users=new JsonArray();var evidence=new List<JsonObject>();
        foreach(var row in parsed.Rows.Where(r=>r.Position<=parsed.Cutoff))
        {
            if(!row.IsUser&&(parsed.ActiveNonUserPositions!=null?!parsed.ActiveNonUserPositions.Contains(row.Position):row.Segment!=parsed.Segment||row.Step>=step))continue;
            var record=new JsonObject{["record_id"]="native:"+row.Position,["step_index"]=row.Step,["source"]=Json.Text(row.Value,"source"),["type"]=Json.Text(row.Value,"type"),
                ["is_authenticated_user_input"]=row.IsUser,["role"]=row.IsUser?"user":Json.Text(row.Value,"type")=="PLANNER_RESPONSE"?"assistant":"unclassified_evidence",
                ["native_position"]=row.Position,["native_segment"]="segment:"+row.Segment,["created_at"]=row.Value["created_at"]?.DeepClone(),
                ["truncation"]=new JsonObject{["upstream_fields"]=row.Value["truncated_fields"]?.DeepClone()??new JsonArray(),["bridge_content_truncated"]=false}};
            foreach(var key in new[]{"content","tool_calls","truncated_fields","status","error"})if(row.Value[key]!=null)record[key]=row.Value[key]!.DeepClone();
            if(row.IsUser)
            {
                ReviewAdapter.SeparateNativeEnvelope(record);
                users.Add(record);
            }
            else evidence.Add(record);
        }
        if(users.Count==0)throw new InvalidDataException("No authenticated user task in transcript");
        bool native=settings.ReviewerBackend=="NativeGuardian";
        var modelUsers=new JsonArray(users.Select(u=>{
            var copy=u!.DeepClone().AsObject();
            copy.Remove("original_content");copy.Remove("host_metadata");
            return (JsonNode)copy;
        }).ToArray());
        if(!native&&Bytes(modelUsers)>settings.MaxContextBytes)throw new InvalidDataException("User instructions exceed review evidence budget");
        var states=ReviewAdapter.FileStates(action,native);var rules=ReadRules(workspace,cwd,args,states);
        var authorizationRevision=Json.Hash(ReviewAdapter.Canonical(new JsonArray(modelUsers.Select(r=>(JsonNode)new JsonObject{
            ["content"]=r!["content"]?.DeepClone(),["truncation"]=r["truncation"]?.DeepClone()}).ToArray())));
        var effectiveKnownPermissions=permissions.DeepClone().AsObject();effectiveKnownPermissions.Remove("sources");
        var environmentRevision=Json.Hash(ReviewAdapter.Canonical(new JsonObject{["workspaces"]=workspace.DeepClone(),["cwd"]=cwd,["permission_context"]=effectiveKnownPermissions}));
        var materialRevision=Json.Hash(ReviewAdapter.Canonical(new JsonObject{["action"]=fingerprint,["environment"]=environmentRevision,["rules"]=rules.DeepClone(),["files"]=states.DeepClone()}));
        var nativeRecords=new JsonArray(users.Concat(evidence).OrderBy(r=>r!["native_position"]!.GetValue<int>()).Select(r=>r!.DeepClone()).ToArray());
        JsonObject? nativeState=null;
        if(includeNativeState&&settings.ReviewerBackend=="NativeGuardian"&&settings.EnableNativeState)
        {
            try{nativeState=await AntigravityState.ReadAsync(settings,conversation,step,call,ct);}
            catch(NativeStateUnavailableException e)when(e.Code is ("state_not_ready" or "adapter_incompatible")){nativeState=null;}
        }
        // Native mode binds relevant source records, not unrelated later assistant appends.
        var sourceHash=settings.ReviewerBackend=="NativeGuardian"?Json.Hash(ReviewAdapter.Canonical(nativeRecords)):parsed.RawHash;
        var evidenceRevision=Json.Hash(sourceHash+ReviewAdapter.Canonical(effectiveKnownPermissions)+rules.ToJsonString()+states.ToJsonString()+parsed.Segment+parsed.Cutoff+(nativeState==null?"":ReviewAdapter.Canonical(nativeState)));
        var id=requestId??Guid.NewGuid().ToString("N");
        var binding=Json.Hash(ReviewAdapter.Canonical(new JsonObject{["request_id"]=id,["raw_request"]=payload.DeepClone(),["action"]=fingerprint,["authorization"]=authorizationRevision,["evidence"]=evidenceRevision,["policy"]=policyHash,["adapter"]=ReviewAdapter.Hash,["transport"]=ReviewAdapter.TransportVersion}));
        var doc=new JsonObject{["schema_version"]=ReviewAdapter.InputVersion,["request_id"]=id,["action_sha256"]=actionHash,["action_fingerprint"]=fingerprint,
            ["authorization_revision"]=authorizationRevision,["evidence_revision"]=evidenceRevision,["binding_hash"]=binding,["policy_hash"]=policyHash,
            ["adapter"]=new JsonObject{["version"]=ReviewAdapter.Version,["instruction_hash"]=ReviewAdapter.Hash,["transport_version"]=ReviewAdapter.TransportVersion,["source"]="plugin_fixed_adapter_not_user",["instructions"]=ReviewAdapter.Instructions},
            ["action_type"]=ReviewAdapter.Describe(tool),["user_instructions"]=modelUsers,["project_rules"]=rules,["permission_context"]=permissions,["referenced_file_states"]=states,
            ["native_binding"]=new JsonObject{["segment_id"]="segment:"+parsed.Segment,["cutoff_position"]=parsed.Cutoff,["binding_method"]=parsed.Method,["raw_transcript_sha256"]=parsed.RawHash},
            ["conversation_evidence"]=new JsonArray(),["transcript_omitted_records"]=0,["transcript_omitted_positions"]=new JsonArray(),["planned_action"]=action,["additional_hook_scope"]=unknownScope};
        if(!native)
        {
            int budget=settings.MaxContextBytes+settings.MaxInputBytes;
            if(Bytes(doc)>budget)throw new InvalidDataException("Complete action, user restrictions and rules exceed input budget");
            var (chosen,omitted)=ReviewEvidence.Select(evidence,settings,budget-Bytes(doc)-4096);
            doc["conversation_evidence"]=chosen;
            doc["transcript_omitted_records"]=omitted.Count;doc["transcript_omitted_positions"]=new JsonArray(omitted.Select(p=>(JsonNode?)JsonValue.Create(p)).ToArray());
            if(Bytes(doc)>budget)throw new InvalidDataException("Complete review input exceeds budget");
        }
        var prompt=doc.ToJsonString(Json.PromptOptions);
        return new(id,actionHash,conversation,tool,cwd,prompt,evidenceRevision){ActionFingerprint=fingerprint,AuthorizationRevision=authorizationRevision,EnvironmentRevision=environmentRevision,
            MaterialRevision=materialRevision,BindingHash=binding,NativeSegment="segment:"+parsed.Segment,AuthorizationSources=users.Select(r=>Json.Text(r,"record_id")!).ToArray(),
            NativeRecords=native?nativeRecords:null,NativeState=nativeState,SourceUserRecords=users,StepIndex=step};
    }

    public static ReviewInput PrepareCliFallback(ReviewInput input,Settings settings)
    {
        var doc=JsonNode.Parse(input.Prompt)!.AsObject();
        int budget=settings.MaxContextBytes+settings.MaxInputBytes;
        if(Bytes(doc)>budget)throw new InvalidDataException("Complete action, user restrictions and rules exceed input budget");
        var nonUser=(input.NativeRecords??new JsonArray())
            .Select(r=>r!.AsObject())
            .Where(r=>r["is_authenticated_user_input"]?.GetValue<bool>()!=true)
            .Select(r=>r.DeepClone().AsObject())
            .ToList();
        var (chosen,omitted)=ReviewEvidence.Select(nonUser,settings,Math.Max(0,budget-Bytes(doc)-4096));
        doc["conversation_evidence"]=chosen;
        doc["transcript_omitted_records"]=omitted.Count;
        doc["transcript_omitted_positions"]=new JsonArray(omitted.Select(p=>(JsonNode?)JsonValue.Create(p)).ToArray());
        if(Bytes(doc)>budget)throw new InvalidDataException("Complete review input exceeds budget");
        return input with{Prompt=doc.ToJsonString(Json.PromptOptions)};
    }
    private static int Bytes(JsonNode value)=>Encoding.UTF8.GetByteCount(value.ToJsonString(Json.PromptOptions));
    private static JsonArray ReadRules(JsonArray workspace,string cwd,JsonObject args,JsonArray states)
    {
        var result=new JsonArray();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var root in workspace.Select(w=>Path.GetFullPath(w!.GetValue<string>())))
        {
            var targets=new List<string>{cwd};
            foreach(var state in states)
                if(Json.Text(state,"path") is string referenced&&Path.GetDirectoryName(referenced) is string parent)targets.Add(parent);
            foreach(var key in new[]{"Path","AbsolutePath","TargetFile"})if(Json.Text(args,key) is string p&&Path.IsPathFullyQualified(p))targets.Add(Path.GetDirectoryName(p)!);
            var directories=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var target in targets)
                for(string? part=target;part!=null&&(part.Equals(root,StringComparison.OrdinalIgnoreCase)||part.StartsWith(Path.TrimEndingDirectorySeparator(root)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase));part=Path.GetDirectoryName(part))
                    directories.Add(part);
            foreach(var part in directories.OrderBy(d=>d.Length).ThenBy(d=>d,StringComparer.OrdinalIgnoreCase))
            {
                var localOverride=Path.Combine(part,"AGENTS.override.md");
                var file=File.Exists(localOverride)?localOverride:Path.Combine(part,"AGENTS.md");
                if(!seen.Add(file)||!File.Exists(file))continue;
                ValidateComponents(file);
                using var stream=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
                if(stream.Length>65536)throw new InvalidDataException("Project rules exceed budget");
                using var bytes=new MemoryStream();stream.CopyTo(bytes);var raw=bytes.ToArray();
                using var reader=new StreamReader(new MemoryStream(raw),new UTF8Encoding(false,true),true);var content=reader.ReadToEnd();
                result.Add(new JsonObject{["source"]="verified_workspace_file",["path"]=file,["scope"]=part,["sha256"]=Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(raw)),["content"]=content});
            }
        }
        return result;
    }
    public static void ValidateTranscriptPath(string path,string conversation,string[] roots)
    {
        if(!Path.IsPathFullyQualified(path))throw new InvalidDataException("Transcript path must be absolute");
        var full=Path.GetFullPath(path);var comparison=OperatingSystem.IsWindows()?StringComparison.OrdinalIgnoreCase:StringComparison.Ordinal;
        if(!roots.SelectMany(root=>new[]{"transcript.jsonl","transcript_full.jsonl"}.Select(name=>Path.GetFullPath(Path.Combine(root,conversation,".system_generated","logs",name)))).Any(p=>string.Equals(p,full,comparison)))throw new InvalidDataException("Transcript path is not owned by this conversation");
        ValidateComponents(full);
    }
    public static void ValidateComponents(string path)
    {
        for(string? part=Path.GetFullPath(path);part!=null;part=Path.GetDirectoryName(part))if((File.GetAttributes(part)&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Evidence path contains a reparse point");
    }
}
