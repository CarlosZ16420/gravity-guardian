using System.Text.Json.Nodes;

namespace AgApproval;

public sealed class Policy
{
    public string Instructions { get; }
    public string Rejection { get; }
    public string Hash { get; }
    public JsonNode Schema { get; }
    public string HashFor(Settings settings)=>settings.ReviewerBackend=="NativeGuardian"?
        Json.Hash(Hash+GuardianFacts.Protocol+GuardianFacts.UpstreamCommit+GuardianFacts.BridgePolicy):Hash;
    public Policy(string directory)
    {
        var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(directory, "SOURCE.json")))!;
        var verified = new Dictionary<string, string>();
        foreach (var entry in manifest["sha256"]!.AsObject())
        {
            if (Path.GetFileName(entry.Key) != entry.Key) throw new InvalidDataException("Invalid policy filename");
            var body = File.ReadAllText(Path.Combine(directory, entry.Key));
            if (Json.Hash(body) != entry.Value!.GetValue<string>()) throw new InvalidDataException("Policy integrity mismatch: " + entry.Key);
            verified[entry.Key] = body;
        }
        var template = verified["policy_template.md"];
        var policy = verified["policy.md"];
        var output = verified["output-contract.txt"];
        Instructions = template.Replace("{{ tenant_policy_config }}", policy).Replace("{{ extra_policy }}", "") + "\n\n" + output;
        Rejection = verified["rejection-feedback.txt"];
        Schema = JsonNode.Parse(verified["output.schema.json"])!;
        Hash = Json.Hash(Instructions + Rejection + Schema.ToJsonString());
    }

    public GateResponse Apply(string finalText, string requestId, string actionHash)
    {
        // Same thin prose-wrapper recovery as upstream; no heuristic allow on malformed output.
        JsonNode? value;
        try { value = JsonNode.Parse(finalText); }
        catch (System.Text.Json.JsonException)
        {
            int start = finalText.IndexOf('{'), end = finalText.LastIndexOf('}');
            if (start < 0 || end <= start) throw new InvalidDataException("Reviewer did not return JSON");
            value = JsonNode.Parse(finalText[start..(end + 1)]);
        }
        var outcome = Json.Text(value, "outcome");
        if (outcome is not ("allow" or "deny")) throw new InvalidDataException("Invalid reviewer outcome");
        var risk = Json.Text(value, "risk_level") ?? (outcome == "allow" ? "low" : "high");
        var auth = Json.Text(value, "user_authorization") ?? "unknown";
        if (risk is not ("low" or "medium" or "high" or "critical") || auth is not ("unknown" or "low" or "medium" or "high"))
            throw new InvalidDataException("Invalid reviewer assessment fields");
        var rationale = Json.Text(value, "rationale");
        if (string.IsNullOrWhiteSpace(rationale)) rationale = outcome == "allow"
            ? "Auto-review returned a low-risk allow decision." : "Auto-review returned a deny decision without a rationale.";
        var reason = $"Automatic approval review {outcome} (risk: {risk}, authorization: {auth}): {rationale}";
        if (outcome == "deny") reason += "\n" + Rejection;
        return new(outcome == "allow" ? "auto_approve" : "deny", reason, outcome == "allow" ? "approved" : "denied", requestId, actionHash){ReasonCode=outcome=="allow"?"policy_allowed":"policy_denied"};
    }
}
