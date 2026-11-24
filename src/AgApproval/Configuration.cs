using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Encodings.Web;
using System.Text.Unicode;

namespace AgApproval;

public sealed class Settings
{
    public string Model { get; set; } = "codex-auto-review";
    public string Effort { get; set; } = "low";
    public string CodexPath { get; set; } = "";
    public string[] CodexPrefixArguments { get; set; } = [];
    public string? Proxy { get; set; }
    public string DataDirectory { get; set; } = "";
    public string PolicyDirectory { get; set; } = "";
    public string CodexHome { get; set; } = "";
    public string AntigravityConfigDirectory { get; set; } = "";
    public string[] TranscriptRoots { get; set; } = [];
    public int ReviewTimeoutSeconds { get; set; } = 90;
    public int HookTimeoutSeconds { get; set; } = 100;
    public int MaxInputBytes { get; set; } = 524288;
    public int MaxContextBytes { get; set; } = 131072;
    public int MaxQueue { get; set; } = 8;
    public bool EnableNativeRouting { get; set; } = true;
    public bool EnableReviewerSessions { get; set; } = true;
    // Old installations remain explicit CLI users until upgraded by Install.ps1.
    public string ReviewerBackend { get; set; } = "Cli";
    public string GuardianPath { get; set; } = "";
    public string[] GuardianPrefixArguments { get; set; } = [];
    public bool EnableNativeState { get; set; }
    public bool EnableNativeAskHandoff { get; set; }
    public string NativeStateLogPath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"Antigravity","logs","main.log");
    public int NativeStateTimeoutMilliseconds { get; set; } = 4000;
    public int MaxNativeHistoryBytes { get; set; } = 8388608;
    public int MaxEvidenceBytes { get; set; } = 49152;
    public int MaxEvidenceRecords { get; set; } = 40;
    public int MaxEvidenceContentBytes { get; set; } = 4096;
    public int MaxReviewerSessionTurns { get; set; } = 8;
    public int MaxReviewerSessionBytes { get; set; } = 262144;
    public int MaxReviewerSessionInputTokens { get; set; } = 96000;
    private volatile bool enableDetailedLogs;
    public bool EnableDetailedLogs { get => enableDetailedLogs; set => enableDetailedLogs = value; }
    public int MaxLogSegmentBytes { get; set; } = 16 * 1024 * 1024;
    public string PipeName { get; set; } = "";
    public bool DetailedLogsActive => enableDetailedLogs || string.Equals(Environment.GetEnvironmentVariable("AG_APPROVAL_DETAILED_LOGS"), "1", StringComparison.Ordinal);

    public static Settings Load(string path)
    {
        var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json.Options)
            ?? throw new InvalidDataException("Empty configuration");
        if (s.Model != "codex-auto-review" || s.Effort != "low")
            throw new InvalidDataException("This release is validated only for codex-auto-review / low");
        foreach (var p in new[] { s.DataDirectory, s.PolicyDirectory, s.CodexHome, s.AntigravityConfigDirectory })
            if (!Path.IsPathFullyQualified(p)) throw new InvalidDataException("Configuration paths must be absolute");
        if (s.ReviewerBackend is not ("Cli" or "NativeGuardian")) throw new InvalidDataException("Unknown reviewer backend");
        if (s.ReviewerBackend == "Cli" && string.IsNullOrWhiteSpace(s.CodexPath))
            throw new InvalidDataException("Configuration paths must be absolute");
        if (!string.IsNullOrWhiteSpace(s.CodexPath))
        {
            if (!Path.IsPathFullyQualified(s.CodexPath)) throw new InvalidDataException("Configuration paths must be absolute");
            if (!File.Exists(s.CodexPath)) throw new FileNotFoundException("Codex executable not found");
        }
        else
        {
            s.CodexPath = "";
        }
        if(s.ReviewerBackend=="NativeGuardian"&&(!Path.IsPathFullyQualified(s.GuardianPath)||!File.Exists(s.GuardianPath)))throw new InvalidDataException("Native Guardian executable is missing");
        if(s.ReviewerBackend=="NativeGuardian"&&s.GuardianPrefixArguments.Length>0)throw new InvalidDataException("Native Guardian prefix arguments are reserved for in-process test fixtures");
        if(s.EnableNativeState&&!Path.IsPathFullyQualified(s.NativeStateLogPath))throw new InvalidDataException("Native state log path must be absolute");
        if(s.NativeStateTimeoutMilliseconds is < 100 or > 5000 || s.MaxNativeHistoryBytes is < 262144 or > 8388608)throw new InvalidDataException("Invalid native state/history limits");
        if (s.ReviewTimeoutSeconds is < 1 or > 120 || s.HookTimeoutSeconds <= s.ReviewTimeoutSeconds || s.HookTimeoutSeconds > 150)
            throw new InvalidDataException("Invalid nested deadlines");
        if (s.MaxInputBytes is < 1024 or > 1048576 || s.MaxContextBytes is < 1024 or > 524288 || s.MaxQueue is < 1 or > 32)
            throw new InvalidDataException("Invalid resource limits");
        if(s.MaxEvidenceBytes is < 1024 or > 131072 || s.MaxEvidenceRecords is < 1 or > 100 || s.MaxEvidenceContentBytes is < 256 or > 16384 ||
            s.MaxReviewerSessionTurns is < 1 or > 32 || s.MaxReviewerSessionBytes is < 16384 or > 1048576 || s.MaxReviewerSessionInputTokens is < 4096 or > 160000)
            throw new InvalidDataException("Invalid reviewer context/session limits");
        if(s.MaxLogSegmentBytes is < 65536 or > 67108864)
            throw new InvalidDataException("Invalid log segment size limit");
        if (s.TranscriptRoots.Length == 0 || s.TranscriptRoots.Any(p => !Path.IsPathFullyQualified(p)))
            throw new InvalidDataException("Transcript roots must be explicit absolute paths");
        if (string.IsNullOrEmpty(s.PipeName))
        {
            var owner = OperatingSystem.IsWindows() ? WindowsIdentity.GetCurrent().User!.Value : Environment.UserName;
            s.PipeName = "ag-codex-" + Json.Hash(owner + Path.GetFullPath(path))[..20];
        }
        return s;
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = false };
    // This JSON is sent as model text, not embedded into HTML. Preserve Unicode to avoid
    // turning every Chinese character into six ASCII characters and inflating model input.
    public static readonly JsonSerializerOptions PromptOptions = new(JsonSerializerDefaults.Web) {
        WriteIndented = false, Encoder = JavaScriptEncoder.Create(UnicodeRanges.All)
    };
    public static string Encode(object value) => JsonSerializer.Serialize(value, Options);
    public static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    public static string? Text(JsonNode? node, string key) => node?[key]?.GetValue<string>();
    public static async Task<string> ReadBoundedAsync(TextReader reader, int maxBytes, CancellationToken ct)
    {
        var text = new StringBuilder(); var buffer = new char[4096]; int count;
        long totalBytes = 0; bool exceeded = false;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), ct)) > 0)
        {
            totalBytes += Encoding.UTF8.GetByteCount(buffer, 0, count);
            if (!exceeded)
            {
                if (totalBytes > maxBytes) exceeded = true;
                else text.Append(buffer, 0, count);
            }
            if (totalBytes > 32L * 1024 * 1024) break;
        }
        if (exceeded) throw new InvalidDataException("Input too large");
        return text.ToString();
    }
}

public sealed record GateResponse(string Decision, string Reason, string Status, string RequestId, string ActionHash)
{
    public string ReasonCode { get; init; } = "unknown";
    public object HookOutput => new { decision = Decision, reason = Reason };
    public static GateResponse Delegate(string id,string hash,ReviewRoute route) =>
        new("allow", $"Native permission rules decide this operation ({ReviewRoute.Version}/{route.RuleId}). No additional permissions were granted by this hook.", "delegated",id,hash){ReasonCode="native_delegation"};
    public static GateResponse NeedsHuman(string id, string hash, string reason,string code="reviewer_unavailable") =>
        new("force_ask", "Codex automatic review could not reach a valid decision. Human approval is required before execution. This is not a model denial. " + reason, "review_failed", id, hash){ReasonCode=code};
    public static GateResponse NativeAsk(string id,string hash,string reason,string code) =>
        new("ask","Codex review encountered a technical failure. Antigravity applies its existing permissions and asks when required. "+reason,"review_failed",id,hash){ReasonCode=code};
    public static GateResponse Failure(string id, string hash, string reason,string code="request_invalid") =>
        new("deny", "Automatic approval review could not be completed. The action was not executed. This is a review failure, not a determination that the action is unsafe. Do not bypass the approval check. Repair the evidence or review pipeline; do not ask for the same authorization repeatedly. " + reason, "review_failed", id, hash){ReasonCode=code};
    public static GateResponse OversizedForAgentRetry(string id, string hash, string detail) =>
        new("deny", "Automatic approval request exceeds the single-call context budget (" + detail + "). This is a payload size limit, not a policy denial or human approval prompt. Do not stop the task or ask the human for approval on this size limit: split this tool call into smaller incremental requests (for example, smaller targeted edit_file blocks, write_file with an initial section followed by Append=true chunks, or shorter commands) and resend.", "review_failed", id, hash){ReasonCode="request_too_large_retry_smaller"};
    public static GateResponse Repeated(string id,string hash,string reason)=>new("deny",reason,"blocked",id,hash){ReasonCode="duplicate_policy_denial"};
}
