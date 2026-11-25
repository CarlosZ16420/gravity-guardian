using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgApproval;

public sealed record ProtectedPathEntry(string Id, string Segment, string Grant, string[] DelegatedTools);

public sealed record ProtectedPathCatalog(string SchemaVersion, string? MinHostVersion, string? MaxHostVersion, ProtectedPathEntry[] Entries)
{
    public static readonly ProtectedPathCatalog Builtin = new(
        "1.0",
        "2.29.0",
        null,
        [
            new("workspace-git-read", ".git", "read_file(.git)", ["read_file"]),
            new("workspace-cache-read", ".cache", "read_file(.cache)", ["read_file"]),
            new("workspace-cache-write", ".cache", "write_file(.cache)", ["write_file", "edit_file"]),
            new("workspace-vscode-read", ".vscode", "read_file(.vscode)", ["read_file"])
        ]);
}

public static class ProtectedPathDelegation
{
    public const string LedgerFileName = "delegated-grants.json";
    public const string LockFileName = "delegated-grants.lock";

    private static readonly HashSet<string> AllowedCatalogGrants = new(StringComparer.Ordinal)
    {
        "read_file(.git)",
        "read_file(.cache)",
        "write_file(.cache)",
        "read_file(.vscode)"
    };

    public static ProtectedPathCatalog LoadCatalog(string? approvalConfigPath = null)
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(approvalConfigPath) && Path.IsPathFullyQualified(approvalConfigPath))
        {
            var dir = Path.GetDirectoryName(Path.GetFullPath(approvalConfigPath));
            if (!string.IsNullOrEmpty(dir))
                candidates.Add(Path.Combine(dir, "host-protected-paths.json"));
        }
        var baseSibling = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "host-protected-paths.json"));
        candidates.Add(baseSibling);

        foreach (var path in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(path)) continue;
            try
            {
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) continue;
                var node = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
                if (node?["entries"] is not JsonArray arr) continue;
                var entries = new List<ProtectedPathEntry>();
                foreach (var item in arr.OfType<JsonObject>())
                {
                    var id = Json.Text(item, "id");
                    var segment = Json.Text(item, "segment");
                    var grant = Json.Text(item, "grant");
                    if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(segment) ||
                        string.IsNullOrWhiteSpace(grant) || !AllowedCatalogGrants.Contains(grant))
                        continue;
                    var tools = item["delegatedTools"] is JsonArray toolArr
                        ? toolArr.Select(t => t?.GetValue<string>()).OfType<string>().ToArray()
                        : [];
                    if (tools.Length > 0)
                        entries.Add(new ProtectedPathEntry(id, segment, grant, tools));
                }
                if (entries.Count > 0)
                {
                    return new ProtectedPathCatalog(
                        Json.Text(node, "schemaVersion") ?? "1.0",
                        Json.Text(node, "minHostVersion"),
                        Json.Text(node, "maxHostVersion"),
                        entries.ToArray());
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return ProtectedPathCatalog.Builtin;
    }

    public static HashSet<string> ReadOwnedGrants(string dataDirectory)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(dataDirectory) || !Path.IsPathFullyQualified(dataDirectory))
            return result;
        var ledgerPath = Path.Combine(dataDirectory, LedgerFileName);
        if (!File.Exists(ledgerPath)) return result;
        try
        {
            if ((File.GetAttributes(ledgerPath) & FileAttributes.ReparsePoint) != 0) return result;
            using var fs = new FileStream(ledgerPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var doc = JsonNode.Parse(fs) as JsonObject;
            if (doc?["ownedGrants"] is JsonArray grants)
            {
                foreach (var g in grants)
                {
                    if (g is JsonValue v && v.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text))
                        result.Add(text);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return result;
    }

    public static bool HasOwnedGrants(string dataDirectory) => ReadOwnedGrants(dataDirectory).Count > 0;

    public static void TrySync(Settings? settings, bool hostActive, string? approvalConfigPath = null, string? hostVersionOverride = null)
    {
        if (settings == null) return;
        try { Sync(settings, hostActive, approvalConfigPath, hostVersionOverride); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or JsonException) { }
    }

    public static void TryRevoke(Settings? settings)
    {
        if (settings == null) return;
        TrySync(settings, hostActive: false);
    }

    public static string[] Sync(Settings settings, bool hostActive, string? approvalConfigPath = null, string? hostVersionOverride = null)
    {
        if (string.IsNullOrWhiteSpace(settings.DataDirectory) || !Path.IsPathFullyQualified(settings.DataDirectory) ||
            string.IsNullOrWhiteSpace(settings.AntigravityConfigDirectory) || !Path.IsPathFullyQualified(settings.AntigravityConfigDirectory))
            return [];

        var configPath = Path.Combine(settings.AntigravityConfigDirectory, "config.json");
        if (!File.Exists(configPath)) return [];

        Directory.CreateDirectory(settings.DataDirectory);
        using var syncLock = AcquireLock(settings.DataDirectory);

        EnsureNotReparsePoint(configPath);
        var ledgerPath = Path.Combine(settings.DataDirectory, LedgerFileName);
        if (File.Exists(ledgerPath)) EnsureNotReparsePoint(ledgerPath);

        var catalog = LoadCatalog(approvalConfigPath);
        bool uninstalled = File.Exists(Path.Combine(settings.DataDirectory, "uninstalled"));
        bool shouldEnable = hostActive &&
                            !uninstalled &&
                            settings.DelegateProtectedPaths &&
                            settings.IsTakeoverEnabled() &&
                            IsHostVersionEligible(catalog, hostVersionOverride);

        var owned = ReadOwnedGrants(settings.DataDirectory);
        if (!shouldEnable && owned.Count == 0)
        {
            if (File.Exists(ledgerPath)) File.Delete(ledgerPath);
            return [];
        }

        var originalBytes = File.ReadAllBytes(configPath);
        var originalHash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(originalBytes));
        var root = JsonNode.Parse(originalBytes) as JsonObject ?? throw new InvalidDataException("Invalid Antigravity config.json");
        var userSettings = root["userSettings"] as JsonObject ?? throw new InvalidDataException("Missing userSettings in Antigravity config.json");
        var globalGrants = userSettings["globalPermissionGrants"] as JsonObject;
        if (globalGrants == null)
        {
            if (!shouldEnable)
            {
                if (File.Exists(ledgerPath)) File.Delete(ledgerPath);
                return [];
            }
            globalGrants = new JsonObject();
            userSettings["globalPermissionGrants"] = globalGrants;
        }

        var allowList = new List<string>();
        if (globalGrants["allow"] is JsonArray existingAllow)
        {
            foreach (var item in existingAllow)
            {
                if (item is JsonValue v && v.TryGetValue<string>(out var s))
                    allowList.Add(s);
            }
        }

        bool configChanged = false;
        if (shouldEnable)
        {
            var desiredGrants = catalog.Entries.Select(e => e.Grant).Distinct(StringComparer.Ordinal).ToArray();
            var desiredSet = new HashSet<string>(desiredGrants, StringComparer.Ordinal);

            // Drop any previously plugin-owned grant that is no longer in the catalog.
            foreach (var stale in owned.Where(g => !desiredSet.Contains(g)).ToArray())
            {
                if (allowList.RemoveAll(a => string.Equals(a, stale, StringComparison.Ordinal)) > 0)
                    configChanged = true;
                owned.Remove(stale);
            }

            foreach (var grant in desiredGrants)
            {
                bool alreadyPresent = allowList.Contains(grant, StringComparer.Ordinal);
                if (!alreadyPresent)
                {
                    owned.Add(grant);
                    allowList.Add(grant);
                    configChanged = true;
                }
                // If alreadyPresent and not in owned, it belongs to the user; never claim ownership.
            }

            // Write-ahead ledger before touching config.json so crash recovery always knows what we added.
            WriteLedgerAtomic(ledgerPath, owned);
            if (configChanged)
            {
                globalGrants["allow"] = new JsonArray(allowList.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
                WriteConfigAtomic(configPath, root, originalHash);
            }
            return owned.OrderBy(s => s, StringComparer.Ordinal).ToArray();
        }
        else
        {
            foreach (var grant in owned)
            {
                if (allowList.RemoveAll(a => string.Equals(a, grant, StringComparison.Ordinal)) > 0)
                    configChanged = true;
            }
            if (configChanged)
            {
                globalGrants["allow"] = new JsonArray(allowList.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
                WriteConfigAtomic(configPath, root, originalHash);
            }
            if (File.Exists(ledgerPath)) File.Delete(ledgerPath);
            return [];
        }
    }

    public static GateResponse? EvaluateFallbackRedirect(ReviewInput input, Settings settings)
    {
        if (input.Tool != "read_file") return null;
        var owned = ReadOwnedGrants(settings.DataDirectory);
        // When read_file(.git) is actively delegated, let Native Guardian review and auto-approve in place.
        if (settings.DelegateProtectedPaths && owned.Contains("read_file(.git)")) return null;

        var doc = JsonNode.Parse(input.Prompt);
        var planned = doc?["planned_action"];
        var args = planned?["toolCall"]?["args"] as JsonObject;
        var workspaces = planned?["workspacePaths"] as JsonArray;
        if (args == null || workspaces == null) return null;

        var target = FindArgText(args, "Path", "AbsolutePath");
        if (string.IsNullOrWhiteSpace(target) || !Path.IsPathFullyQualified(target)) return null;

        string fullTarget;
        try { fullTarget = Path.GetFullPath(target); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }

        string? matchedWorkspace = null;
        string? gitSubpath = null;
        foreach (var wsNode in workspaces)
        {
            if (wsNode is not JsonValue wv || !wv.TryGetValue<string>(out var wsRaw) || !Path.IsPathFullyQualified(wsRaw))
                continue;
            var wsFull = Path.TrimEndingDirectorySeparator(Path.GetFullPath(wsRaw));
            var gitRoot = wsFull + Path.DirectorySeparatorChar + ".git";
            if (string.Equals(fullTarget, gitRoot, StringComparison.OrdinalIgnoreCase))
            {
                matchedWorkspace = wsFull;
                gitSubpath = "";
                break;
            }
            if (fullTarget.StartsWith(gitRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                matchedWorkspace = wsFull;
                gitSubpath = fullTarget[(gitRoot.Length + 1)..].Replace('\\', '/');
                break;
            }
        }
        if (matchedWorkspace == null || gitSubpath == null) return null;

        // Respect explicit user instructions that directly name .git or the exact file.
        if (UserExplicitlyNamedGitPath(input.SourceUserRecords, gitSubpath))
            return null;

        var commandHint = SuggestGitReadCommand(matchedWorkspace, gitSubpath);
        if (commandHint == null) return null;

        return GateResponse.HostProtectedRedirect(
            input.Id,
            input.Hash,
            $"Host protected-path redirect (not a policy denial): Antigravity enforces a built-in manual prompt on direct read_file access to workspace .git metadata when protected-path delegation is inactive. Do not ask the user for file approval; run a read-only Git command instead, for example: {commandHint}");
    }

    private static string? FindArgText(JsonObject args, params string[] keys)
    {
        foreach (var key in keys)
        {
            foreach (var pair in args)
            {
                if (string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase) &&
                    pair.Value is JsonValue v && v.TryGetValue<string>(out var text))
                    return text;
            }
        }
        return null;
    }

    private static bool UserExplicitlyNamedGitPath(JsonArray? userRecords, string gitSubpath)
    {
        if (userRecords == null) return false;
        foreach (var item in userRecords.OfType<JsonObject>())
        {
            var text = Json.Text(item, "content");
            if (string.IsNullOrWhiteSpace(text)) continue;
            if (text.Contains(".git/", StringComparison.OrdinalIgnoreCase) ||
                text.Contains(".git\\", StringComparison.OrdinalIgnoreCase) ||
                (!string.IsNullOrEmpty(gitSubpath) && text.Contains(".git/" + gitSubpath, StringComparison.OrdinalIgnoreCase)))
                return true;
        }
        return false;
    }

    private static string? SuggestGitReadCommand(string workspace, string gitSubpath)
    {
        var wsDisplay = workspace.Replace('\\', '/');
        if (string.Equals(gitSubpath, "config", StringComparison.OrdinalIgnoreCase))
            return $"git -C \"{wsDisplay}\" config --local --list";
        if (string.Equals(gitSubpath, "HEAD", StringComparison.OrdinalIgnoreCase))
            return $"git -C \"{wsDisplay}\" status --short --branch";
        if (string.Equals(gitSubpath, "packed-refs", StringComparison.OrdinalIgnoreCase) ||
            gitSubpath.StartsWith("refs/", StringComparison.OrdinalIgnoreCase))
            return $"git -C \"{wsDisplay}\" show-ref";
        if (gitSubpath.StartsWith("logs/", StringComparison.OrdinalIgnoreCase))
            return $"git -C \"{wsDisplay}\" reflog -n 20";
        return null;
    }

    internal static bool IsHostVersionEligible(ProtectedPathCatalog catalog, string? hostVersionOverride = null)
    {
        var version = hostVersionOverride;
        if (string.IsNullOrWhiteSpace(version))
        {
            var detected = EnvironmentDiscovery.DetectAntigravity();
            if (!detected.Found || string.IsNullOrWhiteSpace(detected.Version))
                return true;
            version = detected.Version;
        }
        var current = ParseVersion3(version);
        if (current == null) return true;
        if (!string.IsNullOrWhiteSpace(catalog.MinHostVersion) && ParseVersion3(catalog.MinHostVersion) is { } min && current < min)
            return false;
        if (!string.IsNullOrWhiteSpace(catalog.MaxHostVersion) && ParseVersion3(catalog.MaxHostVersion) is { } max && current > max)
            return false;
        return true;
    }

    private static Version? ParseVersion3(string raw)
    {
        var clean = raw.Trim().TrimStart('v', 'V');
        int dash = clean.IndexOfAny(['-', '+', ' ']);
        if (dash > 0) clean = clean[..dash];
        var parts = clean.Split('.');
        if (parts.Length < 2) return null;
        if (!int.TryParse(parts[0], out int major) || !int.TryParse(parts[1], out int minor)) return null;
        int patch = parts.Length >= 3 && int.TryParse(parts[2], out int p) ? p : 0;
        return new Version(major, minor, patch);
    }

    private static void EnsureNotReparsePoint(string path)
    {
        for (string? p = Path.GetFullPath(path); p != null; p = Path.GetDirectoryName(p))
        {
            if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Protected-path configuration contains a reparse point: " + p);
        }
    }

    private static void WriteLedgerAtomic(string ledgerPath, IEnumerable<string> owned)
    {
        var payload = new JsonObject
        {
            ["schemaVersion"] = "1.0",
            ["updatedAt"] = DateTimeOffset.UtcNow.ToString("O"),
            ["ownedGrants"] = new JsonArray(owned.OrderBy(s => s, StringComparer.Ordinal).Select(s => (JsonNode?)JsonValue.Create(s)).ToArray())
        };
        var tmp = ledgerPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(tmp, payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(tmp, ledgerPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(tmp)) try { File.Delete(tmp); } catch { }
        }
    }

    private static void WriteConfigAtomic(string configPath, JsonObject root, string expectedSha256)
    {
        var tmp = configPath + ".codex-delegation.tmp";
        EnsureNotReparsePoint(Path.GetDirectoryName(configPath)!);
        try
        {
            File.WriteAllText(tmp, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            var currentHash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(configPath)));
            if (!string.Equals(currentHash, expectedSha256, StringComparison.Ordinal))
                throw new IOException("Antigravity config.json changed concurrently during delegation update");
            File.Move(tmp, configPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(tmp)) try { File.Delete(tmp); } catch { }
        }
    }

    private static FileStream AcquireLock(string dataDirectory)
    {
        var lockPath = Path.Combine(dataDirectory, LockFileName);
        for (int attempt = 0; attempt < 80; attempt++)
        {
            try
            {
                return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException) when (attempt < 79)
            {
                Thread.Sleep(25);
            }
        }
        throw new IOException("Timed out acquiring delegated-grants lock");
    }
}
