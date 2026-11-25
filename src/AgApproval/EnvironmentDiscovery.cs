using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace AgApproval;

public sealed record AntigravityDetection(bool Found, string Path, string? Version, string Source);

public sealed record EnvironmentDetectionReport(
    AntigravityDetection Antigravity,
    string GeminiRoot,
    string DataDirectory,
    bool PluginInstalled,
    string PluginDirectory)
{
    public JsonObject? NativeAuth { get; init; }
}

public static class EnvironmentDiscovery
{
    public static EnvironmentDetectionReport DetectAll(
        string? configuredAntigravityPath = null,
        string? geminiRoot = null,
        string? dataDirectory = null,
        bool skipLoginCheck = false,
        string? approvalConfig = null)
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var resolvedGemini = string.IsNullOrWhiteSpace(geminiRoot)
            ? Path.Combine(userProfile, ".gemini")
            : Path.GetFullPath(geminiRoot);
        var pluginDir = Path.Combine(resolvedGemini, "config", "plugins", "gravity-guardian");
        bool installed = File.Exists(Path.Combine(pluginDir, "plugin.json")) &&
                         File.Exists(Path.Combine(pluginDir, "approval.json"));

        var ag = DetectAntigravity(configuredAntigravityPath);
        var configPath = approvalConfig ?? Path.Combine(pluginDir, "approval.json");
        var defaultHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(defaultHome)) defaultHome = Path.Combine(userProfile, ".codex");
        JsonObject? config = null;
        if (File.Exists(configPath))
        {
            try { config = JsonNode.Parse(File.ReadAllText(configPath)) as JsonObject; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
        }
        var codexHome = Json.Text(config, "codexHome") ?? defaultHome;
        var configuredData = dataDirectory ?? Json.Text(config, "dataDirectory");
        var resolvedData = string.IsNullOrWhiteSpace(configuredData)
            ? Path.Combine(resolvedGemini, "gravity-guardian-data")
            : Path.GetFullPath(configuredData);
        var executable = Json.Text(config, "guardianPath");
        if (string.IsNullOrWhiteSpace(executable))
            executable = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(configPath))!, "native", "ag-guardian-host.exe");
        if (!File.Exists(executable))
        {
            var bundled = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "native", "ag-guardian-host.exe"));
            if (File.Exists(bundled)) executable = bundled;
        }
        var nativeAuth = skipLoginCheck ? null
            : ProbeNativeAuth(executable, codexHome, Path.Combine(resolvedData, "guardian-workspace"));
        return new EnvironmentDetectionReport(ag, resolvedGemini, resolvedData, installed, pluginDir) { NativeAuth = nativeAuth };
    }

    private static JsonObject ProbeNativeAuth(string executable, string codexHome, string workspace)
    {
        try
        {
            NativeGuardianReviewer.VerifyBinary(executable);
            var probe = RunQuick(executable, ["--check-auth"], 12000,
                new Dictionary<string, string> { ["CODEX_HOME"] = codexHome }, Directory.Exists(workspace) ? workspace : null,
                NativeGuardianReviewer.StrippedAuthEnvironmentVariables);
            if (JsonNode.Parse(probe.Output) is JsonObject reply && (probe.ExitCode, Json.Text(reply, "status")) is
                (0, "credentials_found") or (1, "credentials_missing") or (2, "store_unavailable"))
                return reply;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or
            Win32Exception or ArgumentException or InvalidOperationException) { }
        return new JsonObject { ["status"] = "store_unavailable", ["codexHome"] = codexHome,
            ["storeMode"] = null, ["storeError"] = "guardian_probe_unavailable" };
    }

    public static AntigravityDetection DetectAntigravity(string? configuredPath = null)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath) && File.Exists(configuredPath))
        {
            var full = Path.GetFullPath(configuredPath);
            return new AntigravityDetection(true, full, ReadFileVersion(full), "configured");
        }

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);

        var candidates = new List<(string Path, string Source)>
        {
            (Path.Combine(localAppData, "Programs", "antigravity", "Antigravity.exe"), "local_appdata"),
            (Path.Combine(localAppData, "Programs", "Antigravity", "Antigravity.exe"), "local_appdata"),
            (Path.Combine(programFiles, "Antigravity", "Antigravity.exe"), "program_files"),
            (Path.Combine(programFilesX86, "Antigravity", "Antigravity.exe"), "program_files_x86")
        };

        foreach (var (candidate, source) in candidates)
        {
            if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
            {
                var full = Path.GetFullPath(candidate);
                return new AntigravityDetection(true, full, ReadFileVersion(full), source);
            }
        }

        try
        {
            foreach (var proc in Process.GetProcessesByName("Antigravity"))
            {
                using (proc)
                {
                    try
                    {
                        var path = proc.MainModule?.FileName;
                        if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
                            return new AntigravityDetection(true, Path.GetFullPath(path), ReadFileVersion(path), "running_process");
                    }
                    catch (Exception e) when (e is Win32Exception or InvalidOperationException) { }
                }
            }
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException) { }

        if (OperatingSystem.IsWindows())
        {
            var fromRegistry = ProbeUninstallRegistryForAntigravity();
            if (!string.IsNullOrWhiteSpace(fromRegistry) && File.Exists(fromRegistry))
                return new AntigravityDetection(true, Path.GetFullPath(fromRegistry), ReadFileVersion(fromRegistry), "windows_registry");
        }

        return new AntigravityDetection(false, "", null, "not_found");
    }

    [SupportedOSPlatform("windows")]
    private static string? ProbeUninstallRegistryForAntigravity()
    {
        var hives = new[]
        {
            (Registry.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")
        };

        foreach (var (hive, subKeyPath) in hives)
        {
            try
            {
                using var rootKey = hive.OpenSubKey(subKeyPath);
                if (rootKey == null) continue;
                foreach (var name in rootKey.GetSubKeyNames())
                {
                    using var sub = rootKey.OpenSubKey(name);
                    if (sub == null) continue;
                    var displayName = sub.GetValue("DisplayName") as string;
                    if (string.IsNullOrWhiteSpace(displayName) ||
                        !displayName.Contains("Antigravity", StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (sub.GetValue("InstallLocation") is string installLoc && !string.IsNullOrWhiteSpace(installLoc))
                    {
                        var exe = Path.Combine(installLoc.Trim('"'), "Antigravity.exe");
                        if (File.Exists(exe)) return exe;
                    }
                    if (sub.GetValue("DisplayIcon") is string icon && !string.IsNullOrWhiteSpace(icon))
                    {
                        var cleaned = icon.Split(',')[0].Trim().Trim('"');
                        if (cleaned.EndsWith("Antigravity.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(cleaned))
                            return cleaned;
                    }
                }
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { }
        }
        return null;
    }

    private static string? ReadFileVersion(string path)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(path);
            return string.IsNullOrWhiteSpace(info.ProductVersion) ? info.FileVersion : info.ProductVersion;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static (int? ExitCode, string Output, string Error) RunQuick(string exe, string[] args, int timeoutMs,
        Dictionary<string, string>? env = null, string? workingDirectory = null, IEnumerable<string>? removeEnv = null)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = workingDirectory ?? "",
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            if (removeEnv != null)
            {
                foreach (var key in removeEnv) psi.Environment.Remove(key);
            }
            if (env != null)
            {
                foreach (var kv in env) psi.Environment[kv.Key] = kv.Value;
            }
            using var proc = Process.Start(psi);
            if (proc == null) return (null, "", "");
            var outTask = proc.StandardOutput.ReadToEndAsync();
            var errTask = proc.StandardError.ReadToEndAsync();
            if (!proc.WaitForExit(timeoutMs))
            {
                try { proc.Kill(entireProcessTree: true); } catch { }
                return (null, "", "timeout");
            }
            return (proc.ExitCode, outTask.GetAwaiter().GetResult(), errTask.GetAwaiter().GetResult());
        }
        catch (Exception e) when (e is IOException or Win32Exception or InvalidOperationException)
        {
            return (null, "", e.Message);
        }
    }
}
