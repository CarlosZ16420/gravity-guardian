using System.Text.Json.Nodes;

namespace AgApproval;

// Explicit v1 -> v2 conversion for isolated review experiments. Never executes a tool,
// invents historical runtime permissions, or applies an assessment to a Hook request.
public static class HistoricalReplay
{
    public static JsonObject ConvertLegacy(JsonObject legacy,string policyHash)
    {
        if(Json.Text(legacy,"schema_version")!="1.0"||legacy["transcript"] is not JsonArray transcript||legacy["planned_action"] is not JsonObject action||legacy["permission_context"] is not JsonObject permissions)
            throw new InvalidDataException("Expected archived v1 review evidence");
        var users=new JsonArray();var evidence=new JsonArray();
        foreach(var value in transcript)
        {
            var record=value?.DeepClone() as JsonObject??throw new InvalidDataException("Invalid historical record");
            bool trusted=record["is_authenticated_user_input"]?.GetValue<bool>()==true;
            if(trusted&&(Json.Text(record,"source")!="USER_EXPLICIT"||Json.Text(record,"type")!="USER_INPUT"||Json.Text(record,"role")!="user"))throw new InvalidDataException("Invalid archived user provenance");
            record["record_id"]="native:"+record["native_position"]!.GetValue<int>();record["native_segment"]="historical:unavailable";
            if(trusted){ReviewAdapter.SeparateNativeEnvelope(record);users.Add(record);}else evidence.Add(record);
        }
        if(users.Count==0)throw new InvalidDataException("Archived evidence has no real user instruction");
        var fingerprint=Json.Hash(ReviewAdapter.Canonical(ReviewAdapter.ActionIdentity(action)));
        var auth=Json.Hash(ReviewAdapter.Canonical(users));var evidenceHash=Json.Hash(ReviewAdapter.Canonical(legacy));var id=Guid.NewGuid().ToString("N");
        return new JsonObject{["schema_version"]=ReviewAdapter.InputVersion,["request_id"]=id,["action_sha256"]=legacy["action_sha256"]!.DeepClone(),["action_fingerprint"]=fingerprint,
            ["authorization_revision"]=auth,["evidence_revision"]=evidenceHash,["binding_hash"]=Json.Hash(id+fingerprint+auth+evidenceHash+policyHash+ReviewAdapter.Hash),["policy_hash"]=policyHash,
            ["adapter"]=new JsonObject{["version"]=ReviewAdapter.Version,["instruction_hash"]=ReviewAdapter.Hash,["transport_version"]=ReviewAdapter.TransportVersion,["source"]="plugin_fixed_adapter_not_user",["instructions"]=ReviewAdapter.Instructions},
            ["action_type"]=ReviewAdapter.Describe(Json.Text(action["toolCall"],"name")!),["user_instructions"]=users,["conversation_evidence"]=evidence,["project_rules"]=new JsonArray(),["permission_context"]=permissions.DeepClone(),["referenced_file_states"]=new JsonArray(),
            ["native_binding"]=new JsonObject{["segment_id"]="historical:unavailable",["cutoff_position"]=transcript.Select(r=>r!["native_position"]!.GetValue<int>()).DefaultIfEmpty(0).Max(),["binding_method"]="historical_v1_conversion_not_live_approval",["raw_transcript_sha256"]=evidenceHash},
            ["transcript_omitted_records"]=legacy["transcript_omitted_records"]!.DeepClone(),["transcript_omitted_positions"]=legacy["transcript_omitted_positions"]!.DeepClone(),["planned_action"]=action.DeepClone(),["additional_hook_scope"]=new JsonObject()};
    }
}
