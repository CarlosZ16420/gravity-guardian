using System.Text.Json.Nodes;

namespace AgApproval;

// Installed and portable builds share the same binaries. Only portable.json selects a layout.
internal sealed record StorageLayout(string Root)
{
    internal string ProgramDirectory => Path.Combine(Root, "app");
    internal string ConfigPath => Path.Combine(Root, "config", "approval.json");
    internal string DataDirectory => Path.Combine(Root, "data");
    internal string InstallationPath => Path.Combine(DataDirectory, "installation.json");

    internal static string DefaultConfigPath()
    {
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", ".."));
        return File.Exists(Path.Combine(root, "portable.json"))
            ? Path.Combine(root, "config", "approval.json")
            : Path.Combine(AppContext.BaseDirectory, "approval.json");
    }

    internal static StorageLayout? FromConfig(string path)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        if (!string.Equals(Path.GetFileName(directory), "config", StringComparison.OrdinalIgnoreCase)) return null;
        var root = Path.GetDirectoryName(directory)!;
        var marker = Path.Combine(root, "portable.json");
        if (!File.Exists(marker)) return null;
        var doc = JsonNode.Parse(File.ReadAllText(marker));
        if (Json.Text(doc, "storageMode") != "portable" || doc?["layoutVersion"]?.GetValue<int>() != 1)
            throw new InvalidDataException("Unsupported portable layout");
        ReviewContext.ValidateComponents(marker);
        return new(root);
    }

    internal void Resolve(Settings settings)
    {
        JsonNode? installation = File.Exists(InstallationPath) ? JsonNode.Parse(File.ReadAllText(InstallationPath)) : null;
        var gemini = Json.Text(installation, "geminiRoot")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini");
        settings.PortableRoot = Root;
        settings.DataDirectory = DataDirectory;
        settings.PolicyDirectory = Path.Combine(ProgramDirectory, "policy", "effective-codex");
        settings.GuardianPath = Path.Combine(ProgramDirectory, "native", "ag-guardian-host.exe");
        settings.CodexHome = Json.Text(installation, "codexHome")
            ?? Environment.GetEnvironmentVariable("CODEX_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        settings.AntigravityConfigDirectory = Path.Combine(gemini, "config");
        settings.TranscriptRoots = [Path.Combine(gemini, "antigravity", "brain"),
            Path.Combine(gemini, "antigravity-cli", "brain"), Path.Combine(gemini, "antigravity-ide", "brain")];
        if (installation?["transcriptRoots"] is JsonArray roots)
            settings.TranscriptRoots = roots.Select(p => p!.GetValue<string>()).ToArray();
        settings.NativeStateLogPath = Json.Text(installation, "nativeStateLogPath")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Antigravity", "logs", "main.log");
    }

    internal bool IsConnected(string configRoot)
    {
        var binding = Path.Combine(configRoot, "plugins", "gravity-guardian", "binding.json");
        if (!File.Exists(binding)) return false;
        var doc = JsonNode.Parse(File.ReadAllText(binding));
        return Json.Text(doc, "storageMode") == "portable" &&
            string.Equals(Json.Text(doc, "portableRoot"), Root, StringComparison.OrdinalIgnoreCase);
    }
}
