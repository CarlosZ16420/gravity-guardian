using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace AgApproval;

public sealed record AntigravityDetection(bool Found, string Path, string? Version, string Source);

public sealed record CodexDetection(
    bool Found,
    string Path,
    string? Version,
    bool LoggedIn,
    string LoginSummary,
    bool AuthFilePresent,
    string Source);

public sealed record EnvironmentDetectionReport(
    AntigravityDetection Antigravity,
    CodexDetection Codex,
    string GeminiRoot,
    string DataDirectory,
    bool PluginInstalled,
    string PluginDirectory);

public static class EnvironmentDiscovery
{
    public static EnvironmentDetectionReport DetectAll(
        string? configuredAntigravityPath = null,
        string? configuredCodexPath = null,
        string? geminiRoot = null,
        string? dataDirectory = null,
        bool skipLoginCheck = false)
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var resolvedGemini = string.IsNullOrWhiteSpace(geminiRoot)
            ? Path.Combine(userProfile, ".gemini")
            : Path.GetFullPath(geminiRoot);
        var resolvedData = string.IsNullOrWhiteSpace(dataDirectory)
            ? Path.Combine(resolvedGemini, "codex-approval-data")
            : Path.GetFullPath(dataDirectory);
        var pluginDir = Path.Combine(resolvedGemini, "config", "plugins", "codex-approval");
        bool installed = File.Exists(Path.Combine(pluginDir, "plugin.json")) &&
                         File.Exists(Path.Combine(pluginDir, "approval.json"));

        var ag = DetectAntigravity(configuredAntigravityPath);
        var codex = DetectCodexCli(configuredCodexPath, Path.Combine(userProfile, ".codex"), skipLoginCheck);
        return new EnvironmentDetectionReport(ag, codex, resolvedGemini, resolvedData, installed, pluginDir);
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

    public static CodexDetection DetectCodexCli(string? configuredPath = null, string? codexHome = null, bool skipLoginCheck = false)
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var resolvedHome = string.IsNullOrWhiteSpace(codexHome) ? Path.Combine(userProfile, ".codex") : codexHome;
        bool authPresent = File.Exists(Path.Combine(resolvedHome, "auth.json"));

        string? resolvedExe = null;
        string source = "not_found";

        if (!string.IsNullOrWhiteSpace(configuredPath) && File.Exists(configuredPath))
        {
            resolvedExe = ResolveCodexShim(configuredPath) ?? (configuredPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? Path.GetFullPath(configuredPath) : null);
            if (resolvedExe != null) source = "configured";
        }

        if (resolvedExe == null)
        {
            var pathVar = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                foreach (var name in new[] { "codex.exe", "codex.cmd", "codex.ps1" })
                {
                    var candidate = SafeCombine(dir, name);
                    if (candidate == null || !File.Exists(candidate)) continue;
                    var resolved = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                        ? Path.GetFullPath(candidate)
                        : ResolveCodexShim(candidate);
                    if (resolved != null && File.Exists(resolved))
                    {
                        resolvedExe = resolved;
                        source = "path";
                        break;
                    }
                }
                if (resolvedExe != null) break;
            }
        }

        if (resolvedExe == null)
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var probeDirs = new[]
            {
                Path.Combine(appData, "npm"),
                Path.Combine(localAppData, "pnpm"),
                Path.Combine(userProfile, ".volta", "bin"),
                Path.Combine(userProfile, "scoop", "shims"),
                Path.Combine(userProfile, ".cargo", "bin"),
                Path.Combine(localAppData, "Programs"),
                Path.Combine(appData, "npm", "node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin"),
                Path.Combine(appData, "npm", "node_modules", "@openai", "codex", "vendor", "x86_64-pc-windows-msvc", "codex")
            };

            foreach (var dir in probeDirs)
            {
                foreach (var name in new[] { "codex.exe", "codex.cmd" })
                {
                    var candidate = SafeCombine(dir, name);
                    if (candidate == null || !File.Exists(candidate)) continue;
                    var resolved = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                        ? Path.GetFullPath(candidate)
                        : ResolveCodexShim(candidate);
                    if (resolved != null && File.Exists(resolved))
                    {
                        resolvedExe = resolved;
                        source = "standard_location";
                        break;
                    }
                }
                if (resolvedExe != null) break;
            }
        }

        if (resolvedExe == null)
        {
            return new CodexDetection(
                Found: false,
                Path: "",
                Version: null,
                LoggedIn: authPresent,
                LoginSummary: authPresent ? "已检测到 .codex/auth.json（未检测到 Codex CLI）" : "未检测到 Codex CLI",
                AuthFilePresent: authPresent,
                Source: "not_found");
        }

        string? version = null;
        bool loggedIn = authPresent;
        string loginSummary = authPresent ? "已检测到登录凭证" : "未登录";

        if (!skipLoginCheck)
        {
            var verRes = RunQuick(resolvedExe, ["--version"], 3000);
            if (verRes.ExitCode == 0 && !string.IsNullOrWhiteSpace(verRes.Output))
                version = verRes.Output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();

            var loginRes = RunQuick(resolvedExe, ["login", "status"], 3000, new Dictionary<string, string> { ["CODEX_HOME"] = resolvedHome });
            if (loginRes.ExitCode == 0)
            {
                loggedIn = true;
                var msg = (loginRes.Output + " " + loginRes.Error).Trim();
                loginSummary = string.IsNullOrWhiteSpace(msg) ? "已登录" : msg.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).First().Trim();
            }
            else if (loginRes.ExitCode is not null)
            {
                loggedIn = false;
                var msg = (loginRes.Error + " " + loginRes.Output).Trim();
                loginSummary = string.IsNullOrWhiteSpace(msg) ? "未登录" : msg.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).First().Trim();
            }
        }

        return new CodexDetection(true, resolvedExe, version, loggedIn, loginSummary, authPresent, source);
    }

    public static string? ResolveCodexShim(string shimPath)
    {
        if (string.IsNullOrWhiteSpace(shimPath) || !File.Exists(shimPath))
            return null;
        var full = Path.GetFullPath(shimPath);
        if (full.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            return full;

        var dir = Path.GetDirectoryName(full);
        if (string.IsNullOrEmpty(dir)) return null;

        // Typical npm layout: <prefix>\codex.cmd alongside <prefix>\node_modules\@openai\codex\...
        var directCandidates = new[]
        {
            Path.Combine(dir, "codex.exe"),
            Path.Combine(dir, "node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
            Path.Combine(dir, "node_modules", "@openai", "codex", "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"),
            Path.Combine(dir, "node_modules", "@openai", "codex", "bin", "codex.exe")
        };

        foreach (var candidate in directCandidates)
        {
            if (File.Exists(candidate))
                return Path.GetFullPath(candidate);
        }

        // Parse .cmd/.ps1 content for relative path to @openai/codex or codex.exe
        try
        {
            var text = File.ReadAllText(full);
            var exeMatch = Regex.Match(text, @"([A-Za-z0-9_.\-\\/%~]+\.exe)", RegexOptions.IgnoreCase);
            if (exeMatch.Success)
            {
                var raw = exeMatch.Groups[1].Value.Replace("%dp0%", dir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    .Replace("%~dp0", dir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    .Replace("$basedir", dir, StringComparison.OrdinalIgnoreCase);
                if (!Path.IsPathFullyQualified(raw)) raw = Path.Combine(dir, raw);
                if (File.Exists(raw)) return Path.GetFullPath(raw);
            }

            var jsMatch = Regex.Match(text, @"node_modules[\\/]@openai[\\/]codex[\\/]", RegexOptions.IgnoreCase);
            if (jsMatch.Success)
            {
                // Also support pnpm nested .pnpm layout under <dir>\node_modules
                var pnpmRoot = Path.Combine(dir, "node_modules", ".pnpm");
                if (Directory.Exists(pnpmRoot))
                {
                    foreach (var found in Directory.EnumerateFiles(pnpmRoot, "codex.exe", SearchOption.AllDirectories))
                        return Path.GetFullPath(found);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }

        return null;
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

    private static string? SafeCombine(string dir, string file)
    {
        try { return Path.Combine(dir, file); }
        catch (ArgumentException) { return null; }
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

    private static (int? ExitCode, string Output, string Error) RunQuick(string exe, string[] args, int timeoutMs, Dictionary<string, string>? env = null)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
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
