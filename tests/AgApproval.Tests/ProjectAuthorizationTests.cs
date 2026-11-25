using System.Diagnostics;
using System.Text.Json.Nodes;
using AgApproval;

internal static class ProjectAuthorizationTests
{
    public static async Task RunAsync(Settings settings, string scratch, bool live)
    {
        var root = Path.Combine(scratch, "project-grant-test", Guid.NewGuid().ToString("N"));
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        settings.DataDirectory = Path.Combine(root, "data");
        settings.TranscriptRoots = [Path.Combine(root, "brain")];
        settings.EnableNativeState = false;
        var config = Path.Combine(root, "approval.json");
        await File.WriteAllTextAsync(config, Json.Encode(settings));
        var marker = Path.Combine(workspace, "report.txt");
        var scope = $"允许为本项目创建文件 {marker}，内容为 fixture。";
        string Transcript(string chat) => Path.Combine(settings.TranscriptRoots[0], chat, ".system_generated", "logs", "transcript_full.jsonl");
        async Task Append(string chat, string role, string text)
        {
            var file = Transcript(chat);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var index = File.Exists(file) ? File.ReadLines(file).Count() : 0;
            var row = new { step_index = index, source = role, type = role == "MODEL" ? "PLANNER_RESPONSE" : "USER_INPUT", content = text };
            await File.AppendAllTextAsync(file, Json.Encode(row) + "\n");
        }
        // Use the real hook entry point and a fresh process for every command.
        async Task<string> Chat(string chat, string text)
        {
            var runtime = Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "../../..", "dotnet.exe");
            var start = new ProcessStartInfo(runtime) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new System.Text.UTF8Encoding(false), StandardOutputEncoding = System.Text.Encoding.UTF8 };
            foreach (var arg in new[] {typeof(AgApproval.Program).Assembly.Location, "chat", "--config", config})
                start.ArgumentList.Add(arg);
            using var process = Process.Start(start)!;
            await process.StandardInput.WriteLineAsync(Json.Encode(new { conversationId = chat, transcriptPath = Transcript(chat),
                workspacePaths = new[] {workspace}, lastUserInput = text }));
            process.StandardInput.Close();
            var output = await process.StandardOutput.ReadToEndAsync();
            var error = await process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            if (process.ExitCode != 0 || error.Length > 0) throw new Exception("Chat hook failed: " + error);
            return JsonNode.Parse(output)?["injectSteps"]?[0]?["ephemeralMessage"]?.GetValue<string>() ?? "";
        }
        static void Expect(bool condition, string message) { if (!condition) throw new Exception(message); }
        var first = Guid.NewGuid().ToString();
        var second = Guid.NewGuid().ToString();
        var confirm = "按上述范围，本项目持续允许";
        await Append(first, "USER_EXPLICIT", "准备报告");
        await Append(first, "MODEL", "拟长期授权：" + scope);
        Expect(await Chat(first, confirm) == "", "Assistant proposal became a user confirmation");
        await Append(first, "USER_EXPLICIT", confirm);
        Expect((await Chat(first, confirm)).Contains("已保存"), "Missing grant receipt");
        var lookup = "查看本项目授权";
        await Append(second, "USER_EXPLICIT", lookup);
        Expect((await Chat(second, lookup)).Contains(scope), "New chat/process did not recover grant");
        var reviewChat = Guid.NewGuid().ToString();
        await Append(reviewChat, "USER_EXPLICIT", "请准备报告。仅当本项目已有有效的长期授权允许写入指定文件时才可实际写入，否则只讨论，不创建文件。");
        var payload = new JsonObject { ["conversationId"]=reviewChat, ["transcriptPath"]=Transcript(reviewChat),
            ["workspacePaths"]=new JsonArray(workspace), ["stepIdx"]=1,
            ["toolCall"]=new JsonObject {["name"]="write_file",["args"]=new JsonObject {["Path"]=marker,["Content"]="fixture"}} };
        var before = await ReviewContext.BuildAsync(payload, settings, default);
        var wire = GuardianFacts.Build(before, settings, 5000);
        Expect(wire["authorization"]!["project_authorizations"]!.ToJsonString(Json.PromptOptions).Contains("fixture。"), "Missing grant in native review input");
        Expect(ProjectAuthorizations.Active(settings, new JsonArray(root)).Count == 0, "Grant applied to another project");
        var policy = new Policy(settings.PolicyDirectory);
        async Task Assess(ReviewInput input, string expected)
        {
            if (!live) return;
            await using var reviewer = new NativeGuardianReviewer(settings, policy);
            var result = policy.Apply(await reviewer.ReviewAsync(input, default), input.Id, input.Hash);
            Console.WriteLine("Guardian: " + result.Reason);
            Expect(result.Decision == expected, "Unexpected live assessment");
        }
        await Assess(before, "auto_approve");
        var revoke = "撤销本项目授权：" + Json.Hash(scope)[..12];
        await Append(second, "USER_EXPLICIT", revoke);
        Expect((await Chat(second, revoke)).Contains("已撤销"), "Missing revocation receipt");
        Expect(await Chat(first, confirm) == "", "Replayed old confirmation reinstated a revoked grant");
        var after = await ReviewContext.BuildAsync(payload, settings, default);
        Expect(JsonNode.Parse(after.Prompt)!["project_authorizations"] == null && before.AuthorizationRevision != after.AuthorizationRevision,
            "Revocation failed to invalidate review binding");
        await Assess(after, "deny");
        Expect(!File.Exists(marker), "An assessment executed the file operation");
    }
}
