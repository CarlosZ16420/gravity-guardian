using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AgApproval;

// A local record of explicit user choices. The existing reviewer still assesses each action.
internal static class ProjectAuthorizations
{
    internal const string Guidance = "Project authorizations are earlier user-confirmed scopes for these mounted workspaces. Apply an active scope only when the actual data, recipient and effects match, under the existing policy. Current user restrictions take precedence. Historical messages that manage standing grants do not themselves keep revoked grants active.";
    private const string Confirm = "按上述范围，本项目持续允许";
    private const string List = "查看本项目授权";
    private const string Proposal = "拟长期授权";
    private static readonly Regex Edit = new(@"\A(?:我明确)?(?<verb>本项目长期授权|本项目持续允许|撤销本项目授权)\s*[：:]\s*(?<scope>[^\r\n]+)\z", RegexOptions.CultureInvariant);

    private sealed record State(Dictionary<string,string> Grants, Dictionary<string,int> Handled);

    private static string StorePath(Settings settings, JsonArray roots)
    {
        if (roots.Count == 0) throw new InvalidDataException("Missing project roots");
        var paths = roots.Select(root => {
            var path = root?.GetValue<string>();
            if (path is null || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("Invalid project root");
            var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            return OperatingSystem.IsWindows() ? full.ToUpperInvariant() : full;
        }).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal);
        return Path.Combine(settings.DataDirectory, "project-authorizations", Json.Hash(Json.Encode(paths)) + ".json");
    }

    private static State Load(string path)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            return JsonSerializer.Deserialize<State>(file, Json.Options) is { Grants: not null, Handled: not null } state
                ? state : throw new InvalidDataException("Invalid project authorization file");
        }
        catch (FileNotFoundException) { return new(new(), new()); }
        catch (DirectoryNotFoundException) { return new(new(), new()); }
    }

    internal static JsonObject Active(Settings settings, JsonArray roots) =>
        JsonSerializer.SerializeToNode(Load(StorePath(settings, roots)).Grants, Json.Options)!.AsObject();

    private static JsonObject Feedback(string message) => new() {
        ["injectSteps"] = new JsonArray(new JsonObject { ["ephemeralMessage"] = "审批插件：" + message })
    };

    internal static JsonObject Handle(Settings settings, JsonNode input)
    {
        var text = Json.Text(input, "lastUserInput")?.Trim() ?? "";
        var choice = text.TrimEnd('。', '.', '！', '!');
        var edit = Edit.Match(text);
        bool confirm = choice == Confirm || choice == "按上面这个范围，本项目一直允许，直到我撤销";
        if (!confirm && choice != List && !edit.Success) return new();

        var conversation = Json.Text(input, "conversationId");
        if (!Guid.TryParseExact(conversation, "D", out _)) throw new InvalidDataException("Invalid conversation identity");
        var transcript = Json.Text(input, "transcriptPath") ?? throw new InvalidDataException("Missing conversation transcript");
        ReviewContext.ValidateTranscriptPath(transcript, conversation!, settings.TranscriptRoots);
        var path = StorePath(settings, input["workspacePaths"]?.AsArray() ?? throw new InvalidDataException("Missing project"));
        using var mutex = new Mutex(false, "AgApproval-Project-" + Json.Hash(Path.GetFullPath(path).ToUpperInvariant()));
        try { if (!mutex.WaitOne(TimeSpan.FromSeconds(2))) throw new IOException("Project authorizations are busy"); }
        catch (AbandonedMutexException) { /* Atomic replacement preserves the previous committed state. */ }
        try
        {
            JsonObject? latestInput = null;
            string? previousAssistant = null, proposal = null;
            int position = 0, userPosition = 0;
            foreach (var line in File.ReadLines(transcript))
            {
                position++;
                if (string.IsNullOrWhiteSpace(line)) continue;
                var row = JsonNode.Parse(line)!.AsObject();
                if (Json.Text(row, "type") == "USER_INPUT")
                {
                    latestInput = row;
                    userPosition = position;
                    proposal = previousAssistant;
                    previousAssistant = null;
                }
                else if (Json.Text(row, "source") == "MODEL" && Json.Text(row, "type") == "PLANNER_RESPONSE")
                    previousAssistant = Json.Text(row, "content");
            }
            if (latestInput == null || !NativeTranscript.IsExplicitUser(latestInput)) return new();
            if (latestInput["truncated_fields"] is JsonArray fields && fields.Any(f => f?.GetValue<string>() is "content" or "original_content"))
                return Feedback("用户回复被截断，本次未更改授权。");
            ReviewAdapter.SeparateNativeEnvelope(latestInput);
            if (!string.Equals(Json.Text(latestInput, "content")?.Trim(), text, StringComparison.Ordinal)) return new();

            var state = Load(path);
            if (state.Handled.GetValueOrDefault(conversation!) >= userPosition) return new();
            string message;
            if (choice == List)
            {
                message = state.Grants.Count == 0 ? "本项目没有长期授权。" :
                    "本项目有效授权：\n" + string.Join("\n", state.Grants.Select(g => g.Key + "  " + g.Value));
            }
            else if (edit.Groups["verb"].Value == "撤销本项目授权")
            {
                var target = edit.Groups["scope"].Value.Trim().TrimEnd('。');
                if (target == "全部") { state.Grants.Clear(); message = "已撤销本项目的全部长期授权。"; }
                else message = state.Grants.Remove(target) ? "已撤销本项目授权 " + target : "本项目没有该授权编号。";
            }
            else
            {
                var scope = edit.Groups["scope"].Value.Trim();
                if (confirm)
                {
                    var scopes = (proposal ?? "").Split('\n').Select(s => s.Trim())
                        .Where(s => s.StartsWith(Proposal + "：", StringComparison.Ordinal) || s.StartsWith(Proposal + ":", StringComparison.Ordinal)).ToArray();
                    scope = scopes.Length == 1 ? scopes[0][(Proposal.Length + 1)..].Trim() : "";
                }
                if (scope.Length is 0 or > 2048)
                    message = "未保存。请单独发送「本项目长期授权：具体范围」，一行即可。";
                else
                {
                    var id = Json.Hash(scope)[..12];
                    state.Grants[id] = scope;
                    message = $"已保存本项目长期授权 {id}，直到撤销。范围：{scope}";
                }
            }
            state.Handled[conversation!] = userPosition;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(state, Json.PromptOptions));
            File.Move(temporary, path, true);
            return Feedback(message);
        }
        finally { mutex.ReleaseMutex(); }
    }
}
