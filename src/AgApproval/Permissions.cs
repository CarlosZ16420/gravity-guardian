using System.Text.Json.Nodes;

namespace AgApproval;

public static class PermissionSnapshot
{
    private static readonly string[] SettingKeys = ["permissionPreset", "enableTerminalSandbox", "autoExecutionPolicy", "nonWorkspaceFileAccessPolicy"];
    public static JsonObject Read(Settings settings, JsonArray workspaces)
    {
        var config = Path.Combine(settings.AntigravityConfigDirectory, "config.json");
        var raw = ReadConfig(config);
        var user = raw["userSettings"] as JsonObject ?? throw new InvalidDataException("Unrecognized Antigravity settings schema");
        var global = SelectSettings(user);
        global["permissionGrants"] = Grants(user["globalPermissionGrants"]);
        var sources = new JsonArray(new JsonObject { ["kind"] = "global_config", ["path"] = config, ["sha256"] = Json.Hash(raw.ToJsonString()) });
        var matches = new JsonArray();
        var projects = Path.Combine(settings.AntigravityConfigDirectory, "projects");
        if (Directory.Exists(projects))
        {
            foreach (var file in Directory.EnumerateFiles(projects, "*.json").OrderBy(p=>p,StringComparer.Ordinal))
            {
                JsonObject project;
                try { project=ReadConfig(file); }
                catch(Exception e) when(e is IOException or System.Text.Json.JsonException or InvalidDataException)
                {
                    // An unreadable registry entry is not evidence of a match. Retain it in audit provenance.
                    sources.Add(new JsonObject{["kind"]="unresolved_project_config",["path"]=file});
                    continue;
                }
                if(project["projectResources"] is not JsonObject resourceContainer||resourceContainer["resources"] is not JsonArray resources)continue;
                var folders = resources.OfType<JsonObject>().Select(r => FolderUri(r["folderUri"]) ??
                    (r["gitFolder"] is JsonObject git?FolderUri(git["folderUri"]):null)).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToArray();
                if (!workspaces.Any(w => folders.Any(f => SamePath(f, w!.GetValue<string>())))) continue;
                if(project["settings"] is { } configSettings&&configSettings is not JsonObject)throw new InvalidDataException("Unrecognized matching project settings");
                var selected = SelectSettings(project["settings"] as JsonObject ?? new JsonObject());
                selected["permissionGrants"] = Grants(project["permissionGrants"]?["permissionGrants"]);
                matches.Add(new JsonObject { ["id"] = Json.Text(project,"id"), ["workspaceFolders"] = new JsonArray(folders.Select(f=>(JsonNode?)JsonValue.Create(f)).ToArray()), ["settings"] = selected });
                sources.Add(new JsonObject { ["kind"] = "project_config", ["path"] = file, ["sha256"] = Json.Hash(project.ToJsonString()) });
            }
        }
        var preset = Json.Text(global,"permissionPreset");
        if (matches.Count == 1)
        {
            var projectPreset = Json.Text(matches[0]?["settings"],"permissionPreset");
            if (!string.IsNullOrEmpty(projectPreset) && !projectPreset.Contains("INHERIT",StringComparison.Ordinal)) preset=projectPreset;
        }
        return new JsonObject {
            ["snapshot_version"] = "1.0", ["sources"] = sources, ["global_settings"] = global,
            ["matching_projects"] = matches, ["configured_permission_preset"] = preset,
            ["mounted_workspace_paths"] = workspaces.DeepClone(),
            ["coverage"] = "persisted_configuration_and_hook_request",
            ["runtime_effective_scope_complete"] = false,
            ["unknowns"] = new JsonArray("in-memory per-turn grants and caches", "actual operating-system sandbox availability", "final native permission-engine outcome", "scope changes internal to a tool after this hook"),
            ["precedence"] = "Antigravity explicit Deny > Ask > Allow; project preset may override global. These are observed settings, not proof of runtime access. Only the native engine grants access. Read the exact requested scope in the proposed tool call arguments."
        };
    }

    private static JsonObject ReadConfig(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Permission settings path is a reparse point");
        if (new FileInfo(path).Length > 1024*1024) throw new InvalidDataException("Permission settings exceed supported size");
        using var f = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        return JsonNode.Parse(f) as JsonObject ?? throw new InvalidDataException("Invalid Antigravity permissions file");
    }
    private static JsonObject SelectSettings(JsonObject source)
    {
        var result = new JsonObject();
        foreach(var key in SettingKeys) if(source[key] != null) result[key]=source[key]!.DeepClone();
        return result;
    }
    private static JsonObject Grants(JsonNode? source)
    {
        var result = new JsonObject();
        foreach(var key in new[]{"allow","ask","deny"})
        {
            if(source?[key] is JsonArray array)
            {
                if(array.Any(v=>v is not JsonValue || !v.AsValue().TryGetValue<string>(out _))) throw new InvalidDataException("Unrecognized permission rule schema");
                result[key]=new JsonArray(array.Select(v=>v!.GetValue<string>()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).Select(v=>(JsonNode?)JsonValue.Create(v)).ToArray());
            }
            else if(source?[key]!=null)throw new InvalidDataException("Unrecognized permission rule schema");
            else result[key]=new JsonArray();
        }
        return result;
    }
    private static string? FolderUri(JsonNode? value) => value is JsonValue scalar&&scalar.TryGetValue<string>(out var text)&&
        Uri.TryCreate(text,UriKind.Absolute,out var uri)&&uri.IsFile&&Path.IsPathFullyQualified(uri.LocalPath)?Path.GetFullPath(uri.LocalPath):null;
    private static bool SamePath(string a,string b) => string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)),Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),StringComparison.OrdinalIgnoreCase);
}
