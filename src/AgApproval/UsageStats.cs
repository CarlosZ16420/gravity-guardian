using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AgApproval;

public sealed class WindowSummary
{
    public int TotalRequests { get; set; }
    public int ModelCalls { get; set; }
    public int Approved { get; set; }
    public int Denied { get; set; }
    public int Delegated { get; set; }
    public int Redirected { get; set; }
    public int Failed { get; set; }
    public long InputTokens { get; set; }
    public long CachedInputTokens { get; set; }
    public long OutputTokens { get; set; }
    public long ReasoningOutputTokens { get; set; }
    public long TotalTokens { get; set; }
    public int ReportedUsageCalls { get; set; }
    public int UnknownOrPartialUsageCalls { get; set; }
    public decimal EstimatedCostUsd { get; set; }
}

public sealed class UsageStatsReport
{
    public string DataDirectory { get; init; } = "";
    public string LocalDate { get; init; } = "";
    public long LogsSizeBytes { get; init; }
    public int SegmentFileCount { get; init; }
    public int InvalidLines { get; init; }
    public PricingProfile Pricing { get; init; } = PricingProfile.Default;
    public WindowSummary Today { get; init; } = new();
    public WindowSummary Last7Days { get; init; } = new();
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public WindowSummary? CustomRange { get; init; }
}

public readonly record struct LocalDateRange(DateOnly Start, DateOnly End)
{
    public bool Contains(DateOnly day) => day >= Start && day <= End;
}

public static partial class UsageStats
{
    private const int CacheVersion = 2;
    [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2})\.", RegexOptions.CultureInvariant)]
    private static partial Regex UtcPrefixRegex();

    private sealed record CompletedItem(
        DateTimeOffset At,
        string RequestId,
        string Status,
        string Decision,
        string ReasonCode,
        bool HasAssessment);

    private sealed record UsageItem(
        DateTimeOffset At,
        string RequestId,
        string? Backend,
        int? AttemptCount,
        long? InferenceDispatchCount,
        string? Source,
        string? Status,
        long? InputTokens,
        long? CachedInputTokens,
        long? OutputTokens,
        long? ReasoningOutputTokens,
        long? TotalTokens,
        bool HasModelEvidence);

    private sealed class CachedFileSummary
    {
        public int Version { get; set; }
        public long Length { get; set; }
        public long LastWriteUtcTicks { get; set; }
        public int InvalidLines { get; set; }
        public List<CachedCompleted> Completed { get; set; } = [];
        public List<CachedInvalidated> Invalidated { get; set; } = [];
        public List<CachedUsage> Usage { get; set; } = [];
    }

    private sealed record CachedCompleted(DateTimeOffset At, string RequestId, string Status, string Decision, string ReasonCode, bool HasAssessment);
    private sealed record CachedInvalidated(string RequestId, string? Decision, string? ReasonCode);
    private sealed record CachedUsage(
        DateTimeOffset At,
        string RequestId,
        string? Backend,
        int? AttemptCount,
        long? InferenceDispatchCount,
        string? Source,
        string? Status,
        long? InputTokens,
        long? CachedInputTokens,
        long? OutputTokens,
        long? ReasoningOutputTokens,
        long? TotalTokens,
        bool HasModelEvidence);

    public static UsageStatsReport Compute(string dataDirectory, string? pricingPath = null, DateTimeOffset? nowOverride = null,
        LocalDateRange? customRange = null)
    {
        if (customRange is { } requested && requested.End < requested.Start)
            throw new InvalidDataException("The end date must be on or after the start date.");

        var pricing = PricingProfile.Load(pricingPath);
        var nowLocal = nowOverride ?? DateTimeOffset.Now;
        var todayLocal = DateOnly.FromDateTime(nowLocal.Date);
        var last7Start = todayLocal.AddDays(-6);
        var recentRange = new LocalDateRange(last7Start, todayLocal);
        var customSummary = customRange.HasValue ? new WindowSummary() : null;

        var logsDir = Path.GetFullPath(Path.Combine(dataDirectory, "logs"));
        if (!Directory.Exists(logsDir))
        {
            return new UsageStatsReport
            {
                DataDirectory = dataDirectory,
                LocalDate = todayLocal.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                Pricing = pricing,
                CustomRange = customSummary
            };
        }

        TimeSpan OffsetAtMidnight(DateOnly day) =>
            nowOverride?.Offset ?? TimeZoneInfo.Local.GetUtcOffset(day.ToDateTime(TimeOnly.MinValue));

        // Include adjacent UTC segments for usage and invalidations around a local midnight.
        (int First, int Last) UtcSegmentDays(LocalDateRange range)
        {
            var nextDay = range.End == DateOnly.MaxValue ? range.End : range.End.AddDays(1);
            int first = range.Start.DayNumber - (OffsetAtMidnight(range.Start) > TimeSpan.Zero ? 1 : 0);
            int last = range.End.DayNumber + 1 - (OffsetAtMidnight(nextDay) > TimeSpan.Zero ? 1 : 0);
            return (first - 1, last + 1);
        }

        var recentSegments = UtcSegmentDays(recentRange);
        var customSegments = customRange is { } dates ? UtcSegmentDays(dates) : ((int First, int Last)?)null;
        var activeUtcPrefix = DateTime.UtcNow.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

        var allFiles = Directory.EnumerateFiles(logsDir, "*.jsonl", SearchOption.TopDirectoryOnly)
            .Select(p => new FileInfo(p))
            .OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        long logsSizeBytes = 0;
        foreach (var f in allFiles) logsSizeBytes += f.Length;

        var cachePath = Path.Combine(dataDirectory, "stats-cache.json");
        var cache = LoadCache(cachePath);
        bool cacheDirty = false;

        var completed = new List<CompletedItem>();
        var invalidations = new Dictionary<string, (string? Decision, string? ReasonCode)>(StringComparer.Ordinal);
        var usages = new List<UsageItem>();
        int invalidLines = 0;

        foreach (var file in allFiles)
        {
            var match = UtcPrefixRegex().Match(file.Name);
            if (match.Success && DateOnly.TryParseExact(match.Groups[1].Value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var fileUtcDate))
            {
                int day = fileUtcDate.DayNumber;
                bool inRecent = day >= recentSegments.First && day <= recentSegments.Last;
                bool inCustom = customSegments is { } bounds && day >= bounds.First && day <= bounds.Last;
                if (!inRecent && !inCustom)
                    continue;
            }

            bool canUseCache = !(match.Success && string.Equals(match.Groups[1].Value, activeUtcPrefix, StringComparison.Ordinal));
            CachedFileSummary? summary = null;
            if (canUseCache && cache.TryGetValue(file.Name, out var cached) && cached.Version == CacheVersion &&
                cached.Length == file.Length && cached.LastWriteUtcTicks == file.LastWriteTimeUtc.Ticks)
            {
                summary = cached;
            }

            if (summary == null)
            {
                summary = ParseFile(file);
                if (canUseCache)
                {
                    cache[file.Name] = summary;
                    cacheDirty = true;
                }
            }

            invalidLines += summary.InvalidLines;
            foreach (var c in summary.Completed)
                completed.Add(new CompletedItem(c.At, c.RequestId, c.Status, c.Decision, c.ReasonCode, c.HasAssessment));
            foreach (var inv in summary.Invalidated)
                invalidations[inv.RequestId] = (inv.Decision, inv.ReasonCode);
            foreach (var u in summary.Usage)
                usages.Add(new UsageItem(u.At, u.RequestId, u.Backend, u.AttemptCount, u.InferenceDispatchCount, u.Source, u.Status, u.InputTokens, u.CachedInputTokens, u.OutputTokens, u.ReasoningOutputTokens, u.TotalTokens, u.HasModelEvidence));
        }

        if (cacheDirty)
        {
            var existingNames = new HashSet<string>(allFiles.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            foreach (var key in cache.Keys.Where(k => !existingNames.Contains(k)).ToArray())
                cache.Remove(key);
            TrySaveCache(cachePath, cache);
        }

        var modelEvidenceIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var u in usages)
        {
            if (!string.IsNullOrEmpty(u.RequestId) && u.HasModelEvidence)
                modelEvidenceIds.Add(u.RequestId);
        }
        foreach (var c in completed)
        {
            if (!string.IsNullOrEmpty(c.RequestId) && c.HasAssessment)
                modelEvidenceIds.Add(c.RequestId);
        }

        var todaySummary = new WindowSummary();
        var last7Summary = new WindowSummary();

        DateOnly ToLocalDate(DateTimeOffset at) =>
            DateOnly.FromDateTime(nowOverride.HasValue
                ? at.ToOffset(nowOverride.Value.Offset).Date
                : TimeZoneInfo.ConvertTime(at, TimeZoneInfo.Local).Date);

        foreach (var item in completed)
        {
            var localDate = ToLocalDate(item.At);
            bool inRecent = recentRange.Contains(localDate);
            bool inCustom = customRange?.Contains(localDate) == true;
            if (!inRecent && !inCustom) continue;

            var status = item.Status;
            var decision = item.Decision;
            var reasonCode = item.ReasonCode;
            if (!string.IsNullOrEmpty(item.RequestId) && invalidations.TryGetValue(item.RequestId, out var inv))
            {
                status = "review_failed";
                decision = inv.Decision ?? decision;
                reasonCode = inv.ReasonCode ?? reasonCode;
            }

            bool hasModel = !string.IsNullOrEmpty(item.RequestId) && modelEvidenceIds.Contains(item.RequestId);

            void Apply(WindowSummary w)
            {
                w.TotalRequests++;
                if (hasModel) w.ModelCalls++;
                if (status == "approved") w.Approved++;
                else if (status == "redirected") w.Redirected++;
                else if (status == "denied" || status == "escalated" || (status == "blocked" && decision == "deny")) w.Denied++;
                else if (status == "delegated") w.Delegated++;
                else w.Failed++;
            }

            if (inRecent) Apply(last7Summary);
            if (localDate == todayLocal) Apply(todaySummary);
            if (inCustom) Apply(customSummary!);
        }

        foreach (var u in usages)
        {
            var localDate = ToLocalDate(u.At);
            bool inRecent = recentRange.Contains(localDate);
            bool inCustom = customRange?.Contains(localDate) == true;
            if (!inRecent && !inCustom) continue;

            bool legacyLastAttemptOnly = u.Backend == "native_guardian" &&
                                         u.Source == "native_guardian.last_attempt_delta" &&
                                         u.AttemptCount != 1;
            if (legacyLastAttemptOnly || (u.Backend == "native_guardian" && u.InferenceDispatchCount == 0 && !u.HasModelEvidence))
                continue;

            void ApplyUsage(WindowSummary w)
            {
                if (u.InputTokens.HasValue && u.OutputTokens.HasValue)
                {
                    long input = Math.Max(0, u.InputTokens.Value);
                    long output = Math.Max(0, u.OutputTokens.Value);
                    long total = u.TotalTokens ?? checked(input + output);
                    w.InputTokens += input;
                    w.OutputTokens += output;
                    w.TotalTokens += total;
                    if (u.CachedInputTokens.HasValue)
                        w.CachedInputTokens += Math.Clamp(u.CachedInputTokens.Value, 0, input);
                    if (u.ReasoningOutputTokens.HasValue)
                        w.ReasoningOutputTokens += Math.Clamp(u.ReasoningOutputTokens.Value, 0, output);
                    w.EstimatedCostUsd += pricing.EstimateUsd(input, u.CachedInputTokens, output);
                    if (u.Status == "reported") w.ReportedUsageCalls++;
                    else w.UnknownOrPartialUsageCalls++;
                }
                else
                {
                    w.UnknownOrPartialUsageCalls++;
                }
            }

            if (inRecent) ApplyUsage(last7Summary);
            if (localDate == todayLocal) ApplyUsage(todaySummary);
            if (inCustom) ApplyUsage(customSummary!);
        }

        todaySummary.EstimatedCostUsd = Math.Round(todaySummary.EstimatedCostUsd, 6, MidpointRounding.AwayFromZero);
        last7Summary.EstimatedCostUsd = Math.Round(last7Summary.EstimatedCostUsd, 6, MidpointRounding.AwayFromZero);
        if (customSummary is not null)
            customSummary.EstimatedCostUsd = Math.Round(customSummary.EstimatedCostUsd, 6, MidpointRounding.AwayFromZero);

        return new UsageStatsReport
        {
            DataDirectory = dataDirectory,
            LocalDate = todayLocal.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            LogsSizeBytes = logsSizeBytes,
            SegmentFileCount = allFiles.Length,
            InvalidLines = invalidLines,
            Pricing = pricing,
            Today = todaySummary,
            Last7Days = last7Summary,
            CustomRange = customSummary
        };
    }

    private static CachedFileSummary ParseFile(FileInfo file)
    {
        var summary = new CachedFileSummary
        {
            Version = CacheVersion,
            Length = file.Length,
            LastWriteUtcTicks = file.LastWriteTimeUtc.Ticks
        };
        using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                var node = JsonNode.Parse(line);
                if (node is not JsonObject obj) { summary.InvalidLines++; continue; }
                var evt = Json.Text(obj, "event");
                if (evt == "review_invalidated")
                {
                    var reqId = Json.Text(obj, "requestId");
                    if (!string.IsNullOrEmpty(reqId))
                        summary.Invalidated.Add(new CachedInvalidated(reqId, Json.Text(obj, "decision"), Json.Text(obj, "reasonCode")));
                    continue;
                }
                if (evt is not ("review_completed" or "review_usage")) continue;
                var atText = Json.Text(obj, "at");
                if (string.IsNullOrWhiteSpace(atText) || !DateTimeOffset.TryParse(atText, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var at))
                    continue;

                if (evt == "review_completed")
                {
                    summary.Completed.Add(new CachedCompleted(
                        at,
                        Json.Text(obj, "requestId") ?? "",
                        Json.Text(obj, "status") ?? "",
                        Json.Text(obj, "decision") ?? "",
                        Json.Text(obj, "reasonCode") ?? "",
                        !string.IsNullOrWhiteSpace(Json.Text(obj, "assessmentText"))));
                }
                else if (evt == "review_usage")
                {
                    var usage = obj["usage"] as JsonObject;
                    long? input = TryLong(usage?["inputTokens"]);
                    long? cached = TryLong(usage?["cachedInputTokens"]);
                    long? output = TryLong(usage?["outputTokens"]);
                    long? reasoning = TryLong(usage?["reasoningOutputTokens"]);
                    long? total = TryLong(usage?["totalTokens"]);
                    long? dispatchCount = TryLong(obj["inferenceDispatchCount"]) ?? TryLong(obj["inferenceRequests"]);
                    int? attemptCount = obj["attemptCount"] is JsonValue av && av.TryGetValue<int>(out var ac) ? ac : null;
                    int? observedEvents = usage?["observedEvents"] is JsonValue ov && ov.TryGetValue<int>(out var oe) ? oe : null;
                    int? reportedTurns = usage?["reportedTurns"] is JsonValue rtv && rtv.TryGetValue<int>(out var rt) ? rt : null;
                    bool hasEvidence = (obj["modelCallEvidence"] is JsonValue mcv && mcv.TryGetValue<bool>(out var mce) && mce)
                        || dispatchCount > 0 || observedEvents > 0 || reportedTurns > 0 || input.HasValue || output.HasValue || total.HasValue;

                    summary.Usage.Add(new CachedUsage(
                        at,
                        Json.Text(obj, "requestId") ?? "",
                        Json.Text(obj, "backend"),
                        attemptCount,
                        dispatchCount,
                        Json.Text(usage, "source"),
                        Json.Text(usage, "status"),
                        input, cached, output, reasoning, total,
                        hasEvidence));
                }
            }
            catch (JsonException)
            {
                summary.InvalidLines++;
            }
            catch (InvalidOperationException)
            {
                summary.InvalidLines++;
            }
        }
        return summary;
    }

    private static long? TryLong(JsonNode? node) =>
        node is JsonValue v && v.TryGetValue<long>(out var value) && value >= 0 ? value : null;

    private static Dictionary<string, CachedFileSummary> LoadCache(string path)
    {
        if (!File.Exists(path)) return new Dictionary<string, CachedFileSummary>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var loaded = JsonSerializer.Deserialize<Dictionary<string, CachedFileSummary>>(File.ReadAllText(path), Json.Options);
            return loaded != null
                ? new Dictionary<string, CachedFileSummary>(loaded, StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, CachedFileSummary>(StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return new Dictionary<string, CachedFileSummary>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private static void TrySaveCache(string path, Dictionary<string, CachedFileSummary> cache)
    {
        var tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(tmp, JsonSerializer.Serialize(cache, Json.Options), new UTF8Encoding(false));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        finally
        {
            try { File.Delete(tmp); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}

public static class LogCompactor
{
    public sealed record CompactionResult(string LogDirectory, int SegmentFiles, long BeforeBytes, long AfterBytes, long SavedBytes, int KeptEvents, int DroppedVerboseDumps, int SkippedActiveOrLockedFiles = 0);

    public static CompactionResult Compact(string dataDirectory)
    {
        var logsDir = Path.GetFullPath(Path.Combine(dataDirectory, "logs"));
        if (!Directory.Exists(logsDir))
            return new(logsDir, 0, 0, 0, 0, 0, 0, 0);

        using var lockStream = AcquireCompactionLock(logsDir);
        CleanupStaleStages(logsDir);

        var files = Directory.GetFiles(logsDir, "*.jsonl", SearchOption.TopDirectoryOnly)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        long beforeBytes = files.Sum(f => new FileInfo(f).Length);
        if (files.Length == 0)
            return new(logsDir, 0, 0, 0, 0, 0, 0, 0);

        var todayUtc = DateTime.UtcNow.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var groups = new Dictionary<string, (bool IsDated, List<string> Files)>(StringComparer.OrdinalIgnoreCase);
        int skipped = 0;

        foreach (var file in files)
        {
            var name = Path.GetFileName(file);
            var dot = name.IndexOf('.');
            var prefix = dot > 0 ? name[..dot] : "";
            bool isDated = Regex.IsMatch(prefix, @"^\d{4}-\d{2}-\d{2}$");
            if (isDated && string.Equals(prefix, todayUtc, StringComparison.Ordinal))
            {
                skipped++;
                continue;
            }
            var key = isDated ? prefix : "legacy";
            if (!groups.TryGetValue(key, out var group))
            {
                group = (isDated, new List<string>());
                groups[key] = group;
            }
            group.Files.Add(file);
        }

        var tempDir = Path.Combine(logsDir, "compact-stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        int kept = 0, dropped = 0;

        try
        {
            foreach (var (key, group) in groups)
            {
                var opened = new List<(string Path, FileStream Stream)>(group.Files.Count);
                try
                {
                    bool locked = false;
                    foreach (var file in group.Files)
                    {
                        try
                        {
                            opened.Add((file, new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None)));
                        }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                        {
                            locked = true;
                            break;
                        }
                    }
                    if (locked)
                    {
                        skipped += group.Files.Count;
                        continue;
                    }

                    string targetName = ChooseCompactedName(logsDir, key, group.IsDated, group.Files);
                    string outPath = Path.Combine(tempDir, targetName);
                    int groupKept = 0, groupDropped = 0;
                    using (var writer = new StreamWriter(new FileStream(outPath, FileMode.CreateNew, FileAccess.Write, FileShare.None), new UTF8Encoding(false)))
                    {
                        foreach (var (_, fs) in opened)
                        {
                            fs.Position = 0;
                            using var reader = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
                            string? line;
                            while ((line = reader.ReadLine()) != null)
                            {
                                if (string.IsNullOrWhiteSpace(line)) continue;
                                if (line.Contains("\"event\":\"review_context\"", StringComparison.Ordinal) ||
                                    line.Contains("\"event\":\"guardian_input\"", StringComparison.Ordinal) ||
                                    line.Contains("\"event\":\"review_transport\"", StringComparison.Ordinal))
                                {
                                    groupDropped++;
                                    continue;
                                }
                                if (line.Length > 8192 && (line.Contains("\"event\":\"tool_completed\"", StringComparison.Ordinal) ||
                                                           line.Contains("\"event\":\"review_received\"", StringComparison.Ordinal)))
                                {
                                    try
                                    {
                                        var obj = JsonNode.Parse(line)?.AsObject();
                                        if (obj != null)
                                        {
                                            obj.Remove("payload");
                                            writer.WriteLine(obj.ToJsonString(Json.Options));
                                            groupKept++;
                                            continue;
                                        }
                                    }
                                    catch (Exception e) when (e is JsonException or InvalidOperationException)
                                    {
                                        groupDropped++;
                                        continue;
                                    }
                                }
                                writer.WriteLine(line);
                                groupKept++;
                            }
                        }
                        writer.Flush();
                    }

                    foreach (var (_, fs) in opened) fs.Dispose();
                    opened.Clear();

                    var oldBackupDir = Path.Combine(tempDir, "old-" + key);
                    Directory.CreateDirectory(oldBackupDir);
                    var movedOriginals = new List<(string Original, string Backup)>(group.Files.Count);
                    var targetDest = Path.Combine(logsDir, targetName);
                    try
                    {
                        foreach (var file in group.Files)
                        {
                            var backup = Path.Combine(oldBackupDir, Path.GetFileName(file));
                            File.Move(file, backup);
                            movedOriginals.Add((file, backup));
                        }
                        File.Move(outPath, targetDest, overwrite: true);
                    }
                    catch
                    {
                        foreach (var (orig, backup) in movedOriginals)
                        {
                            try
                            {
                                if (File.Exists(backup) && !File.Exists(orig))
                                    File.Move(backup, orig);
                            }
                            catch (IOException) { }
                            catch (UnauthorizedAccessException) { }
                        }
                        throw;
                    }

                    kept += groupKept;
                    dropped += groupDropped;
                }
                finally
                {
                    foreach (var (_, fs) in opened)
                    {
                        try { fs.Dispose(); } catch { }
                    }
                }
            }
        }
        finally
        {
            try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        long afterBytes = Directory.GetFiles(logsDir, "*.jsonl", SearchOption.TopDirectoryOnly).Sum(f => new FileInfo(f).Length);
        return new(logsDir, files.Length, beforeBytes, afterBytes, Math.Max(0, beforeBytes - afterBytes), kept, dropped, skipped);
    }

    private static FileStream AcquireCompactionLock(string logsDir)
    {
        var lockPath = Path.Combine(logsDir, ".compact.lock");
        for (int attempt = 0; attempt < 40; attempt++)
        {
            try
            {
                return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException) when (attempt < 39)
            {
                Thread.Sleep(25);
            }
            catch (UnauthorizedAccessException) when (attempt < 39)
            {
                Thread.Sleep(25);
            }
        }
        throw new IOException("Another log compaction is currently in progress.");
    }

    private static void CleanupStaleStages(string logsDir)
    {
        foreach (var dir in Directory.GetDirectories(logsDir, "compact-stage-*", SearchOption.TopDirectoryOnly))
        {
            try
            {
                var info = new DirectoryInfo(dir);
                if (DateTime.UtcNow - info.CreationTimeUtc > TimeSpan.FromMinutes(10))
                    Directory.Delete(dir, recursive: true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static string ChooseCompactedName(string logsDir, string key, bool isDated, List<string> groupFiles)
    {
        if (isDated) return key + ".000.jsonl";
        var sourceNames = new HashSet<string>(groupFiles.Select(f => Path.GetFileName(f)!), StringComparer.OrdinalIgnoreCase);
        for (int idx = 0; idx < 1000; idx++)
        {
            var candidate = $"{key}.{idx:D3}.jsonl";
            if (sourceNames.Contains(candidate) || !File.Exists(Path.Combine(logsDir, candidate)))
                return candidate;
        }
        return $"{key}.{Guid.NewGuid():N}.jsonl";
    }
}
