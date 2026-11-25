using System.Diagnostics;
using System.Globalization;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

namespace AgApproval;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.InputEncoding = Encoding.UTF8; Console.OutputEncoding = new UTF8Encoding(false);
        var command = args.FirstOrDefault() ?? "help";
        Settings? failureSettings=null;
        JsonNode? failurePayload=null;
        string config = Option(args, "--config") ?? StorageLayout.DefaultConfigPath();
        try
        {
            if (command == "detect")
            {
                string? agOpt = Option(args, "--antigravity");
                string? geminiRoot = Option(args, "--gemini-root");
                string? dataDir = Option(args, "--data-dir");
                bool skipLogin = args.Contains("--skip-login-check");
                Console.WriteLine(Json.Encode(EnvironmentDiscovery.DetectAll(agOpt, geminiRoot, dataDir, skipLogin, Option(args, "--config"))));
                return 0;
            }
            if (command == "stats")
            {
                var dataDir = ResolveDataDir(args, config);
                var pricingPath = ResolvePricingPath(args, config);
                Console.WriteLine(Json.Encode(UsageStats.Compute(dataDir, pricingPath, customRange: StatsDateRange(args))));
                return 0;
            }
            if (command == "compact-logs")
            {
                var dataDir = ResolveDataDir(args, config);
                Console.WriteLine(Json.Encode(LogCompactor.Compact(dataDir)));
                return 0;
            }
            if (command == "set-logging")
            {
                var enabledRaw = Option(args, "--enabled") ?? throw new InvalidDataException("Missing --enabled <true|false>");
                bool enabled = enabledRaw.ToLowerInvariant() switch
                {
                    "true" or "1" or "yes" => true,
                    "false" or "0" or "no" => false,
                    _ => throw new InvalidDataException("Invalid --enabled value")
                };
                if (!File.Exists(config)) throw new FileNotFoundException("Configuration file not found", config);
                var doc = JsonNode.Parse(File.ReadAllText(config))?.AsObject() ?? throw new InvalidDataException("Invalid configuration");
                doc["enableDetailedLogs"] = enabled;
                var tmp = config + ".logging.tmp";
                File.WriteAllText(tmp, doc.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
                File.Move(tmp, config, overwrite: true);

                var s = Settings.Load(config);
                bool liveUpdated = false;
                try
                {
                    var reply = await RequestAsync(s, new { operation = "set_logging", enabled }, TimeSpan.FromSeconds(2));
                    liveUpdated = JsonNode.Parse(reply)?["ok"]?.GetValue<bool>() == true;
                }
                catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
                Console.WriteLine(Json.Encode(new { ok = true, persisted = true, liveUpdated, detailedLogs = s.DetailedLogsActive }));
                return 0;
            }
            if (command == "set-protected-delegation")
            {
                var enabledRaw = Option(args, "--enabled") ?? throw new InvalidDataException("Missing --enabled <true|false>");
                bool enabled = enabledRaw.ToLowerInvariant() switch
                {
                    "true" or "1" or "yes" => true,
                    "false" or "0" or "no" => false,
                    _ => throw new InvalidDataException("Invalid --enabled value")
                };
                if (!File.Exists(config)) throw new FileNotFoundException("Configuration file not found", config);
                var doc = JsonNode.Parse(File.ReadAllText(config))?.AsObject() ?? throw new InvalidDataException("Invalid configuration");
                doc["delegateProtectedPaths"] = enabled;
                var tmp = config + ".delegation.tmp";
                File.WriteAllText(tmp, doc.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
                File.Move(tmp, config, overwrite: true);

                var s = Settings.Load(config);
                bool liveUpdated = false;
                try
                {
                    var reply = await RequestAsync(s, new { operation = "set_protected_delegation", enabled }, TimeSpan.FromSeconds(2));
                    liveUpdated = JsonNode.Parse(reply)?["ok"]?.GetValue<bool>() == true;
                }
                catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
                if (!liveUpdated)
                    ProtectedPathDelegation.TrySync(s, hostActive: false, config);
                Console.WriteLine(Json.Encode(new { ok = true, persisted = true, liveUpdated, delegateProtectedPaths = s.DelegateProtectedPaths,
                    activeProtectedGrants = ProtectedPathDelegation.ReadOwnedGrants(s.DataDirectory).OrderBy(x => x, StringComparer.Ordinal).ToArray() }));
                return 0;
            }
            var settings = Settings.Read(config);
            if (command == "takeover")
            {
                if (args.Contains("--enabled"))
                {
                    if (!bool.TryParse(Option(args, "--enabled"), out bool enabled))
                        throw new InvalidDataException("Expected --enabled <true|false>");
                    settings.SetTakeoverEnabled(enabled);
                    bool hostOnline = false;
                    if (enabled)
                    {
                        try
                        {
                            settings.Validate(config);
                            var running = JsonNode.Parse(await RequestAsync(settings, new { operation = "status" }, TimeSpan.FromSeconds(1)));
                            hostOnline = Json.Text(running, "status") == "running";
                        }
                        catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException or InvalidDataException or System.Text.Json.JsonException) { }
                    }
                    ProtectedPathDelegation.TrySync(settings, hostActive: enabled && hostOnline, config);
                }
                Console.WriteLine(Json.Encode(new { takeoverEnabled = settings.IsTakeoverEnabled() }));
                return 0;
            }
            if (command is ("review" or "chat" or "session" or "post") && !settings.IsTakeoverEnabled())
            {
                if (ProtectedPathDelegation.HasOwnedGrants(settings.DataDirectory))
                    ProtectedPathDelegation.TryRevoke(settings);
                // Consume the hook payload without parsing it, including large requests written to the pipe.
                using var input = Console.OpenStandardInput();
                await input.CopyToAsync(Stream.Null);
                Console.WriteLine(command == "review" ? "{\"decision\":\"allow\"}" : "{}");
                return 0;
            }
            settings.Validate(config);
            failureSettings=settings;
            if (command == "check-guardian")
            {
                await using var reviewer = new NativeGuardianReviewer(settings, new Policy(settings.PolicyDirectory));
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                await reviewer.CheckHandshakeAsync(timeout.Token);
                Console.WriteLine("{\"ok\":true}");
                return 0;
            }
            if (command == "chat")
            {
                using var input = Console.OpenStandardInput();
                await input.CopyToAsync(Stream.Null);
                Console.WriteLine("{}");
                return 0;
            }
            if (command == "host") { await HostAsync(settings, config); return 0; }
            if (command == "ensure") { await EnsureAsync(settings, config); return 0; }
            if (command == "supervise")
            {
                while (!File.Exists(Path.Combine(settings.DataDirectory,"uninstalled")))
                {
                    try
                    {
                        var current = File.Exists(config) ? Settings.Read(config) : settings;
                        current.Validate(config);
                        await EnsureAsync(current, config);
                        ProtectedPathDelegation.TrySync(current, hostActive: true, config);
                    }
                    catch (Exception e) when (e is IOException or InvalidOperationException or InvalidDataException or System.Text.Json.JsonException)
                    {
                        ProtectedPathDelegation.TryRevoke(settings);
                        Console.Error.WriteLine(e.GetType().Name);
                    }
                    await Task.Delay(2000);
                }
                ProtectedPathDelegation.TryRevoke(settings);
                return 0;
            }
            if (command == "status") { Console.WriteLine(await RequestAsync(settings, new { operation = "status" }, TimeSpan.FromSeconds(3))); return 0; }
            if(command=="native-state")
            {
                using var ct=new CancellationTokenSource(TimeSpan.FromSeconds(6));
                var payload=JsonNode.Parse(await Json.ReadBoundedAsync(Console.In,settings.MaxInputBytes,ct.Token))!;
                var state=await AntigravityState.ReadAsync(settings,Json.Text(payload,"conversationId")!,payload["stepIdx"]!.GetValue<int>(),payload["toolCall"]!.AsObject(),ct.Token);
                var refresh=await AntigravityState.ReadAsync(settings,Json.Text(payload,"conversationId")!,payload["stepIdx"]!.GetValue<int>(),payload["toolCall"]!.AsObject(),ct.Token);
                Console.WriteLine(Json.Encode(new{snapshot=refresh,refreshMatched=ReviewAdapter.Canonical(state)==ReviewAdapter.Canonical(refresh),queryCount=2,modelCalled=false}));return 0;
            }
            if (command == "stop") { Console.WriteLine(await RequestAsync(settings, new { operation = "stop" }, TimeSpan.FromSeconds(3))); return 0; }
            if (command == "review")
            {
                var hookDeadline=DateTimeOffset.UtcNow.AddSeconds(settings.HookTimeoutSeconds);
                using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(settings.HookTimeoutSeconds));
                var raw = await Json.ReadBoundedAsync(Console.In, settings.MaxInputBytes, ct.Token);
                var payload = JsonNode.Parse(raw) ?? throw new InvalidDataException("Invalid Hook input");
                failurePayload=payload;
                var result = await RequestAsync(settings, new { operation = "review", payload, deadlineUnixMs=hookDeadline.ToUnixTimeMilliseconds() },ct.Token);
                var response = System.Text.Json.JsonSerializer.Deserialize<GateResponse>(result, Json.Options) ?? throw new InvalidDataException("Invalid host response");
                if (response.Decision is not ("deny" or "auto_approve" or "force_ask" or "allow" or "ask")) throw new InvalidDataException("Unknown host decision");
                using var auditDeadline=CancellationTokenSource.CreateLinkedTokenSource(ct.Token);auditDeadline.CancelAfter(250);
                await Audit.TryAppendAsync(settings,new{at=DateTimeOffset.UtcNow,@event="hook_decision",requestId=response.RequestId,
                    conversationId=Json.Text(payload,"conversationId"),stepIdx=payload["stepIdx"],toolIdentity=ToolIdentity(payload),hookDecision=response.Decision,reasonCode=response.ReasonCode},auditDeadline.Token);
                ct.Token.ThrowIfCancellationRequested();
                Console.WriteLine(Json.Encode(response.HookOutput)); return 0;
            }
            if (command == "session")
            {
                using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var input = await Json.ReadBoundedAsync(Console.In, settings.MaxInputBytes, ct.Token);
                var p = JsonNode.Parse(input);
                await Audit.AppendAsync(settings, new { at = DateTimeOffset.UtcNow, @event = "session_start", conversationId = Json.Text(p,"conversationId") }, ct.Token);
                Console.WriteLine("{}"); return 0;
            }
            if (command == "post")
            {
                using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var p = JsonNode.Parse(await Json.ReadBoundedAsync(Console.In, settings.MaxInputBytes, ct.Token));
                object completedEvent = settings.DetailedLogsActive
                    ? new { at = DateTimeOffset.UtcNow, @event = "tool_completed", conversationId = Json.Text(p,"conversationId"),
                        stepIdx = p?["stepIdx"]?.GetValue<int>(), tool = Json.Text(p?["toolCall"],"name"), toolIdentity=ToolIdentity(p), hadError = !string.IsNullOrEmpty(Json.Text(p,"error")), payload=p }
                    : new { at = DateTimeOffset.UtcNow, @event = "tool_completed", conversationId = Json.Text(p,"conversationId"),
                        stepIdx = p?["stepIdx"]?.GetValue<int>(), tool = Json.Text(p?["toolCall"],"name"), toolIdentity=ToolIdentity(p), hadError = !string.IsNullOrEmpty(Json.Text(p,"error")) };
                await Audit.AppendAsync(settings, completedEvent, ct.Token);
                Console.WriteLine("{}"); return 0;
            }
            Console.Error.WriteLine("Usage: gravity-guardian <host|ensure|review|status|stop|session|post|detect|stats|set-logging|set-protected-delegation|compact-logs|takeover> --config <absolute-file>");
            return 2;
        }
        catch (Exception e)
        {
            if (command == "review")
            {
                var failure = e is InvalidDataException && e.Message == "Input too large" && failureSettings != null
                    ? GateResponse.OversizedForAgentRetry("", "", $"Hook payload exceeds {failureSettings.MaxInputBytes} byte single-request limit")
                    : failurePayload != null
                        ? GateResponse.Failure("", "", "Approval service unavailable or invalid host response.","reviewer_unavailable")
                        : GateResponse.Failure("", "", "Invalid Hook input or configuration.");
                if(failureSettings!=null)
                {
                    if (failure.ReasonCode == "reviewer_unavailable")
                        ProtectedPathDelegation.TryRevoke(failureSettings);
                    object failEvent = failureSettings.DetailedLogsActive
                        ? new {at=DateTimeOffset.UtcNow,@event="hook_review_failed",error=e.GetType().Name,decision=failure.Decision,hookResponse=failure.HookOutput,payload=failurePayload}
                        : new {at=DateTimeOffset.UtcNow,@event="hook_review_failed",error=e.GetType().Name,decision=failure.Decision,conversationId=Json.Text(failurePayload,"conversationId"),stepIdx=failurePayload?["stepIdx"]?.DeepClone(),tool=Json.Text(failurePayload?["toolCall"],"name")};
                    try { await Audit.AppendAsync(failureSettings, failEvent, CancellationToken.None); }
                    catch(Exception logError) when(logError is IOException or UnauthorizedAccessException){Console.Error.WriteLine("Cannot persist hook failure log");}
                }
                Console.WriteLine(Json.Encode(failure.HookOutput));
                Console.Error.WriteLine(e.GetType().Name + ": " + e.Message); return 0;
            }
            if (command is "session" or "post" or "chat") { Console.WriteLine("{}"); Console.Error.WriteLine(e.GetType().Name); return 0; }
            Console.Error.WriteLine(e.GetType().Name + ": " + e.Message); return 1;
        }
    }

    public static async Task<string> RequestAsync(Settings settings, object request, TimeSpan timeout)
    {
        using var ct = new CancellationTokenSource(timeout);
        return await RequestAsync(settings,request,ct.Token);
    }
    private static async Task<string> RequestAsync(Settings settings,object request,CancellationToken ct)
    {
        using var pipe = new NamedPipeClientStream(".", settings.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(ct);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true);
        await writer.WriteLineAsync(System.Text.Json.JsonSerializer.Serialize(request,Json.PromptOptions).AsMemory(), ct);
        return await ReadLineAsync(reader, settings.MaxInputBytes + 16384, ct);
    }

    public static async Task<string> ReadLineAsync(StreamReader reader, int maxBytes, CancellationToken ct)
    {
        // A bounded framing reader also protects the long-lived host from oversized IPC messages.
        var result = new StringBuilder(); var one = new char[1]; int bytes = 0;bool high=false;
        while (await reader.ReadAsync(one.AsMemory(), ct) > 0)
        {
            if (one[0] == '\n') return result.ToString();
            var c=one[0];
            result.Append(c);bytes+=c<=0x7f?1:c<=0x7ff?2:high&&char.IsLowSurrogate(c)?1:3;
            high=char.IsHighSurrogate(c);
            if (bytes > maxBytes) throw new InvalidDataException("IPC message too large");
        }
        throw new EndOfStreamException("IPC connection ended without a complete message");
    }

    private static async Task EnsureAsync(Settings settings, string config)
    {
        if (File.Exists(Path.Combine(settings.DataDirectory,"uninstalled"))) throw new InvalidOperationException("Plugin has been uninstalled");
        try {
            var running=JsonNode.Parse(await RequestAsync(settings,new{operation="status"},TimeSpan.FromSeconds(1)))!;
            if(Json.Text(running,"version")!=typeof(Program).Assembly.GetName().Version!.ToString(3)||Json.Text(running,"adapterInstructionHash")!=ReviewAdapter.Hash||
                Json.Text(running,"reviewerBackend")!="NativeGuardian"||Json.Text(running,"nativeBridgePolicyHash")!=Json.Hash(GuardianFacts.BridgePolicy))
                throw new InvalidDataException("Running approval service differs from the installed package; fully exit Antigravity and restart");
            if (settings.PortableRoot != null && !string.Equals(Json.Text(running, "portableRoot"), settings.PortableRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Running approval service belongs to another portable directory");
            ProtectedPathDelegation.TrySync(settings, hostActive: true, config);
            return;
        }
        catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
        // ShellExecute detaches the Windows host from a calling PowerShell pipeline's
        // inherited handles; otherwise invoking Install.ps1 via -File can wait forever.
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = OperatingSystem.IsWindows(), CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = AppContext.BaseDirectory };
        if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(typeof(Program).Assembly.Location);
        foreach (var arg in new[] { "host", "--config", Path.GetFullPath(config) }) start.ArgumentList.Add(arg);
        Process.Start(start)?.Dispose();
        for (int attempt = 0; attempt < 40; attempt++)
        {
            try { await RequestAsync(settings, new { operation = "status" }, TimeSpan.FromMilliseconds(300)); return; }
            catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { await Task.Delay(100); }
        }
        throw new InvalidOperationException("Approval host did not become ready");
    }

    internal static async Task HostAsync(Settings settings, string? configPath = null)
    {
        Directory.CreateDirectory(settings.DataDirectory);
        FileStream hostLock;
        try { hostLock = new FileStream(Path.Combine(settings.DataDirectory, settings.PipeName + ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return; }
        using (hostLock)
        {
            Directory.CreateDirectory(settings.DataDirectory);
            ProtectedPathDelegation.TrySync(settings, hostActive: true, configPath);
            try
            {
                var policy = new Policy(settings.PolicyDirectory);
                await using var reviewer = new NativeGuardianReviewer(settings, policy);
                var gate = new ReviewGate(settings, policy, reviewer);
                using var stop = new CancellationTokenSource();
                var handlers = new List<Task>();
                await Audit.AppendAsync(settings, new { at = DateTimeOffset.UtcNow, @event = "host_start", capabilities=Capabilities(settings,policy.NativeHash), policyHash = policy.NativeHash }, stop.Token);
                while (!stop.IsCancellationRequested)
                {
                    var pipe = new NamedPipeServerStream(settings.PipeName, PipeDirection.InOut, 16, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    try { await pipe.WaitForConnectionAsync(stop.Token); }
                    catch (OperationCanceledException) { pipe.Dispose(); break; }
                    handlers.RemoveAll(t => t.IsCompleted);
                    handlers.Add(HandleAsync(pipe, settings, gate, stop,policy.NativeHash, configPath));
                }
                await Task.WhenAll(handlers);
            }
            finally
            {
                ProtectedPathDelegation.TryRevoke(settings);
            }
        }
    }

    private static async Task HandleAsync(NamedPipeServerStream pipe, Settings settings, ReviewGate gate, CancellationTokenSource stop,string policyHash, string? configPath = null)
    {
        await using (pipe)
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(settings.HookTimeoutSeconds + 2));
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
            try
            {
                var message = JsonNode.Parse(await ReadLineAsync(reader, settings.MaxInputBytes+16384, deadline.Token));
                if(Json.Text(message,"operation")=="review"&&message?["deadlineUnixMs"] is JsonValue absolute&&absolute.TryGetValue<long>(out var unixMs))
                {
                    var remaining=Math.Clamp(unixMs-DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()-500,1,settings.HookTimeoutSeconds*1000);
                    deadline.CancelAfter(TimeSpan.FromMilliseconds(remaining));
                }
                object result = Json.Text(message, "operation") switch {
                    "status" => Capabilities(settings,policyHash),
                    "stop" => new { status = "stopping" },
                    "set_logging" => SetLoggingLive(settings, message),
                    "set_protected_delegation" => SetProtectedDelegationLive(settings, message, configPath),
                    "stats" => UsageStats.Compute(settings.DataDirectory, ResolvePricingPathFromMessage(Json.Text(message, "pricingPath"))),
                    "review" => await gate.ReviewAsync(message?["payload"] ?? throw new InvalidDataException("Missing payload"), deadline.Token),
                    _ => throw new InvalidDataException("Unknown IPC operation")
                };
                await writer.WriteLineAsync(Json.Encode(result).AsMemory(), deadline.Token);
                if (Json.Text(message, "operation") == "stop") stop.Cancel();
            }
            catch (Exception e) when (e is IOException or InvalidDataException or OperationCanceledException or System.Text.Json.JsonException)
            { /* Connection failure never produces an approval. Hook client returns a blocking failure. */ }
        }
    }

    private static string? Option(string[] args, string name)
    {
        int i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }
    private static LocalDateRange? StatsDateRange(string[] args)
    {
        const string format = "yyyy-MM-dd";
        if (!args.Contains("--from-date") && !args.Contains("--to-date")) return null;
        if (!DateOnly.TryParseExact(Option(args, "--from-date"), format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var start) ||
            !DateOnly.TryParseExact(Option(args, "--to-date"), format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var end))
            throw new InvalidDataException("Supply both --from-date and --to-date in yyyy-MM-dd format.");
        return new LocalDateRange(start, end);
    }
    private static object SetLoggingLive(Settings settings, JsonNode? message)
    {
        if (message?["enabled"] is not JsonValue val || !val.TryGetValue<bool>(out var enabled))
            throw new InvalidDataException("Missing enabled flag");
        settings.EnableDetailedLogs = enabled;
        return new { ok = true, detailedLogs = settings.DetailedLogsActive };
    }
    private static object SetProtectedDelegationLive(Settings settings, JsonNode? message, string? configPath)
    {
        if (message?["enabled"] is not JsonValue val || !val.TryGetValue<bool>(out var enabled))
            throw new InvalidDataException("Missing enabled flag");
        settings.DelegateProtectedPaths = enabled;
        ProtectedPathDelegation.TrySync(settings, hostActive: true, configPath);
        return new { ok = true, delegateProtectedPaths = settings.DelegateProtectedPaths,
            activeProtectedGrants = ProtectedPathDelegation.ReadOwnedGrants(settings.DataDirectory).OrderBy(x => x, StringComparer.Ordinal).ToArray() };
    }
    private static string ResolveDataDir(string[] args, string config)
    {
        var portable = StorageLayout.FromConfig(config);
        if (portable != null) return portable.DataDirectory;
        var explicitDir = Option(args, "--data-dir");
        if (!string.IsNullOrWhiteSpace(explicitDir)) return Path.GetFullPath(explicitDir);
        if (File.Exists(config))
        {
            try
            {
                var dir = Json.Text(JsonNode.Parse(File.ReadAllText(config)), "dataDirectory");
                if (!string.IsNullOrWhiteSpace(dir)) return Path.GetFullPath(dir);
            }
            catch { }
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini", "gravity-guardian-data");
    }
    private static string? ResolvePricingPath(string[] args, string config)
    {
        var explicitPath = Option(args, "--pricing");
        if (!string.IsNullOrWhiteSpace(explicitPath)) return Path.GetFullPath(explicitPath);
        var configDir = Path.GetDirectoryName(Path.GetFullPath(config));
        if (!string.IsNullOrEmpty(configDir))
        {
            var candidate = Path.Combine(configDir, "pricing.json");
            if (File.Exists(candidate)) return candidate;
        }
        var portable = StorageLayout.FromConfig(config);
        if (portable != null) return Path.Combine(portable.ProgramDirectory, "pricing.json");
        return ResolvePricingPathFromMessage(null);
    }
    private static string? ResolvePricingPathFromMessage(string? requested)
    {
        if (!string.IsNullOrWhiteSpace(requested) && File.Exists(requested)) return Path.GetFullPath(requested);
        var baseSibling = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "pricing.json"));
        return File.Exists(baseSibling) ? baseSibling : null;
    }
    private static string? ToolIdentity(JsonNode? payload)=>payload?["toolCall"] is JsonObject call?
        Json.Hash(ReviewAdapter.Canonical(NativeTranscript.NormalizeToolCall(call))):null;
    private static object Capabilities(Settings settings,string policyHash)=>new{status="running",version=typeof(Program).Assembly.GetName().Version!.ToString(3),nativeRouting=settings.EnableNativeRouting,
        storageMode=settings.PortableRoot==null?"installed":"portable",portableRoot=settings.PortableRoot,
        ruleVersion=ReviewRoute.Version,inputVersion=ReviewAdapter.InputVersion,adapterVersion=ReviewAdapter.Version,adapterInstructionHash=ReviewAdapter.Hash,transportVersion=ReviewAdapter.TransportVersion,
        policyHash,
        guardVersion=DenialGuard.Version,guardScope="bound_request",guardStateDirectory=Path.Combine(settings.DataDirectory,"denial-guard"),guardState=DenialGuard.Diagnostics(settings),
        nativeTurnIdAvailable=false,nativeInterruptionAvailable=false,runtimeEffectiveScopeComplete=false,model=settings.Model,effort=settings.Effort,
        reviewerBackend="NativeGuardian",nativeState=settings.EnableNativeState,escalateAuthorizedDenials=settings.EscalateAuthorizedDenials,
        delegateProtectedPaths=settings.DelegateProtectedPaths,
        activeProtectedGrants=ProtectedPathDelegation.ReadOwnedGrants(settings.DataDirectory).OrderBy(x=>x,StringComparer.Ordinal).ToArray(),
        guardianProtocol=GuardianFacts.Protocol,
        nativeBridgePolicyHash=Json.Hash(GuardianFacts.BridgePolicy),
        inferenceDispatchCap=(int?)null,maxAttempts=GuardianFacts.MaxReviewAttempts,
        detailedLogs=settings.DetailedLogsActive,maxLogSegmentBytes=settings.MaxLogSegmentBytes,
        adapter="native-guardian",pid=Environment.ProcessId};
}
