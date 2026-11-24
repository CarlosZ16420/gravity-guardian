using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using AgApproval;

public static class PanelCoreTests
{
    public static async Task RunAsync(Settings baseSettings, string scratchRoot, Func<string, Func<Task>, Task> test)
    {
        void Check(bool cond, string msg) { if (!cond) throw new Exception(msg); }

        await test("pricing estimation applies GPT-6 Luna 2x rates with and without cached input", () =>
        {
            var p = PricingProfile.Default;
            Check(p.Multiplier == 2.0m && p.InputPerMillionUsd == 0.10m && p.CachedInputPerMillionUsd == 0.01m && p.OutputPerMillionUsd == 0.50m,
                "default GPT-6 Luna 2x rates mismatch");

            // 1,000,000 input (800,000 cached + 200,000 uncached) + 100,000 output:
            // base = 0.2 * 0.10 + 0.8 * 0.01 + 0.1 * 0.50 = 0.02 + 0.008 + 0.05 = 0.078 -> x2 = 0.156
            var withCache = p.EstimateUsd(1_000_000, 800_000, 100_000);
            Check(withCache == 0.156000m, $"unexpected cached cost: {withCache}");

            // Without cachedInputTokens (conservative uncached pricing):
            // base = 1.0 * 0.10 + 0.1 * 0.50 = 0.15 -> x2 = 0.30
            var noCache = p.EstimateUsd(1_000_000, null, 100_000);
            Check(noCache == 0.300000m, $"unexpected uncached cost: {noCache}");
            return Task.CompletedTask;
        });

        await test("local-timezone usage stats handle UTC midnight boundaries, invalidations, and legacy retries", () =>
        {
            var dataDir = Path.Combine(scratchRoot, "stats-utc-boundary");
            var logsDir = Path.Combine(dataDir, "logs");
            Directory.CreateDirectory(logsDir);

            // Simulated local time: 2026-11-21 10:00:00 +08:00
            var now = new DateTimeOffset(2026, 11, 21, 10, 0, 0, TimeSpan.FromHours(8));

            // Event at 2026-11-21 01:30 +08:00 == 2026-11-20 17:30Z -> sits in UTC 2026-11-20 file, MUST count as Today!
            var utc20Lines = new[]
            {
                Json.Encode(new { at = "2026-11-20T17:30:00Z", @event = "review_completed", requestId = "r-today", status = "approved", decision = "auto_approve", assessmentText = "{\"outcome\":\"allow\"}" }),
                Json.Encode(new { at = "2026-11-20T17:30:01Z", @event = "review_usage", requestId = "r-today", backend = "native_guardian", attemptCount = 1, modelCallEvidence = true, usage = new { status = "reported", source = "native_guardian.attempt_deltas", inputTokens = 100000, cachedInputTokens = 80000, outputTokens = 10000, reasoningOutputTokens = 2000, totalTokens = 110000 } }),
                // Legacy incomplete record with attemptCount != 1 -> MUST be excluded from token/cost totals
                Json.Encode(new { at = "2026-11-20T17:31:00Z", @event = "review_usage", requestId = "r-legacy", backend = "native_guardian", attemptCount = 2, modelCallEvidence = true, usage = new { status = "reported", source = "native_guardian.last_attempt_delta", inputTokens = 999999, outputTokens = 99999, totalTokens = 1099998 } })
            };
            File.WriteAllLines(Path.Combine(logsDir, "2026-11-20.000.jsonl"), utc20Lines);

            // Event 4 days ago (2026-11-17 +08:00) -> Last7Days only, invalidated later
            var utc17Lines = new[]
            {
                Json.Encode(new { at = "2026-11-17T06:00:00Z", @event = "review_completed", requestId = "r-inv", status = "approved", decision = "auto_approve", assessmentText = "{\"outcome\":\"allow\"}" }),
                Json.Encode(new { at = "2026-11-17T06:00:01Z", @event = "review_invalidated", requestId = "r-inv", decision = "deny", reasonCode = "action_invalidated" }),
                Json.Encode(new { at = "2026-11-17T06:05:00Z", @event = "review_completed", requestId = "r-del", status = "delegated", decision = "allow" }),
                Json.Encode(new { at = "2026-11-17T06:00:02Z", @event = "review_usage", requestId = "r-inv", backend = "native_guardian", attemptCount = 1, modelCallEvidence = true, usage = new { status = "reported", source = "native_guardian.attempt_deltas", inputTokens = 50000, outputTokens = 5000, totalTokens = 55000 } })
            };
            File.WriteAllLines(Path.Combine(logsDir, "2026-11-17.000.jsonl"), utc17Lines);

            // Event 8 days ago (2026-11-13) -> MUST be excluded from Last7Days (Nov 15..21)
            File.WriteAllLines(Path.Combine(logsDir, "2026-11-13.000.jsonl"), [
                Json.Encode(new { at = "2026-11-13T10:00:00Z", @event = "review_completed", requestId = "r-old", status = "approved", decision = "auto_approve" }),
                Json.Encode(new { at = "2026-11-13T10:00:01Z", @event = "review_usage", requestId = "r-old", backend = "native_guardian", attemptCount = 1, usage = new { status = "reported", inputTokens = 500000, outputTokens = 50000, totalTokens = 550000 } })
            ]);

            var report = UsageStats.Compute(dataDir, null, now);
            Check(report.Today.TotalRequests == 1 && report.Today.Approved == 1, $"today requests mismatch: {Json.Encode(report.Today)}");
            Check(report.Today.TotalTokens == 110000 && report.Today.CachedInputTokens == 80000, $"today tokens mismatch: {Json.Encode(report.Today)}");
            // Today cost: (20k*0.10 + 80k*0.01 + 10k*0.50)/1M * 2 = (2000 + 800 + 5000)/1M * 2 = 0.0156
            Check(report.Today.EstimatedCostUsd == 0.015600m, $"today cost mismatch: {report.Today.EstimatedCostUsd}");

            Check(report.Last7Days.TotalRequests == 3 && report.Last7Days.Approved == 1 && report.Last7Days.Failed == 1 && report.Last7Days.Delegated == 1,
                $"last7 breakdown mismatch: {Json.Encode(report.Last7Days)}");
            Check(report.Last7Days.TotalTokens == 165000, $"last7 tokens mismatch: {report.Last7Days.TotalTokens}");
            // r-inv has null cachedInputTokens -> (50k*0.10 + 5k*0.50)/1M * 2 = (5000+2500)/1M*2 = 0.0150; total = 0.0306
            Check(report.Last7Days.EstimatedCostUsd == 0.030600m, $"last7 cost mismatch: {report.Last7Days.EstimatedCostUsd}");
            Check(report.CustomRange is null, "legacy stats call included a custom range");

            var olderDates = new LocalDateRange(new DateOnly(2026, 11, 13), new DateOnly(2026, 11, 17));
            var older = UsageStats.Compute(dataDir, nowOverride: now, customRange: olderDates);
            Check(older.CustomRange is { TotalRequests: 3, Approved: 1, Failed: 1, Delegated: 1, TotalTokens: 605000, EstimatedCostUsd: 0.165000m },
                $"custom range did not include both endpoints and historical usage: {Json.Encode(older)}");
            Check(older.Today.TotalRequests == 1 && older.Last7Days.TotalRequests == 3, "custom range changed preset totals");

            var day = new DateOnly(2026, 11, 21);
            var sameDay = UsageStats.Compute(dataDir, nowOverride: now, customRange: new LocalDateRange(day, day));
            Check(sameDay.CustomRange is { TotalRequests: 1, TotalTokens: 110000 }, "single local day missed its previous UTC segment");
            return Task.CompletedTask;
        });

        await test("EnvironmentDiscovery unwraps npm codex.cmd shim to native codex.exe", () =>
        {
            var npmRoot = Path.Combine(scratchRoot, "fake-npm");
            var vendorExe = Path.Combine(npmRoot, "node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(vendorExe)!);
            File.WriteAllText(vendorExe, "MZ-stub");
            var cmdShim = Path.Combine(npmRoot, "codex.cmd");
            File.WriteAllText(cmdShim, "@ECHO off\r\nnode \"%~dp0\\node_modules\\@openai\\codex\\bin\\codex.js\" %*\r\n");

            var resolved = EnvironmentDiscovery.ResolveCodexShim(cmdShim);
            Check(string.Equals(resolved, Path.GetFullPath(vendorExe), StringComparison.OrdinalIgnoreCase), $"shim resolved to '{resolved}' instead of '{vendorExe}'");
            return Task.CompletedTask;
        });

        await test("usage stats distinguish zero-dispatch fallback from missing and reported use", () =>
        {
            var dataDir=Path.Combine(scratchRoot,"stats-fallback-dispatch");
            var logs=Path.Combine(dataDir,"logs");
            Directory.CreateDirectory(logs);
            var now=new DateTimeOffset(2026,11,21,12,0,0,TimeSpan.Zero);
            File.WriteAllLines(Path.Combine(logs,"fixture.jsonl"),[
                Json.Encode(new {at=now,@event="review_usage",requestId="fallback",backend="native_guardian",inferenceDispatchCount=0,usage=new {status="unknown"}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="fallback",usage=new {status="reported",inputTokens=20,outputTokens=2}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="both",backend="native_guardian",inferenceDispatchCount=1,usage=new {status="reported",inputTokens=31,outputTokens=3}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="both",usage=new {status="reported",inputTokens=9,outputTokens=1}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="dispatched",backend="native_guardian",inferenceDispatchCount=1,usage=new {status="unknown"}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="unknown",backend="native_guardian",usage=new {status="unknown"}}),
                Json.Encode(new {at=now,@event="review_usage",requestId="legacy-zero",backend="native_guardian",inferenceRequests=0,usage=new {status="unknown"}})
            ]);
            void CheckReport()
            {
                var result=UsageStats.Compute(dataDir,nowOverride:now).Today;
                Check(result.ReportedUsageCalls==3 && result.UnknownOrPartialUsageCalls==2 && result.TotalTokens==66,Json.Encode(result));
            }
            CheckReport();
            var cacheFile=Path.Combine(dataDir,"stats-cache.json");
            var cache=JsonNode.Parse(File.ReadAllText(cacheFile))!;
            cache["fixture.jsonl"]!.AsObject().Remove("version");
            foreach(var usage in cache["fixture.jsonl"]!["usage"]!.AsArray())
                usage!.AsObject().Remove("inferenceDispatchCount");
            File.WriteAllText(cacheFile,cache.ToJsonString());
            CheckReport();
            CheckReport();
            return Task.CompletedTask;
        });

        await test("Settings.Load allows empty CodexPath for NativeGuardian while requiring it for Cli", () =>
        {
            var cfgDir = Path.Combine(scratchRoot, "settings-codexpath");
            Directory.CreateDirectory(cfgDir);
            var cfgPath = Path.Combine(cfgDir, "approval.json");
            var fakeGuardian = Path.Combine(cfgDir, "guardian.exe");
            File.WriteAllText(fakeGuardian, "stub");

            var nativeCfg = new JsonObject
            {
                ["model"] = "codex-auto-review",
                ["effort"] = "low",
                ["codexPath"] = "",
                ["dataDirectory"] = baseSettings.DataDirectory,
                ["policyDirectory"] = baseSettings.PolicyDirectory,
                ["codexHome"] = baseSettings.CodexHome,
                ["antigravityConfigDirectory"] = baseSettings.AntigravityConfigDirectory,
                ["transcriptRoots"] = new JsonArray(baseSettings.TranscriptRoots[0]),
                ["reviewerBackend"] = "NativeGuardian",
                ["guardianPath"] = fakeGuardian
            };
            File.WriteAllText(cfgPath, nativeCfg.ToJsonString());
            var loaded = Settings.Load(cfgPath);
            Check(loaded.CodexPath == "", "NativeGuardian failed with empty CodexPath");

            nativeCfg["reviewerBackend"] = "Cli";
            File.WriteAllText(cfgPath, nativeCfg.ToJsonString());
            bool failed = false;
            try { Settings.Load(cfgPath); } catch (InvalidDataException) { failed = true; }
            Check(failed, "Cli backend unexpectedly accepted empty CodexPath");
            return Task.CompletedTask;
        });

        await test("live host IPC toggles detailed logs without restart and LogCompactor strips verbose dumps", async () =>
        {
            var ipcData = Path.Combine(scratchRoot, "ipc-hot-log");
            Directory.CreateDirectory(Path.Combine(ipcData, "logs"));
            var fakeGuardian = Path.Combine(ipcData, "fake-guardian.exe");
            File.Copy(Environment.ProcessPath!, fakeGuardian, overwrite: true);

            var cfgPath = Path.Combine(ipcData, "approval.json");
            var cfg = new Settings
            {
                CodexPath = "",
                CodexHome = baseSettings.CodexHome,
                DataDirectory = ipcData,
                PolicyDirectory = baseSettings.PolicyDirectory,
                AntigravityConfigDirectory = baseSettings.AntigravityConfigDirectory,
                TranscriptRoots = baseSettings.TranscriptRoots,
                ReviewerBackend = "Cli", // dummy non-spawning until reviewed; switch to Cli with dummy exe
                EnableDetailedLogs = false
            };
            cfg.CodexPath = Environment.ProcessPath!;
            cfg.PipeName = "ag-test-panel-" + Guid.NewGuid().ToString("N")[..12];

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var hostTask = AgApproval.Program.HostAsync(cfg);

            // Wait briefly for named pipe to start listening
            JsonNode? statusBefore = null;
            for (int i = 0; i < 30; i++)
            {
                try
                {
                    var raw = await AgApproval.Program.RequestAsync(cfg, new { operation = "status" }, TimeSpan.FromSeconds(1));
                    statusBefore = JsonNode.Parse(raw);
                    break;
                }
                catch { await Task.Delay(50); }
            }
            Check(statusBefore != null && statusBefore["detailedLogs"]?.GetValue<bool>() == false, "initial detailedLogs should be false");

            var toggleOn = JsonNode.Parse(await AgApproval.Program.RequestAsync(cfg, new { operation = "set_logging", enabled = true }, TimeSpan.FromSeconds(2)))!;
            Check(toggleOn["ok"]?.GetValue<bool>() == true && toggleOn["detailedLogs"]?.GetValue<bool>() == true, "set_logging failed to enable live");

            var statusAfter = JsonNode.Parse(await AgApproval.Program.RequestAsync(cfg, new { operation = "status" }, TimeSpan.FromSeconds(2)))!;
            Check(statusAfter["detailedLogs"]?.GetValue<bool>() == true, "status did not reflect live detailedLogs=true");

            await AgApproval.Program.RequestAsync(cfg, new { operation = "stop" }, TimeSpan.FromSeconds(2));
            await hostTask.WaitAsync(TimeSpan.FromSeconds(5));

            // Compact logs test
            var compactData = Path.Combine(scratchRoot, "compact-fixture");
            var compactLogs = Path.Combine(compactData, "logs");
            Directory.CreateDirectory(compactLogs);
            var logFile = Path.Combine(compactLogs, "2026-11-21.000.jsonl");
            var bigPayload = new string('x', 9000);
            File.WriteAllLines(logFile, [
                Json.Encode(new { at = "2026-11-21T01:00:00Z", @event = "review_context", data = bigPayload }),
                Json.Encode(new { at = "2026-11-21T01:00:01Z", @event = "guardian_input", data = bigPayload }),
                Json.Encode(new { at = "2026-11-21T01:00:02Z", @event = "tool_completed", requestId = "1", payload = new { huge = bigPayload } }),
                Json.Encode(new { at = "2026-11-21T01:00:03Z", @event = "review_completed", requestId = "1", status = "approved" })
            ]);
            var compact = LogCompactor.Compact(compactData);
            Check(compact.DroppedVerboseDumps == 2 && compact.KeptEvents == 2 && compact.AfterBytes < compact.BeforeBytes,
                $"compactor unexpected result: {Json.Encode(compact)}");
        });
    }
}
