#include "resource.h"
#include "updater.h"
#include "util.h"
#include "version.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace panel {

namespace {

constexpr wchar_t kWindowClass[] = L"AntigravityCodexApprovalPanelWnd";
constexpr UINT kDwmWindowCornerPreference = 33;
constexpr DWORD kDwmRound = 2;
constexpr int kPanelWidth = 414;
constexpr int kCompactHeight = 581;
constexpr int kBannerSpace = 50;
constexpr int kPreferencesSpace = 158;
constexpr DWORD kPanelStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
constexpr DWORD kPanelExStyle = WS_EX_DLGMODALFRAME;

constexpr COLORREF kText = RGB(32, 39, 52);
constexpr COLORREF kSecondary = RGB(87, 98, 114);
constexpr COLORREF kBlue = RGB(15, 104, 229);
constexpr COLORREF kGreen = RGB(20, 122, 65);
constexpr COLORREF kRed = RGB(172, 35, 48);

enum class TrayColor { Green, Blue, Amber, Red };

struct PanelConfig {
    std::wstring geminiRoot;
    std::wstring dataDirectory;
    std::wstring pluginDirectory;
    std::wstring bundleDirectory;
    std::wstring antigravityPath;
    bool autoCheckUpdates = true;
    bool autoUpdate = true;
    bool autostart = false;
};

struct DateRange {
    std::wstring from;
    std::wstring to;
    bool operator==(const DateRange&) const = default;
};

enum class StatsPeriod { Today, Week, Custom };

struct ApprovalStats {
    int64_t total = 0;
    int64_t model = 0;
    int64_t approved = 0;
    int64_t denied = 0;
    int64_t delegated = 0;
    int64_t tokens = 0;
    int64_t inputTokens = 0;
    int64_t cachedTokens = 0;
    int64_t outputTokens = 0;
    int64_t unknownUsage = 0;
    double costUsd = 0.0;
};

struct StatsResult {
    std::optional<ApprovalStats> today;
    std::optional<ApprovalStats> week;
    std::optional<ApprovalStats> custom;
    std::optional<DateRange> dates;
    uint64_t logsSizeBytes = 0;
    std::wstring pricingLabel = L"GPT-6 Luna 低思考 × 2（估算）";
};

struct RuntimeState {
    bool pluginInstalled = false;
    bool serviceRunning = false;
    std::wstring serviceVersion = PANEL_VERSION_WIDE;
    std::wstring serviceDetail = L"正在初始化...";
    std::wstring serviceBackend;
    std::optional<bool> takeoverEnabled;
    unsigned takeoverRevision = 0;
    bool detailedLogs = false;

    bool agFound = false;
    std::wstring agVersion;
    std::wstring guardianAuthStatus;

    bool updateChecked = false;
    bool updateAvailable = false;
    bool updateDownloaded = false;
    bool waitingAntigravityExit = false;
    UpdateManifest availableUpdate;
    std::wstring downloadedZipPath;
    std::wstring updateBannerText;
};

enum class WorkKind {
    InitialRefresh,
    RefreshAll,
    ServiceEnsure,
    LaunchAntigravity,
    DetectEnv,
    ToggleApprovalTakeover,
    ToggleDetailedLogs,
    CompactLogs,
    CheckAndMaybeUpdate,
    DownloadUpdate,
    InstallOrRepair
};

struct WorkResult {
    WorkKind kind{};
    bool ok = false;
    std::wstring message;
    RuntimeState snapshot;
    bool triggerImmediateApply = false;
    bool requestExit = false;
    bool targetDetailedLogs = false;
};

struct App {
    HINSTANCE hInst = nullptr;
    HWND hwnd = nullptr;
    NOTIFYICONDATAW nid{};
    bool trayAdded = false;

    HFONT fontTitle = nullptr;
    HFONT fontHeading = nullptr;
    HFONT fontBold = nullptr;
    HFONT fontRegular = nullptr;
    HFONT fontSmall = nullptr;
    HFONT fontMetric = nullptr;
    HBRUSH brushBg = nullptr;
    HBRUSH brushCard = nullptr;
    HBRUSH brushBanner = nullptr;

    HICON iconGreen = nullptr;
    HICON iconBlue = nullptr;
    HICON iconAmber = nullptr;
    HICON iconRed = nullptr;

    PanelConfig cfg;
    UpdateConfig updateCfg;
    RuntimeState state;
    std::mutex cfgMutex;

    std::atomic<bool> busyRefresh{false};
    std::atomic<bool> busyUpdate{false};
    std::atomic<bool> busyAction{false};
    bool busyTakeover = false;
    bool uninstallPromptOpen = false;
    bool statsRunning = false;
    bool statsPending = false;
    bool statsLoaded = false;
    StatsPeriod period = StatsPeriod::Today;
    std::optional<DateRange> customDates;
    StatsResult stats;
    bool preferencesOpen = false;
    int scrollY = 0;

    // Child controls
    HWND lblTitle = nullptr;
    HWND lblStatus = nullptr;
    HWND btnApprovalTakeover = nullptr;
    HWND lblBackend = nullptr;
    HWND btnLaunchAg = nullptr;
    HWND btnServiceAction = nullptr;
    HWND btnRefresh = nullptr;

    HWND lblUpdateBanner = nullptr;
    HWND btnUpdateNow = nullptr;

    HWND lblStatsTitle = nullptr;
    HWND btnStatsDate = nullptr;
    HWND lblStatsCount = nullptr;
    HWND lblStatsSub = nullptr;
    HWND lblStatsTokens = nullptr;
    HWND lblStatsCost = nullptr;
    HWND lblPricingTitle = nullptr;
    HWND lblPricingNote = nullptr;
    HWND btnOpenPricing = nullptr;
    HWND btnPreferences = nullptr;

    HWND chkDetailedLogs = nullptr;
    HWND lblLogBadge = nullptr;
    HWND lblLogSize = nullptr;
    HWND btnOpenLogs = nullptr;
    HWND btnCompactLogs = nullptr;
    HWND chkAutostart = nullptr;
    HWND chkAutoUpdate = nullptr;
    HWND lblVersionInfo = nullptr;
    HWND btnCheckUpdate = nullptr;

    HWND lblAppsTitle = nullptr;
    HWND lblAgTitle = nullptr;
    HWND lblAgPath = nullptr;
    HWND btnBrowseAg = nullptr;
    HWND lblGuardianTitle = nullptr;
    HWND lblGuardianAuth = nullptr;
    HWND btnDetectEnv = nullptr;

    HWND btnInstallRepair = nullptr;
    HWND btnUninstall = nullptr;
};

App g_app;

void ResizePanelToContent();

void WriteStdoutUtf8(std::string_view text) {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hOut == nullptr || hOut == INVALID_HANDLE_VALUE) {
        if (AttachConsole(ATTACH_PARENT_PROCESS)) {
            hOut = GetStdHandle(STD_OUTPUT_HANDLE);
        }
    }
    if (hOut != nullptr && hOut != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(hOut, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
    }
}

int Scale(HWND hwnd, int dip) {
    UINT dpi = hwnd ? GetDpiForWindow(hwnd) : 96;
    if (dpi == 0) dpi = 96;
    return MulDiv(dip, static_cast<int>(dpi), 96);
}

HICON CreateShieldBadgeIcon(COLORREF fillColor, int size) {
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = size;
    bmi.bmiHeader.biHeight = -size;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP colorBmp = CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HBITMAP maskBmp = CreateBitmap(size, size, 1, 1, nullptr);
    HICON icon = nullptr;

    if (colorBmp && maskBmp && bits) {
        auto* pixels = static_cast<uint32_t*>(bits);
        double r = static_cast<double>(size) * 0.44;
        double cx = (size - 1) * 0.5;
        double cy = (size - 1) * 0.5;
        uint8_t cr = GetRValue(fillColor);
        uint8_t cg = GetGValue(fillColor);
        uint8_t cb = GetBValue(fillColor);

        for (int y = 0; y < size; ++y) {
            for (int x = 0; x < size; ++x) {
                double dx = x - cx;
                double dy = y - cy;
                double dist = std::sqrt(dx * dx + dy * dy);
                if (dist <= r - 0.5) {
                    // Draw a crisp inner checkmark/shield highlight
                    bool innerDot = (dist <= r * 0.36);
                    uint8_t pr = innerDot ? 255 : cr;
                    uint8_t pg = innerDot ? 255 : cg;
                    uint8_t pb = innerDot ? 255 : cb;
                    pixels[y * size + x] = (0xFFu << 24) | (static_cast<uint32_t>(pr) << 16) |
                                           (static_cast<uint32_t>(pg) << 8) | pb;
                } else if (dist <= r + 0.7) {
                    // Subtle border ring
                    pixels[y * size + x] = (0xFFu << 24) | (static_cast<uint32_t>(cr / 2) << 16) |
                                           (static_cast<uint32_t>(cg / 2) << 8) | (cb / 2);
                } else {
                    pixels[y * size + x] = 0;
                }
            }
        }

        ICONINFO ii{};
        ii.fIcon = TRUE;
        ii.hbmColor = colorBmp;
        ii.hbmMask = maskBmp;
        icon = CreateIconIndirect(&ii);
    }

    if (maskBmp) DeleteObject(maskBmp);
    if (colorBmp) DeleteObject(colorBmp);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return icon;
}

std::wstring GetUserProfileDir() {
    wchar_t buf[MAX_PATH]{};
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", buf, static_cast<DWORD>(std::size(buf)));
    return n > 0 ? std::wstring(buf, n) : L"";
}

std::wstring PanelSettingsPath(const PanelConfig& cfg) {
    return JoinPath(cfg.dataDirectory, L"panel-settings.json");
}

void SavePanelConfig(const PanelConfig& cfg) {
    EnsureDirectoryTree(cfg.dataDirectory);
    std::wstring path = PanelSettingsPath(cfg);

    JsonValue doc;
    std::string existing;
    if (ReadFileUtf8(path, existing)) {
        JsonValue parsed;
        if (JsonValue::Parse(existing, parsed) && parsed.kind == JsonValue::Kind::Object) {
            doc = std::move(parsed);
        }
    }
    if (doc.kind != JsonValue::Kind::Object) doc.kind = JsonValue::Kind::Object;

    auto setStr = [&](const char* k, const std::wstring& v) {
        JsonValue j;
        j.kind = JsonValue::Kind::String;
        j.strVal = WideToUtf8(v);
        doc.objVal.insert_or_assign(k, std::move(j));
    };
    auto setBool = [&](const char* k, bool v) {
        JsonValue j;
        j.kind = JsonValue::Kind::Bool;
        j.boolVal = v;
        doc.objVal.insert_or_assign(k, std::move(j));
    };

    setStr("geminiRoot", cfg.geminiRoot);
    setStr("dataDirectory", cfg.dataDirectory);
    setStr("pluginDirectory", cfg.pluginDirectory);
    setStr("antigravityPath", cfg.antigravityPath);
    doc.objVal.erase("codexPath");
    setBool("autoCheckUpdates", cfg.autoCheckUpdates);
    setBool("autoUpdate", cfg.autoUpdate);
    setBool("autostart", cfg.autostart);

    WriteFileUtf8Atomic(path, doc.Dump(true));
}

void LoadPanelPreferences(PanelConfig& cfg) {
    std::string raw;
    JsonValue doc;
    if (!ReadFileUtf8(PanelSettingsPath(cfg), raw) || !JsonValue::Parse(raw, doc) ||
        doc.kind != JsonValue::Kind::Object) return;
    cfg.antigravityPath = doc.GetWide("antigravityPath");
    cfg.autoCheckUpdates = doc.GetBool("autoCheckUpdates", true);
    cfg.autoUpdate = doc.GetBool("autoUpdate", true);
    cfg.autostart = doc.GetBool("autostart", false);
}

void InitPathsAndConfig(const std::wstring& optPlugin, const std::wstring& optData, const std::wstring& optGemini) {
    std::wstring exeDir = GetDirectoryName(GetExecutablePath());
    std::wstring parentDir = GetDirectoryName(exeDir);
    std::wstring profile = GetUserProfileDir();

    PanelConfig cfg{};
    cfg.geminiRoot = !optGemini.empty() ? optGemini : JoinPath(profile, L".gemini");
    cfg.dataDirectory = !optData.empty() ? optData : JoinPath(cfg.geminiRoot, L"codex-approval-data");
    cfg.pluginDirectory = !optPlugin.empty() ? optPlugin : JoinPath(cfg.geminiRoot, L"config\\plugins\\codex-approval");

    // Pick bundleDirectory (contains runtime/dotnet.exe & scripts/ag-approval.dll)
    std::wstring nestedBundle = JoinPath(exeDir, L"artifacts\\codex-approval");
    if (FileExists(JoinPath(cfg.pluginDirectory, L"scripts\\ag-approval.dll")) &&
        FileExists(JoinPath(cfg.pluginDirectory, L"runtime\\dotnet.exe"))) {
        cfg.bundleDirectory = cfg.pluginDirectory;
    } else if (FileExists(JoinPath(parentDir, L"scripts\\ag-approval.dll")) &&
               FileExists(JoinPath(parentDir, L"runtime\\dotnet.exe"))) {
        cfg.bundleDirectory = parentDir;
    } else if (FileExists(JoinPath(nestedBundle, L"scripts\\ag-approval.dll")) &&
               FileExists(JoinPath(nestedBundle, L"runtime\\dotnet.exe"))) {
        cfg.bundleDirectory = nestedBundle;
    } else {
        cfg.bundleDirectory = cfg.pluginDirectory;
    }

    LoadPanelPreferences(cfg);

    // Also inspect installation.json if panel-settings lacked paths
    if (cfg.antigravityPath.empty()) {
        std::string instRaw;
        if (ReadFileUtf8(JoinPath(cfg.dataDirectory, L"installation.json"), instRaw)) {
            JsonValue inst;
            if (JsonValue::Parse(instRaw, inst) && inst.kind == JsonValue::Kind::Object) {
                if (cfg.antigravityPath.empty()) cfg.antigravityPath = inst.GetWide("antigravityPath");
            }
        }
    }

    // Synchronize registry autostart path if enabled
    std::wstring exePath = GetExecutablePath();
    if (!GetAutostartCommand().empty()) {
        cfg.autostart = true;
        if (!IsAutostartMatching(exePath)) {
            SetAutostart(true, exePath);
        }
    } else if (cfg.autostart) {
        SetAutostart(true, exePath);
    }

    // Load update-config.json from pluginDirectory or bundleDirectory
    std::wstring updPath = JoinPath(cfg.pluginDirectory, L"update-config.json");
    if (!FileExists(updPath)) updPath = JoinPath(cfg.bundleDirectory, L"update-config.json");
    g_app.updateCfg = LoadUpdateConfig(updPath);
    g_app.cfg = std::move(cfg);
}

std::wstring GetDotnetExe(const PanelConfig& cfg) {
    std::wstring p1 = JoinPath(cfg.pluginDirectory, L"runtime\\dotnet.exe");
    if (FileExists(p1)) return p1;
    return JoinPath(cfg.bundleDirectory, L"runtime\\dotnet.exe");
}

std::wstring GetAssemblyDll(const PanelConfig& cfg) {
    std::wstring p1 = JoinPath(cfg.pluginDirectory, L"scripts\\ag-approval.dll");
    if (FileExists(p1)) return p1;
    return JoinPath(cfg.bundleDirectory, L"scripts\\ag-approval.dll");
}

std::wstring GetPricingJsonPath(const PanelConfig& cfg) {
    std::wstring p1 = JoinPath(cfg.pluginDirectory, L"pricing.json");
    if (FileExists(p1)) return p1;
    return JoinPath(cfg.bundleDirectory, L"pricing.json");
}

std::wstring GetApplyScriptPath(const PanelConfig& cfg) {
    std::wstring p1 = JoinPath(cfg.pluginDirectory, L"scripts\\Apply-Update.ps1");
    if (FileExists(p1)) return p1;
    return JoinPath(cfg.bundleDirectory, L"scripts\\Apply-Update.ps1");
}

std::optional<ApprovalStats> ReadApprovalStats(const JsonValue* w) {
    if (!w || w->kind != JsonValue::Kind::Object) return std::nullopt;
    ApprovalStats stats;
    stats.total = w->GetInt64("totalRequests", 0);
    stats.model = w->GetInt64("modelCalls", 0);
    stats.approved = w->GetInt64("approved", 0);
    stats.denied = w->GetInt64("denied", 0);
    stats.delegated = w->GetInt64("delegated", 0);
    stats.tokens = w->GetInt64("totalTokens", 0);
    stats.inputTokens = w->GetInt64("inputTokens", 0);
    stats.cachedTokens = w->GetInt64("cachedInputTokens", 0);
    stats.outputTokens = w->GetInt64("outputTokens", 0);
    stats.unknownUsage = w->GetInt64("unknownOrPartialUsageCalls", 0);
    stats.costUsd = w->GetDouble("estimatedCostUsd", 0.0);
    return stats;
}

StatsResult QueryApprovalStats(const PanelConfig& cfg, const std::optional<DateRange>& dates) {
    StatsResult result;
    result.dates = dates;
    std::wstring dotnet = GetDotnetExe(cfg);
    std::wstring dll = GetAssemblyDll(cfg);
    std::wstring exeDir = GetDirectoryName(GetExecutablePath());
    // Use the core shipped with this panel for its read-only statistics, even with an older installed plugin.
    for (const auto& bundle : {GetDirectoryName(exeDir), JoinPath(exeDir, L"artifacts\\codex-approval")}) {
        auto bundledDotnet = JoinPath(bundle, L"runtime\\dotnet.exe");
        auto bundledDll = JoinPath(bundle, L"scripts\\ag-approval.dll");
        if (FileExists(bundledDotnet) && FileExists(bundledDll)) {
            dotnet = std::move(bundledDotnet);
            dll = std::move(bundledDll);
            break;
        }
    }

    auto pricing = GetPricingJsonPath(cfg);
    std::wstring args = L"\"" + dll + L"\" stats --data-dir \"" + cfg.dataDirectory + L"\"";
    if (FileExists(pricing)) args += L" --pricing \"" + pricing + L"\"";
    if (dates) args += L" --from-date " + dates->from + L" --to-date " + dates->to;
    if (FileExists(dotnet) && FileExists(dll)) {
        auto cmd = RunHiddenCommand(dotnet, args, GetDirectoryName(dll), dates ? 60000 : 8000);
        JsonValue report;
        if (cmd.started && !cmd.timedOut && cmd.exitCode == 0 && JsonValue::Parse(cmd.stdoutUtf8, report)) {
            if (const auto* price = report.Get("pricing")) {
                result.pricingLabel = price->GetWide("displayLabel", result.pricingLabel);
            }
            result.today = ReadApprovalStats(report.Get("today"));
            result.week = ReadApprovalStats(report.Get("last7Days"));
            result.custom = ReadApprovalStats(report.Get("customRange"));
            result.logsSizeBytes = static_cast<uint64_t>(std::max<int64_t>(0, report.GetInt64("logsSizeBytes", 0)));
        }
    }
    if (!result.today) result.logsSizeBytes = SumFilesSize(JoinPath(cfg.dataDirectory, L"logs"), L".jsonl");
    return result;
}

void SyncStatsToUi() {
    const auto& report = g_app.stats;
    const auto* value = &report.today;
    std::wstring title = L"今日审批";
    if (g_app.period == StatsPeriod::Week) {
        value = &report.week;
        title = L"近 7 日审批";
    } else if (g_app.period == StatsPeriod::Custom && g_app.customDates) {
        const auto& dates = *g_app.customDates;
        value = report.dates == g_app.customDates ? &report.custom : nullptr;
        title = dates.from == dates.to ? dates.from : dates.from + L" 至 " + dates.to;
    }
    SetWindowTextW(g_app.lblStatsTitle, title.c_str());
    if (!value || !*value) {
        SetWindowTextW(g_app.lblStatsCount, L"—");
        SetWindowTextW(g_app.lblStatsSub, !g_app.statsLoaded || g_app.statsRunning ? L"正在读取统计…" : L"暂时无法读取统计");
        SetWindowTextW(g_app.lblStatsTokens, L"");
        SetWindowTextW(g_app.lblStatsCost, L"");
    } else {
        const auto& s = **value;
        auto count = FormatIntWithCommas(s.total) + L" 次";
        auto sub = L"模型 " + FormatIntWithCommas(s.model) + L"（准 " + FormatIntWithCommas(s.approved) +
                   L" / 拒 " + FormatIntWithCommas(s.denied) + L"） · 放行 " + FormatIntWithCommas(s.delegated);
        auto tokens = L"Token " + FormatIntWithCommas(s.tokens) + L"（入 " + FormatIntWithCommas(s.inputTokens) +
                      L" / 缓 " + FormatIntWithCommas(s.cachedTokens) + L" / 出 " + FormatIntWithCommas(s.outputTokens) + L"）";
        auto cost = L"估算 " + FormatUsd(s.costUsd);
        if (s.unknownUsage > 0) cost += L"（+" + FormatIntWithCommas(s.unknownUsage) + L" 未回报）";
        SetWindowTextW(g_app.lblStatsCount, count.c_str());
        SetWindowTextW(g_app.lblStatsSub, sub.c_str());
        SetWindowTextW(g_app.lblStatsTokens, tokens.c_str());
        SetWindowTextW(g_app.lblStatsCost, cost.c_str());
    }
    SetWindowTextW(g_app.lblPricingNote, report.pricingLabel.c_str());
    SetWindowTextW(g_app.lblLogSize, (L"日志占用 " + FormatBytes(report.logsSizeBytes)).c_str());
}

void StartStatsWorker() {
    if (g_app.statsRunning) {
        g_app.statsPending = true;
        return;
    }
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    const auto dates = g_app.period == StatsPeriod::Custom ? g_app.customDates : std::nullopt;
    HWND hwnd = g_app.hwnd;
    g_app.statsRunning = true;
    std::thread([cfgCopy, dates, hwnd]() {
        auto result = std::make_unique<StatsResult>(QueryApprovalStats(cfgCopy, dates));
        if (PostMessageW(hwnd, WM_APP_STATS_DONE, 0, reinterpret_cast<LPARAM>(result.get()))) {
            result.release();
        }
    }).detach();
}

std::optional<bool> RunTakeoverCommand(const PanelConfig& cfg, std::optional<bool> enabled = std::nullopt) {
    const auto dotnet = JoinPath(cfg.pluginDirectory, L"runtime\\dotnet.exe");
    const auto dll = JoinPath(cfg.pluginDirectory, L"scripts\\ag-approval.dll");
    const auto approvalCfg = JoinPath(cfg.pluginDirectory, L"approval.json");
    std::wstring args = L"\"" + dll + L"\" takeover --config \"" + approvalCfg + L"\"";
    if (enabled.has_value()) args += *enabled ? L" --enabled true" : L" --enabled false";
    const auto result = RunHiddenCommand(dotnet, args, cfg.pluginDirectory, 4000);
    JsonValue reply;
    if (!result.started || result.timedOut || result.exitCode != 0 || !JsonValue::Parse(result.stdoutUtf8, reply))
        return std::nullopt;
    const auto* value = reply.Get("takeoverEnabled");
    if (!value || value->kind != JsonValue::Kind::Bool) return std::nullopt;
    return value->boolVal;
}

void QueryCoreSnapshot(const PanelConfig& cfg, RuntimeState& snap, bool runDetect, bool skipLoginCheck) {
    std::wstring approvalCfg = JoinPath(cfg.pluginDirectory, L"approval.json");
    std::wstring pluginJson = JoinPath(cfg.pluginDirectory, L"plugin.json");
    snap.pluginInstalled = FileExists(approvalCfg) && FileExists(pluginJson);
    snap.takeoverEnabled = snap.pluginInstalled ? RunTakeoverCommand(cfg) : std::nullopt;

    if (snap.pluginInstalled) {
        std::string pjRaw;
        if (ReadFileUtf8(pluginJson, pjRaw)) {
            JsonValue pj;
            if (JsonValue::Parse(pjRaw, pj)) {
                auto v = pj.GetWide("version");
                if (!v.empty()) snap.serviceVersion = v;
            }
        }
        std::string appRaw;
        if (ReadFileUtf8(approvalCfg, appRaw)) {
            JsonValue app;
            if (JsonValue::Parse(appRaw, app)) {
                snap.detailedLogs = app.GetBool("enableDetailedLogs", false);
            }
        }
    }

    std::wstring dotnet = GetDotnetExe(cfg);
    std::wstring dll = GetAssemblyDll(cfg);
    if (!FileExists(dotnet) || !FileExists(dll)) {
        snap.serviceRunning = false;
        snap.serviceDetail = L"缺少内置运行组件";
        return;
    }

    // 1. Service status
    if (snap.pluginInstalled) {
        CommandResult st = RunHiddenCommand(
            dotnet,
            L"\"" + dll + L"\" status --config \"" + approvalCfg + L"\"",
            cfg.pluginDirectory,
            4000);
        JsonValue stJson;
        if (st.started && !st.timedOut && st.exitCode == 0 && JsonValue::Parse(st.stdoutUtf8, stJson)) {
            snap.serviceRunning = stJson.GetString("status") == "running";
            if (auto v = stJson.GetWide("version"); !v.empty()) snap.serviceVersion = v;
            snap.detailedLogs = stJson.GetBool("detailedLogs", snap.detailedLogs);
            snap.serviceBackend = stJson.GetWide("reviewerBackend", L"NativeGuardian");
            snap.serviceDetail = snap.serviceRunning ? L"审批服务运行中" : L"审批服务未运行";
        } else {
            snap.serviceRunning = false;
            snap.serviceDetail = st.timedOut || st.stderrUtf8.starts_with("OperationCanceledException:")
                ? L"审批服务未响应"
                : L"无法读取审批服务状态";
        }
    } else {
        snap.serviceRunning = false;
        snap.serviceDetail = L"插件尚未安装到 Antigravity";
    }

    // 2. Environment discovery
    if (runDetect) {
        std::wstring dArgs = L"\"" + dll + L"\" detect --gemini-root \"" + cfg.geminiRoot + L"\" --data-dir \"" + cfg.dataDirectory + L"\"";
        if (snap.pluginInstalled) dArgs += L" --config \"" + approvalCfg + L"\"";
        if (!cfg.antigravityPath.empty()) dArgs += L" --antigravity \"" + cfg.antigravityPath + L"\"";
        if (skipLoginCheck) dArgs += L" --skip-login-check";
        CommandResult dRes = RunHiddenCommand(dotnet, dArgs, GetDirectoryName(dll), 10000);
        JsonValue dJson;
        if (dRes.started && !dRes.timedOut && dRes.exitCode == 0 && JsonValue::Parse(dRes.stdoutUtf8, dJson)) {
            if (const auto* ag = dJson.Get("antigravity")) {
                snap.agFound = ag->GetBool("found", false);
                snap.agVersion = ag->GetWide("version");
                auto p = ag->GetWide("path");
                if (snap.agFound && !p.empty()) {
                    std::lock_guard<std::mutex> lk(g_app.cfgMutex);
                    g_app.cfg.antigravityPath = p;
                }
            }
            if (!skipLoginCheck) {
                const auto* auth = dJson.Get("nativeAuth");
                snap.guardianAuthStatus = auth ? auth->GetWide("status", L"store_unavailable") : L"store_unavailable";
            }
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            SavePanelConfig(g_app.cfg);
        } else if (!skipLoginCheck) {
            snap.guardianAuthStatus = L"store_unavailable";
        }
    } else {
        snap.agFound = !cfg.antigravityPath.empty() && FileExists(cfg.antigravityPath);
    }
}

void UpdateTrayAppearance() {
    if (!g_app.trayAdded || !g_app.hwnd) return;
    HICON hIcon = g_app.iconGreen;
    std::wstring tip = L"Gravity Steward v" + g_app.state.serviceVersion;
    if (!g_app.state.pluginInstalled || !g_app.state.serviceRunning) {
        hIcon = g_app.iconRed;
        tip += g_app.state.pluginInstalled ? L" · 服务未运行" : L" · 未安装";
    } else if (g_app.state.takeoverEnabled == false) {
        hIcon = g_app.iconAmber;
        tip += L" · 插件接管已关闭";
    } else if (g_app.state.updateAvailable) {
        hIcon = g_app.iconBlue;
        tip += L" · 发现新版本 v" + g_app.state.availableUpdate.version;
    } else if (g_app.state.detailedLogs || g_app.state.guardianAuthStatus != L"credentials_found") {
        hIcon = g_app.iconAmber;
        tip += g_app.state.detailedLogs ? L" · 详细日志已开启" : L" · 请确认 Codex 登录";
    } else {
        tip += L" · 运行正常";
    }

    g_app.nid.hIcon = hIcon;
    wcsncpy_s(g_app.nid.szTip, tip.c_str(), _TRUNCATE);
    g_app.nid.uFlags = NIF_ICON | NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &g_app.nid);
    SendMessageW(g_app.hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(hIcon));
    SendMessageW(g_app.hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(hIcon));
}

void SyncControlsToUi() {
    const auto& s = g_app.state;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }

    SetWindowTextW(g_app.lblStatus, s.serviceDetail.c_str());
    const wchar_t* takeoverText = L"接管状态未知";
    if (g_app.busyTakeover) takeoverText = L"切换中…";
    else if (s.takeoverEnabled.has_value()) takeoverText = *s.takeoverEnabled ? L"插件接管 开" : L"插件接管 关";
    SetWindowTextW(g_app.btnApprovalTakeover, takeoverText);
    EnableWindow(g_app.btnApprovalTakeover, s.pluginInstalled && s.takeoverEnabled.has_value() && !g_app.busyTakeover);
    InvalidateRect(g_app.btnApprovalTakeover, nullptr, FALSE);
    SetWindowTextW(g_app.lblBackend, s.serviceBackend.c_str());
    SetWindowTextW(g_app.btnServiceAction, s.pluginInstalled ? (s.serviceRunning ? L"重启服务" : L"启动服务") : L"安装插件");
    EnableWindow(g_app.btnLaunchAg, !cfgCopy.antigravityPath.empty() && FileExists(cfgCopy.antigravityPath));

    // Update banner
    if (s.updateAvailable) {
        if (s.waitingAntigravityExit) {
            std::wstring txt = L"v" + s.availableUpdate.version + L" 已下载校验，关闭 Antigravity 后自动升级";
            SetWindowTextW(g_app.lblUpdateBanner, txt.c_str());
            SetWindowTextW(g_app.btnUpdateNow, L"重试升级");
        } else if (s.updateDownloaded) {
            std::wstring txt = L"v" + s.availableUpdate.version + L" 已准备就绪";
            SetWindowTextW(g_app.lblUpdateBanner, txt.c_str());
            SetWindowTextW(g_app.btnUpdateNow, L"立即更新");
        } else {
            std::wstring txt = L"发现新版本 v" + s.availableUpdate.version;
            SetWindowTextW(g_app.lblUpdateBanner, txt.c_str());
            SetWindowTextW(g_app.btnUpdateNow, L"下载并更新");
        }
    }

    SyncStatsToUi();

    // Toggles & logs
    SendMessageW(g_app.chkDetailedLogs, BM_SETCHECK, s.detailedLogs ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(g_app.chkDetailedLogs, s.pluginInstalled);
    SetWindowTextW(g_app.lblLogBadge, s.detailedLogs ? L"高写入已开启" : L"精简模式");

    SendMessageW(g_app.chkAutostart, BM_SETCHECK, cfgCopy.autostart ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_app.chkAutoUpdate, BM_SETCHECK, cfgCopy.autoUpdate ? BST_CHECKED : BST_UNCHECKED, 0);

    std::wstring verText = L"面板 v" PANEL_VERSION_WIDE;
    if (s.pluginInstalled && s.serviceVersion != PANEL_VERSION_WIDE) {
        verText += L" · 插件 v" + s.serviceVersion;
    }
    if (!g_app.updateCfg.repository.empty()) {
        verText += L" · 更新源: GitHub";
    }
    SetWindowTextW(g_app.lblVersionInfo, verText.c_str());

    // Environment
    std::wstring agText = cfgCopy.antigravityPath.empty() ? L"未检测到，请手动选择" : cfgCopy.antigravityPath;
    SetWindowTextW(g_app.lblAgTitle, (s.agVersion.empty() ? L"Antigravity" : L"Antigravity · v" + s.agVersion).c_str());
    SetWindowTextW(g_app.lblAgPath, agText.c_str());

    const wchar_t* authText = L"未检测";
    if (s.guardianAuthStatus == L"credentials_found") authText = L"已读取本机凭据";
    else if (s.guardianAuthStatus == L"credentials_missing") authText = L"未找到登录凭据";
    else if (s.guardianAuthStatus == L"store_unavailable") authText = L"无法读取凭据存储";
    SetWindowTextW(g_app.lblGuardianAuth, authText);

    EnableWindow(g_app.btnUninstall, FileExists(JoinPath(cfgCopy.dataDirectory, L"installation.json")));
    UpdateTrayAppearance();
    ResizePanelToContent();
    InvalidateRect(g_app.hwnd, nullptr, FALSE);
}

void PostWorkResult(std::unique_ptr<WorkResult> res) {
    if (g_app.hwnd) {
        PostMessageW(g_app.hwnd, WM_APP_WORK_DONE, 0, reinterpret_cast<LPARAM>(res.release()));
    }
}

void StartRefreshWorker(bool initialStartup, bool runDetect, bool skipLoginCheck) {
    StartStatsWorker();
    if (g_app.busyRefresh.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    RuntimeState baseSnap = g_app.state;

    std::thread([cfgCopy, baseSnap, initialStartup, runDetect, skipLoginCheck]() mutable {
        // On initial startup, ensure approval host if plugin is already installed
        if (initialStartup && FileExists(JoinPath(cfgCopy.pluginDirectory, L"approval.json"))) {
            std::wstring dotnet = GetDotnetExe(cfgCopy);
            std::wstring dll = GetAssemblyDll(cfgCopy);
            std::wstring appCfg = JoinPath(cfgCopy.pluginDirectory, L"approval.json");
            if (FileExists(dotnet) && FileExists(dll)) {
                RunHiddenCommand(dotnet, L"\"" + dll + L"\" ensure --config \"" + appCfg + L"\"", cfgCopy.pluginDirectory, 15000);
            }
        }
        QueryCoreSnapshot(cfgCopy, baseSnap, runDetect, skipLoginCheck);
        auto res = std::make_unique<WorkResult>();
        res->kind = initialStartup ? WorkKind::InitialRefresh : (runDetect ? WorkKind::DetectEnv : WorkKind::RefreshAll);
        res->ok = true;
        res->snapshot = std::move(baseSnap);
        g_app.busyRefresh = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartCheckUpdateWorker(bool allowAutoApply) {
    if (g_app.busyUpdate.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    UpdateConfig updCopy = g_app.updateCfg;
    RuntimeState baseSnap = g_app.state;
    std::wstring currentVer = PANEL_VERSION_WIDE;
    if (CompareSemVer(baseSnap.serviceVersion, currentVer) > 0) {
        currentVer = baseSnap.serviceVersion;
    }
    bool installed = baseSnap.pluginInstalled;

    std::thread([cfgCopy, updCopy, baseSnap, currentVer, allowAutoApply, installed]() mutable {
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::CheckAndMaybeUpdate;
        res->snapshot = std::move(baseSnap);
        res->snapshot.updateChecked = true;

        UpdateCheckResult check = CheckForUpdate(updCopy, currentVer);
        if (!check.ok) {
            res->ok = false;
            res->message = check.error;
            g_app.busyUpdate = false;
            PostWorkResult(std::move(res));
            return;
        }

        res->ok = true;
        res->snapshot.updateAvailable = check.hasUpdate;
        res->snapshot.availableUpdate = check.manifest;
        if (!check.hasUpdate) {
            res->message = L"当前已是最新版本 (v" + currentVer + L")";
            g_app.busyUpdate = false;
            PostWorkResult(std::move(res));
            return;
        }

        if (allowAutoApply && cfgCopy.autoUpdate && installed) {
            std::wstring zipPath;
            std::wstring dlErr;
            std::wstring stagingDir = JoinPath(cfgCopy.dataDirectory, L"updates");
            if (DownloadAndVerifyUpdate(updCopy, check.manifest, stagingDir, zipPath, dlErr)) {
                res->snapshot.updateDownloaded = true;
                res->snapshot.downloadedZipPath = zipPath;
                if (!cfgCopy.antigravityPath.empty() && IsProcessRunningByPath(cfgCopy.antigravityPath)) {
                    res->snapshot.waitingAntigravityExit = true;
                    res->message = L"新版本已下载，等待 Antigravity 关闭后自动更新。";
                } else {
                    res->triggerImmediateApply = true;
                }
            } else {
                res->ok = false;
                res->message = dlErr;
            }
        }
        g_app.busyUpdate = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartDownloadAndApplyWorker() {
    if (g_app.busyUpdate.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    UpdateConfig updCopy = g_app.updateCfg;
    RuntimeState snapCopy = g_app.state;

    std::thread([cfgCopy, updCopy, snapCopy]() mutable {
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::DownloadUpdate;
        res->snapshot = snapCopy;

        if (!snapCopy.pluginInstalled) {
            res->ok = false;
            res->message = L"请先安装并启用插件，然后再执行在线更新。";
            g_app.busyUpdate = false;
            PostWorkResult(std::move(res));
            return;
        }

        std::wstring zipPath = snapCopy.downloadedZipPath;
        if (zipPath.empty() || !FileExists(zipPath)) {
            std::wstring dlErr;
            if (!DownloadAndVerifyUpdate(updCopy, snapCopy.availableUpdate, JoinPath(cfgCopy.dataDirectory, L"updates"), zipPath, dlErr)) {
                res->ok = false;
                res->message = dlErr;
                g_app.busyUpdate = false;
                PostWorkResult(std::move(res));
                return;
            }
        }

        res->ok = true;
        res->snapshot.updateDownloaded = true;
        res->snapshot.downloadedZipPath = zipPath;
        if (!cfgCopy.antigravityPath.empty() && IsProcessRunningByPath(cfgCopy.antigravityPath)) {
            res->snapshot.waitingAntigravityExit = true;
            res->message = L"Antigravity 正在运行，更新包已下载完成；关闭 Antigravity 后将自动安装。";
        } else {
            res->triggerImmediateApply = true;
        }
        g_app.busyUpdate = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void ExecutePendingUpdateAndExit() {
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    std::wstring applyScript = GetApplyScriptPath(cfgCopy);
    std::wstring err;
    if (LaunchApplyUpdate(
            g_app.state.downloadedZipPath,
            g_app.state.availableUpdate.sha256,
            applyScript,
            cfgCopy.pluginDirectory,
            cfgCopy.dataDirectory,
            true,
            err)) {
        if (g_app.trayAdded) {
            Shell_NotifyIconW(NIM_DELETE, &g_app.nid);
            g_app.trayAdded = false;
        }
        PostQuitMessage(0);
    } else {
        MessageBoxW(g_app.hwnd, err.c_str(), L"启动更新器失败", MB_OK | MB_ICONERROR);
    }
}

void StartTakeoverWorker() {
    if (!g_app.state.takeoverEnabled.has_value() || g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    const bool enable = !*g_app.state.takeoverEnabled;
    g_app.busyTakeover = true;
    SyncControlsToUi();
    std::thread([cfgCopy, enable]() {
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::ToggleApprovalTakeover;
        res->snapshot.takeoverEnabled = RunTakeoverCommand(cfgCopy, enable);
        res->ok = res->snapshot.takeoverEnabled == enable;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartDetailedLogsWorker(bool enable) {
    if (g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    std::thread([cfgCopy, enable]() {
        std::wstring dotnet = GetDotnetExe(cfgCopy);
        std::wstring dll = GetAssemblyDll(cfgCopy);
        std::wstring appCfg = JoinPath(cfgCopy.pluginDirectory, L"approval.json");
        std::wstring args = L"\"" + dll + L"\" set-logging --config \"" + appCfg + L"\" --enabled " + (enable ? L"true" : L"false");
        CommandResult cr = RunHiddenCommand(dotnet, args, cfgCopy.pluginDirectory, 8000);

        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::ToggleDetailedLogs;
        res->targetDetailedLogs = enable;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0;
        if (!res->ok) {
            res->message = L"切换详细日志失败: " + Utf8ToWide(cr.stderrUtf8);
        }
        g_app.busyAction = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartServiceWorker() {
    if (g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    RuntimeState snapBase = g_app.state;
    bool alreadyRunning = snapBase.serviceRunning;
    std::thread([cfgCopy, snapBase, alreadyRunning]() mutable {
        std::wstring dotnet = GetDotnetExe(cfgCopy);
        std::wstring dll = GetAssemblyDll(cfgCopy);
        std::wstring appCfg = JoinPath(cfgCopy.pluginDirectory, L"approval.json");
        if (alreadyRunning) {
            RunHiddenCommand(dotnet, L"\"" + dll + L"\" stop --config \"" + appCfg + L"\"", cfgCopy.pluginDirectory, 6000);
            Sleep(300);
        }
        CommandResult cr = RunHiddenCommand(dotnet, L"\"" + dll + L"\" ensure --config \"" + appCfg + L"\"", cfgCopy.pluginDirectory, 15000);
        QueryCoreSnapshot(cfgCopy, snapBase, false, true);
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::ServiceEnsure;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0 && snapBase.serviceRunning;
        res->snapshot = std::move(snapBase);
        if (!res->ok) res->message = L"审批服务启动失败: " + Utf8ToWide(cr.stderrUtf8);
        g_app.busyAction = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartCompactLogsWorker() {
    if (g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    RuntimeState snapBase = g_app.state;
    std::thread([cfgCopy, snapBase]() mutable {
        std::wstring dotnet = GetDotnetExe(cfgCopy);
        std::wstring dll = GetAssemblyDll(cfgCopy);
        CommandResult cr = RunHiddenCommand(dotnet, L"\"" + dll + L"\" compact-logs --data-dir \"" + cfgCopy.dataDirectory + L"\"", GetDirectoryName(dll), 20000);
        QueryCoreSnapshot(cfgCopy, snapBase, false, true);
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::CompactLogs;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0;
        res->snapshot = std::move(snapBase);
        JsonValue cj;
        if (res->ok && JsonValue::Parse(cr.stdoutUtf8, cj)) {
            uint64_t saved = static_cast<uint64_t>(std::max<int64_t>(0, cj.GetInt64("savedBytes", 0)));
            int dropped = static_cast<int>(cj.GetInt64("droppedVerboseDumps", 0));
            res->message = L"日志压缩完成：清理了 " + std::to_wstring(dropped) + L" 条冗余详情，释放空间 " + FormatBytes(saved) + L"。";
        } else {
            res->message = L"压缩日志失败: " + Utf8ToWide(cr.stderrUtf8);
        }
        g_app.busyAction = false;
        PostWorkResult(std::move(res));
    }).detach();
}

std::wstring GetLifecycleScriptPath(const PanelConfig& cfg, const std::wstring& exeDir, const wchar_t* name) {
    const auto relative = JoinPath(L"scripts", name);
    // Use the script shipped with the running panel when a portable package is opened over an older installation.
    for (const auto& root : {exeDir, GetDirectoryName(exeDir), cfg.bundleDirectory, cfg.pluginDirectory}) {
        const auto script = JoinPath(root, relative);
        if (FileExists(script)) return script;
    }
    return {};
}

void StartInstallScriptWorker() {
    if (g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    RuntimeState snapBase = g_app.state;
    std::wstring exeDir = GetDirectoryName(GetExecutablePath());
    std::thread([cfgCopy, snapBase, exeDir]() mutable {
        wchar_t sysDir[MAX_PATH]{};
        GetSystemDirectoryW(sysDir, static_cast<DWORD>(std::size(sysDir)));
        std::wstring psExe = JoinPath(sysDir, L"WindowsPowerShell\\v1.0\\powershell.exe");

        std::wstring script = GetLifecycleScriptPath(cfgCopy, exeDir, L"Install.ps1");
        std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -GeminiRoot \"" + cfgCopy.geminiRoot +
                            L"\" -DataDirectory \"" + cfgCopy.dataDirectory + L"\"";
        if (!cfgCopy.antigravityPath.empty()) args += L" -AntigravityPath \"" + cfgCopy.antigravityPath + L"\"";

        CommandResult cr = RunHiddenCommand(psExe, args, GetDirectoryName(script), 45000);
        QueryCoreSnapshot(cfgCopy, snapBase, false, true);
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::InstallOrRepair;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0;
        res->snapshot = std::move(snapBase);
        if (res->ok) {
            res->message = L"插件已成功安装并启用审批服务。";
        } else {
            res->message = L"安装失败：\n" + Utf8ToWide(cr.stderrUtf8 + "\n" + cr.stdoutUtf8);
        }
        g_app.busyAction = false;
        PostWorkResult(std::move(res));
    }).detach();
}

void StartUninstallAndExit(HWND hwnd) {
    if (g_app.busyAction || g_app.busyUpdate || g_app.busyRefresh || g_app.statsRunning) {
        MessageBoxW(hwnd, L"请等当前操作结束后再卸载。", L"完整卸载", MB_OK | MB_ICONINFORMATION);
        return;
    }
    PanelConfig cfg;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfg = g_app.cfg;
    }
    if (IsProcessRunningByPath(cfg.antigravityPath)) {
        MessageBoxW(hwnd, L"请先完全退出 Antigravity，再卸载。", L"完整卸载", MB_OK | MB_ICONINFORMATION);
        return;
    }
    const std::wstring exePath = GetExecutablePath();
    const auto script = GetLifecycleScriptPath(cfg, GetDirectoryName(exePath), L"Uninstall.ps1");
    if (script.empty()) {
        MessageBoxW(hwnd, L"找不到卸载脚本。请从完整解压的安装包重新打开面板。", L"完整卸载", MB_OK | MB_ICONERROR);
        return;
    }
    g_app.uninstallPromptOpen = true;
    const int answer = MessageBoxW(hwnd,
        L"面板将退出。卸载会移除已安装的插件，并永久删除本地审批日志、统计、设置、项目长期授权和备份。\n\n确认完整卸载吗？",
        L"完整卸载 Gravity Steward", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
    g_app.uninstallPromptOpen = false;
    if (answer != IDYES) return;

    wchar_t systemDir[MAX_PATH]{};
    GetSystemDirectoryW(systemDir, static_cast<DWORD>(std::size(systemDir)));
    std::wstring powershell = JoinPath(systemDir, L"WindowsPowerShell\\v1.0\\powershell.exe");
    std::wstring args = L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
        L"\" -DataDirectory \"" + cfg.dataDirectory + L"\" -PurgeData -WaitPid " + std::to_wstring(GetCurrentProcessId()) +
        L" -PanelExecutablePath \"" + exePath + L"\" -ShowResult";
    if (!LaunchDetached(powershell, args, systemDir, true)) {
        MessageBoxW(hwnd, L"无法启动卸载程序。", L"完整卸载", MB_OK | MB_ICONERROR);
        return;
    }
    DestroyWindow(hwnd);
}

void LaunchAntigravityAction() {
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    if (cfgCopy.antigravityPath.empty() || !FileExists(cfgCopy.antigravityPath)) {
        MessageBoxW(g_app.hwnd, L"未找到 Antigravity.exe，请先点击下方“更改...”指定路径。", L"启动 Antigravity", MB_OK | MB_ICONINFORMATION);
        return;
    }
    if (g_app.busyAction.exchange(true)) return;
    const bool ensureService = g_app.state.pluginInstalled && !g_app.state.serviceRunning;
    std::thread([cfgCopy, ensureService]() {
        if (ensureService) {
            const auto dotnet = GetDotnetExe(cfgCopy);
            const auto dll = GetAssemblyDll(cfgCopy);
            const auto appCfg = JoinPath(cfgCopy.pluginDirectory, L"approval.json");
            RunHiddenCommand(dotnet, L"\"" + dll + L"\" ensure --config \"" + appCfg + L"\"", cfgCopy.pluginDirectory, 8000);
        }
        auto result = std::make_unique<WorkResult>();
        result->kind = WorkKind::LaunchAntigravity;
        result->ok = LaunchDetached(cfgCopy.antigravityPath, L"", GetDirectoryName(cfgCopy.antigravityPath), false);
        g_app.busyAction = false;
        PostWorkResult(std::move(result));
    }).detach();
}

void ShowPanelWindow() {
    if (!g_app.hwnd) return;
    ShowWindow(g_app.hwnd, SW_SHOWNORMAL);
    SetForegroundWindow(g_app.hwnd);
    StartRefreshWorker(false, false, true);
}

void ShowTrayContextMenu() {
    POINT pt{};
    GetCursorPos(&pt);
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, ID_MENU_OPEN, L"打开控制面板");
    AppendMenuW(menu, MF_STRING, ID_MENU_LAUNCH_AG, L"启动 Antigravity");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, ID_MENU_REFRESH, L"刷新状态与统计");
    AppendMenuW(menu, MF_STRING, ID_MENU_CHECK_UPDATE, L"检查更新");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, ID_MENU_EXIT, L"退出托盘");
    SetMenuDefaultItem(menu, ID_MENU_OPEN, FALSE);
    SetForegroundWindow(g_app.hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RIGHTALIGN, pt.x, pt.y, 0, g_app.hwnd, nullptr);
    PostMessageW(g_app.hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

void CreateFonts(HWND hwnd) {
    auto font = [&](int size, int weight) {
        return CreateFontW(-Scale(hwnd, size), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
    };
    g_app.fontTitle = font(23, FW_SEMIBOLD);
    g_app.fontHeading = font(16, FW_SEMIBOLD);
    g_app.fontBold = font(13, FW_SEMIBOLD);
    g_app.fontRegular = font(13, FW_NORMAL);
    g_app.fontSmall = font(12, FW_NORMAL);
    g_app.fontMetric = font(29, FW_BOLD);
}

void CreateChildControls(HWND hwnd) {
    CreateFonts(hwnd);
    auto label = [&](const wchar_t* txt, DWORD style = SS_LEFT) {
        return CreateWindowExW(0, L"STATIC", txt, WS_CHILD | SS_NOPREFIX | style,
                               0, 0, 0, 0, hwnd, nullptr, g_app.hInst, nullptr);
    };
    auto button = [&](const wchar_t* txt, int id, DWORD style = BS_OWNERDRAW) {
        return CreateWindowExW(0, L"BUTTON", txt, WS_CHILD | WS_TABSTOP | style,
                               0, 0, 0, 0, hwnd, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g_app.hInst, nullptr);
    };

    g_app.lblTitle = label(L"自动审批");
    g_app.lblStatus = label(L"", SS_ENDELLIPSIS);
    g_app.btnApprovalTakeover = button(L"接管状态未知", ID_BTN_APPROVAL_TAKEOVER);
    g_app.lblBackend = label(L"", SS_ENDELLIPSIS);
    g_app.btnServiceAction = button(L"启动服务", ID_BTN_SERVICE_ACTION);
    g_app.btnRefresh = button(L"刷新", ID_BTN_REFRESH);
    g_app.btnLaunchAg = button(L"启动 Antigravity", ID_BTN_LAUNCH_AG);
    g_app.lblUpdateBanner = label(L"");
    g_app.btnUpdateNow = button(L"立即更新", ID_BTN_UPDATE_NOW);
    g_app.lblStatsTitle = label(L"今日审批");
    g_app.btnStatsDate = button(L"选择审批日期", ID_BTN_STATS_DATE);
    g_app.lblStatsCount = label(L"");
    g_app.lblStatsSub = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsTokens = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsCost = label(L"", SS_ENDELLIPSIS);
    g_app.lblPricingTitle = label(L"计价基准");
    g_app.lblPricingNote = label(L"", SS_ENDELLIPSIS);
    g_app.btnOpenPricing = button(L"修改单价", ID_BTN_OPEN_PRICING);

    g_app.lblAppsTitle = label(L"应用与插件");
    g_app.lblAgTitle = label(L"Antigravity");
    g_app.lblAgPath = label(L"", SS_PATHELLIPSIS);
    g_app.btnBrowseAg = button(L"更改…", ID_BTN_BROWSE_AG);
    g_app.lblGuardianTitle = label(L"Guardian 登录");
    g_app.lblGuardianAuth = label(L"", SS_ENDELLIPSIS);
    g_app.btnDetectEnv = button(L"检测", ID_BTN_DETECT_ENV);
    g_app.btnInstallRepair = button(L"安装 / 修复插件", ID_BTN_INSTALL_REPAIR);
    g_app.btnUninstall = button(L"完整卸载", ID_BTN_UNINSTALL);

    g_app.btnPreferences = button(L"偏好设置", ID_BTN_PREFERENCES);
    g_app.chkDetailedLogs = button(L"详细调试日志（仅 Debug 时开启）", ID_CHK_DETAILED_LOGS, BS_CHECKBOX);
    g_app.lblLogBadge = label(L"", SS_RIGHT);
    g_app.lblLogSize = label(L"");
    g_app.btnOpenLogs = button(L"打开日志", ID_BTN_OPEN_LOGS);
    g_app.btnCompactLogs = button(L"压缩清理", ID_BTN_COMPACT_LOGS);
    g_app.chkAutostart = button(L"开机自启（最小化到托盘）", ID_CHK_AUTOSTART, BS_CHECKBOX);
    g_app.chkAutoUpdate = button(L"启动时自动更新", ID_CHK_AUTO_UPDATE, BS_CHECKBOX);
    g_app.lblVersionInfo = label(L"");
    g_app.btnCheckUpdate = button(L"检查更新", ID_BTN_CHECK_UPDATE);
}

struct PanelLayout {
    int stats = 150 + (g_app.state.updateAvailable ? kBannerSpace : 0);
    int pricing = stats + 148;
    int apps = pricing + 60;
    int prefs = apps + 170;
    int height = prefs + 53 + (g_app.preferencesOpen ? kPreferencesSpace : 0);
};

void PositionControls(const PanelLayout& layout) {
    auto& a = g_app;
    auto S = [&](int dip) { return Scale(a.hwnd, dip); };
    auto place = [&](HWND control, HFONT font, int x, int y, int w, int h, bool show = true) {
        if (reinterpret_cast<HFONT>(SendMessageW(control, WM_GETFONT, 0, 0)) != font)
            SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
        SetWindowPos(control, nullptr, S(x), S(y) - a.scrollY, S(w), S(h),
                     SWP_NOZORDER | SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    };
    place(a.lblTitle, a.fontTitle, 55, 13, 320, 34);
    place(a.lblStatus, a.fontBold, 50, 68, a.state.serviceRunning ? 106 : a.state.pluginInstalled ? 150 : 336, 20);
    place(a.btnApprovalTakeover, a.fontSmall, a.state.serviceRunning ? 158 : 204, 64, 123, 26, a.state.pluginInstalled);
    place(a.lblBackend, a.fontSmall, 293, 69, 93, 19, a.state.serviceRunning && !a.state.serviceBackend.empty());
    place(a.btnServiceAction, a.fontRegular, 28, 97, 91, 31);
    place(a.btnRefresh, a.fontRegular, 127, 97, 68, 31);
    place(a.btnLaunchAg, a.fontBold, 203, 97, 183, 31);
    place(a.lblUpdateBanner, a.fontSmall, 28, 154, 253, 32, a.state.updateAvailable);
    place(a.btnUpdateNow, a.fontRegular, 289, 156, 97, 28, a.state.updateAvailable);

    const int stats = layout.stats;
    place(a.lblStatsTitle, a.fontHeading, 28, stats + 11, 310, 24);
    place(a.btnStatsDate, a.fontRegular, 351, stats + 9, 35, 30);
    place(a.lblStatsCount, a.fontMetric, 28, stats + 35, 310, 38);
    place(a.lblStatsSub, a.fontSmall, 28, stats + 76, 358, 19);
    place(a.lblStatsTokens, a.fontSmall, 28, stats + 96, 358, 19);
    place(a.lblStatsCost, a.fontBold, 28, stats + 115, 358, 19);

    const int pricing = layout.pricing;
    place(a.lblPricingTitle, a.fontBold, 28, pricing + 7, 255, 18);
    place(a.lblPricingNote, a.fontSmall, 28, pricing + 26, 260, 18);
    place(a.btnOpenPricing, a.fontRegular, 298, pricing + 11, 88, 28);

    const int apps = layout.apps;
    place(a.lblAppsTitle, a.fontHeading, 28, apps + 7, 340, 23);
    place(a.lblAgTitle, a.fontBold, 54, apps + 40, 246, 17);
    place(a.lblAgPath, a.fontSmall, 54, apps + 58, 253, 17);
    place(a.btnBrowseAg, a.fontRegular, 317, apps + 42, 69, 27);
    place(a.lblGuardianTitle, a.fontBold, 54, apps + 82, 253, 17);
    place(a.lblGuardianAuth, a.fontSmall, 54, apps + 100, 253, 17);
    place(a.btnDetectEnv, a.fontRegular, 317, apps + 84, 69, 27);
    place(a.btnInstallRepair, a.fontRegular, 28, apps + 125, 175, 28);
    place(a.btnUninstall, a.fontRegular, 211, apps + 125, 175, 28);

    const int prefs = layout.prefs;
    place(a.btnPreferences, a.fontHeading, 16, prefs, 382, 39);
    const bool expanded = a.preferencesOpen;
    place(a.chkDetailedLogs, a.fontSmall, 28, prefs + 46, 252, 25, expanded);
    place(a.lblLogBadge, a.fontSmall, 280, prefs + 50, 106, 19, expanded);
    place(a.lblLogSize, a.fontSmall, 28, prefs + 80, 184, 19, expanded);
    place(a.btnOpenLogs, a.fontRegular, 219, prefs + 75, 79, 26, expanded);
    place(a.btnCompactLogs, a.fontRegular, 307, prefs + 75, 79, 26, expanded);
    place(a.chkAutostart, a.fontSmall, 28, prefs + 105, 358, 24, expanded);
    place(a.chkAutoUpdate, a.fontSmall, 28, prefs + 132, 358, 24, expanded);
    place(a.lblVersionInfo, a.fontSmall, 28, prefs + 167, 260, 19, expanded);
    place(a.btnCheckUpdate, a.fontRegular, 298, prefs + 162, 88, 26, expanded);

    InvalidateRect(a.hwnd, nullptr, FALSE);
}

void SetPanelScroll(int proposed) {
    PanelLayout layout;
    RECT client{};
    GetClientRect(g_app.hwnd, &client);
    int total = Scale(g_app.hwnd, layout.height);
    g_app.scrollY = std::clamp(proposed, 0, std::max(0, total - static_cast<int>(client.bottom)));
    SCROLLINFO info{sizeof(info), SIF_RANGE | SIF_PAGE | SIF_POS, 0, total - 1,
                    static_cast<UINT>(client.bottom), g_app.scrollY, 0};
    SetScrollInfo(g_app.hwnd, SB_VERT, &info, TRUE);
    PositionControls(layout);
}

void ScrollFocusIntoView(HWND hwnd) {
    auto focus = GetFocus();
    if (!focus || !IsChild(hwnd, focus) || !(GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VSCROLL)) return;

    RECT bounds{}, client{};
    GetWindowRect(focus, &bounds);
    MapWindowPoints(HWND_DESKTOP, hwnd, reinterpret_cast<POINT*>(&bounds), 2);
    GetClientRect(hwnd, &client);
    const int padding = Scale(hwnd, 8);
    if (bounds.top < padding) SetPanelScroll(g_app.scrollY + bounds.top - padding);
    else if (bounds.bottom > client.bottom - padding) SetPanelScroll(g_app.scrollY + bounds.bottom - client.bottom + padding);
}

void ResizePanelToContent() {
    auto hwnd = g_app.hwnd;
    auto dpi = GetDpiForWindow(hwnd);
    PanelLayout layout;
    RECT frame{0, 0, Scale(hwnd, kPanelWidth), Scale(hwnd, layout.height)};
    AdjustWindowRectExForDpi(&frame, kPanelStyle, FALSE, kPanelExStyle, dpi);
    RECT bounds{};
    GetWindowRect(hwnd, &bounds);
    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    const RECT& work = monitor.rcWork;
    LONG width = frame.right - frame.left;
    LONG height = frame.bottom - frame.top;
    const bool scroll = height > work.bottom - work.top;
    if (scroll) {
        height = work.bottom - work.top;
        width += GetSystemMetricsForDpi(SM_CXVSCROLL, dpi);
    }
    LONG x = std::clamp(bounds.left, work.left, std::max(work.left, work.right - width));
    LONG y = std::clamp(bounds.top, work.top, work.bottom - height);
    if (bounds.left != x || bounds.top != y || bounds.right != x + width || bounds.bottom != y + height)
        SetWindowPos(hwnd, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowScrollBar(hwnd, SB_VERT, scroll);
    SetPanelScroll(g_app.scrollY);
}

void FillRoundedRect(HDC hdc, RECT r, int radius, COLORREF fill, COLORREF border) {
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, border);
    HGDIOBJ oldBrush = SelectObject(hdc, brush);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius, radius);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void DrawOwnerButton(const DRAWITEMSTRUCT& item) {
    HDC hdc = item.hDC;
    RECT rc = item.rcItem;
    auto S = [&](int dp) { return Scale(g_app.hwnd, dp); };
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool takeover = item.CtlID == ID_BTN_APPROVAL_TAKEOVER;
    const bool primary = item.CtlID == ID_BTN_LAUNCH_AG;
    const bool disclosure = item.CtlID == ID_BTN_PREFERENCES;
    const bool danger = item.CtlID == ID_BTN_UNINSTALL;
    HBRUSH backdrop = disclosure ? g_app.brushBg : item.CtlID == ID_BTN_UPDATE_NOW ? g_app.brushBanner : g_app.brushCard;
    FillRect(hdc, &rc, backdrop);
    COLORREF fill = pressed ? RGB(235, 239, 246) : RGB(255, 255, 255);
    COLORREF border = RGB(209, 217, 227);
    COLORREF ink = disabled ? RGB(120, 130, 145) : danger ? kRed : kText;
    if (primary) {
        fill = disabled ? RGB(229, 235, 244) : pressed ? RGB(11, 84, 192) : kBlue;
        border = fill;
        if (!disabled) ink = RGB(255, 255, 255);
    }
    const int cy = (rc.top + rc.bottom) / 2;
    if (takeover) {
        const bool enabled = g_app.state.takeoverEnabled.value_or(false);
        const RECT track{rc.left + S(4), cy - S(8), rc.left + S(38), cy + S(8)};
        const COLORREF trackColor = disabled ? RGB(191, 199, 210) : enabled ? kBlue : kSecondary;
        FillRoundedRect(hdc, track, S(16), trackColor, trackColor);
        const int thumb = enabled ? track.right - S(8) : track.left + S(8);
        const RECT knob{thumb - S(5), cy - S(5), thumb + S(5), cy + S(5)};
        constexpr COLORREF white = RGB(255, 255, 255);
        FillRoundedRect(hdc, knob, S(10), white, white);
    } else {
        FillRoundedRect(hdc, rc, S(disclosure ? 18 : 12), fill, border);
    }
    if (item.CtlID == ID_BTN_STATS_DATE) {
        const int cx = (rc.left + rc.right) / 2;
        HPEN pen = CreatePen(PS_SOLID, S(1), ink);
        auto oldPen = SelectObject(hdc, pen);
        auto oldBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
        RoundRect(hdc, cx - S(7), cy - S(6), cx + S(8), cy + S(8), S(4), S(4));
        MoveToEx(hdc, cx - S(7), cy - S(2), nullptr);
        LineTo(hdc, cx + S(8), cy - S(2));
        for (int offset : {-3, 3}) {
            MoveToEx(hdc, cx + S(offset), cy - S(8), nullptr);
            LineTo(hdc, cx + S(offset), cy - S(4));
        }
        SelectObject(hdc, oldBrush);
        SelectObject(hdc, oldPen);
        DeleteObject(pen);
    } else {
        wchar_t text[96]{};
        GetWindowTextW(item.hwndItem, text, static_cast<int>(std::size(text)));
        auto oldFont = SelectObject(hdc, reinterpret_cast<HFONT>(SendMessageW(item.hwndItem, WM_GETFONT, 0, 0)));
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, ink);
        RECT textRect = rc;
        if (disclosure) textRect.left += S(12);
        if (takeover) textRect.left += S(44);
        DrawTextW(hdc, text, -1, &textRect, (disclosure || takeover ? DT_LEFT : DT_CENTER) | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(hdc, oldFont);
        if (disclosure) {
            int x = rc.right - S(20);
            HPEN pen = CreatePen(PS_SOLID, S(2), kSecondary);
            auto oldPen = SelectObject(hdc, pen);
            if (g_app.preferencesOpen) {
                POINT arrow[] = {{x - S(4), cy - S(2)}, {x, cy + S(2)}, {x + S(4), cy - S(2)}};
                Polyline(hdc, arrow, static_cast<int>(std::size(arrow)));
            } else {
                POINT arrow[] = {{x - S(2), cy - S(4)}, {x + S(2), cy}, {x - S(2), cy + S(4)}};
                Polyline(hdc, arrow, static_cast<int>(std::size(arrow)));
            }
            SelectObject(hdc, oldPen);
            DeleteObject(pen);
        }
    }
    if ((item.itemState & ODS_FOCUS) && !(item.itemState & ODS_NOFOCUSRECT)) {
        InflateRect(&rc, -S(4), -S(4));
        DrawFocusRect(hdc, &rc);
    }
}

void PaintWindowCards(HWND hwnd, HDC hdc) {
    RECT client{};
    GetClientRect(hwnd, &client);
    FillRect(hdc, &client, g_app.brushBg);

    auto S = [&](int dp) { return Scale(hwnd, dp); };
    auto Y = [&](int dp) { return S(dp) - g_app.scrollY; };
    constexpr COLORREF white = RGB(255, 255, 255);
    constexpr COLORREF border = RGB(220, 226, 234);
    auto card = [&](int y, int h, COLORREF fill = RGB(255, 255, 255)) {
        FillRoundedRect(hdc, {S(16), Y(y), S(398), Y(y + h)}, S(18), fill, border);
    };
    PanelLayout layout;
    card(56, 84);
    if (g_app.state.updateAvailable) card(150, 40, RGB(232, 242, 255));
    card(layout.stats, 138);
    card(layout.pricing, 50);
    card(layout.apps, 160);
    if (g_app.preferencesOpen) card(layout.prefs + 42, kPreferencesSpace - 3);

    HBRUSH shield = CreateSolidBrush(kBlue);
    auto oldBrush = SelectObject(hdc, shield);
    auto oldPen = SelectObject(hdc, GetStockObject(NULL_PEN));
    POINT shieldOutline[] = {{S(33), Y(14)}, {S(47), Y(20)}, {S(47), Y(30)}, {S(44), Y(37)},
                             {S(33), Y(45)}, {S(22), Y(37)}, {S(19), Y(30)}, {S(19), Y(20)}};
    Polygon(hdc, shieldOutline, static_cast<int>(std::size(shieldOutline)));
    HBRUSH status = CreateSolidBrush(g_app.state.serviceRunning ? kGreen : kSecondary);
    SelectObject(hdc, status);
    Ellipse(hdc, S(29), Y(72), S(39), Y(82));
    HPEN check = CreatePen(PS_SOLID, S(2), white);
    SelectObject(hdc, check);
    POINT tick[] = {{S(26), Y(29)}, {S(31), Y(34)}, {S(40), Y(25)}};
    Polyline(hdc, tick, static_cast<int>(std::size(tick)));

    HPEN divider = CreatePen(PS_SOLID, 1, border);
    SelectObject(hdc, divider);
    if (g_app.state.serviceRunning && !g_app.state.serviceBackend.empty()) {
        MoveToEx(hdc, S(284), Y(69), nullptr);
        LineTo(hdc, S(284), Y(85));
    }
    for (int row : {34, 76, 118}) {
        MoveToEx(hdc, S(28), Y(layout.apps + row), nullptr);
        LineTo(hdc, S(386), Y(layout.apps + row));
    }
    HPEN icon = CreatePen(PS_SOLID, S(1), kSecondary);
    SelectObject(hdc, icon);
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    int y = layout.apps;
    RoundRect(hdc, S(29), Y(y + 47), S(46), Y(y + 59), S(4), S(4));
    MoveToEx(hdc, S(37), Y(y + 59), nullptr);
    LineTo(hdc, S(37), Y(y + 63));
    MoveToEx(hdc, S(33), Y(y + 63), nullptr);
    LineTo(hdc, S(42), Y(y + 63));
    RoundRect(hdc, S(29), Y(y + 89), S(46), Y(y + 105), S(4), S(4));
    POINT prompt[] = {{S(32), Y(y + 93)}, {S(35), Y(y + 97)}, {S(32), Y(y + 100)}};
    Polyline(hdc, prompt, static_cast<int>(std::size(prompt)));
    MoveToEx(hdc, S(38), Y(y + 100), nullptr);
    LineTo(hdc, S(43), Y(y + 100));

    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(shield);
    DeleteObject(status);
    DeleteObject(check);
    DeleteObject(divider);
    DeleteObject(icon);
}

std::wstring IsoDate(const SYSTEMTIME& time) {
    wchar_t text[11]{};
    swprintf_s(text, L"%04u-%02u-%02u", static_cast<unsigned>(time.wYear),
               static_cast<unsigned>(time.wMonth), static_cast<unsigned>(time.wDay));
    return text;
}

INT_PTR CALLBACK DateRangeDialog(HWND dlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_INITDIALOG) {
        auto* dates = reinterpret_cast<DateRange*>(lParam);
        SetWindowLongPtrW(dlg, DWLP_USER, lParam);
        SYSTEMTIME limits[2]{};
        GetLocalTime(&limits[1]);
        for (int id : {ID_DATE_FROM, ID_DATE_TO}) {
            HWND picker = GetDlgItem(dlg, id);
            DateTime_SetFormat(picker, L"yyyy-MM-dd");
            DateTime_SetRange(picker, GDTR_MAX, limits);
            SYSTEMTIME value = limits[1];
            const auto& date = id == ID_DATE_FROM ? dates->from : dates->to;
            swscanf_s(date.c_str(), L"%hu-%hu-%hu", &value.wYear, &value.wMonth, &value.wDay);
            DateTime_SetSystemtime(picker, GDT_VALID, &value);
        }
        return TRUE;
    }
    if (msg != WM_COMMAND) return FALSE;
    if (LOWORD(wParam) == IDCANCEL) {
        EndDialog(dlg, IDCANCEL);
        return TRUE;
    }
    if (LOWORD(wParam) != IDOK) return FALSE;
    SYSTEMTIME from{}, to{};
    if (DateTime_GetSystemtime(GetDlgItem(dlg, ID_DATE_FROM), &from) != GDT_VALID ||
        DateTime_GetSystemtime(GetDlgItem(dlg, ID_DATE_TO), &to) != GDT_VALID)
        return TRUE;
    DateRange chosen{IsoDate(from), IsoDate(to)};
    if (chosen.to < chosen.from) {
        MessageBoxW(dlg, L"结束日期需要在开始日期当天或之后。", L"请检查日期", MB_OK | MB_ICONINFORMATION);
        SetFocus(GetDlgItem(dlg, ID_DATE_TO));
        return TRUE;
    }
    *reinterpret_cast<DateRange*>(GetWindowLongPtrW(dlg, DWLP_USER)) = std::move(chosen);
    EndDialog(dlg, IDOK);
    return TRUE;
}

void ShowStatsPeriodMenu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    AppendMenuW(menu, MF_STRING, ID_MENU_STATS_TODAY, L"今天");
    AppendMenuW(menu, MF_STRING, ID_MENU_STATS_WEEK, L"近 7 日");
    AppendMenuW(menu, MF_STRING, ID_MENU_STATS_CUSTOM, L"自选日期…");
    UINT selected = ID_MENU_STATS_TODAY;
    if (g_app.period == StatsPeriod::Week) selected = ID_MENU_STATS_WEEK;
    if (g_app.period == StatsPeriod::Custom) selected = ID_MENU_STATS_CUSTOM;
    CheckMenuRadioItem(menu, ID_MENU_STATS_TODAY, ID_MENU_STATS_CUSTOM, selected, MF_BYCOMMAND);
    RECT anchor{};
    GetWindowRect(g_app.btnStatsDate, &anchor);
    UINT command = TrackPopupMenu(menu, TPM_RIGHTALIGN | TPM_TOPALIGN | TPM_RETURNCMD | TPM_NONOTIFY,
                                  anchor.right, anchor.bottom, 0, hwnd, nullptr);
    DestroyMenu(menu);
    switch (command) {
    case ID_MENU_STATS_TODAY:
        g_app.period = StatsPeriod::Today;
        break;
    case ID_MENU_STATS_WEEK:
        g_app.period = StatsPeriod::Week;
        break;
    case ID_MENU_STATS_CUSTOM: {
        SYSTEMTIME now{};
        GetLocalTime(&now);
        auto today = IsoDate(now);
        DateRange dates = g_app.customDates.value_or(DateRange{today, today});
        if (DialogBoxParamW(g_app.hInst, MAKEINTRESOURCEW(IDD_STATS_DATE_RANGE), hwnd,
                            DateRangeDialog, reinterpret_cast<LPARAM>(&dates)) != IDOK)
            return;
        g_app.customDates = std::move(dates);
        g_app.period = StatsPeriod::Custom;
        break;
    }
    default:
        return;
    }
    StartStatsWorker();
    SyncStatsToUi();
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        g_app.hwnd = hwnd;
        BOOL round = kDwmRound;
        DwmSetWindowAttribute(hwnd, kDwmWindowCornerPreference, &round, sizeof(round));
        g_app.brushBg = CreateSolidBrush(RGB(246, 248, 252));
        g_app.brushCard = CreateSolidBrush(RGB(255, 255, 255));
        g_app.brushBanner = CreateSolidBrush(RGB(232, 242, 255));
        g_app.iconGreen = CreateShieldBadgeIcon(RGB(22, 163, 74), 32);
        g_app.iconBlue = CreateShieldBadgeIcon(RGB(37, 99, 235), 32);
        g_app.iconAmber = CreateShieldBadgeIcon(RGB(217, 119, 6), 32);
        g_app.iconRed = CreateShieldBadgeIcon(RGB(220, 38, 38), 32);

        CreateChildControls(hwnd);

        g_app.nid.cbSize = sizeof(g_app.nid);
        g_app.nid.hWnd = hwnd;
        g_app.nid.uID = IDI_APP_ICON;
        g_app.nid.uCallbackMessage = WM_APP_TRAY;
        g_app.nid.hIcon = g_app.iconGreen;
        g_app.nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        wcsncpy_s(g_app.nid.szTip, L"Gravity Steward", _TRUNCATE);
        g_app.trayAdded = Shell_NotifyIconW(NIM_ADD, &g_app.nid) == TRUE;

        SyncControlsToUi();
        SetTimer(hwnd, ID_TIMER_REFRESH, 30000, nullptr);
        StartRefreshWorker(true, true, false);
        if (g_app.cfg.autoCheckUpdates) {
            StartCheckUpdateWorker(true);
        }
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_DPICHANGED: {
        const HFONT oldFonts[] = {g_app.fontTitle, g_app.fontHeading, g_app.fontBold,
                                  g_app.fontRegular, g_app.fontSmall, g_app.fontMetric};
        auto suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER);
        CreateFonts(hwnd);
        ResizePanelToContent();
        for (HFONT font : oldFonts) DeleteObject(font);
        return 0;
    }
    case WM_VSCROLL: {
        RECT client{};
        GetClientRect(hwnd, &client);
        int y = g_app.scrollY;
        switch (LOWORD(wParam)) {
        case SB_LINEUP: y -= Scale(hwnd, 28); break;
        case SB_LINEDOWN: y += Scale(hwnd, 28); break;
        case SB_PAGEUP: y -= client.bottom; break;
        case SB_PAGEDOWN: y += client.bottom; break;
        case SB_TOP: y = 0; break;
        case SB_BOTTOM: y = Scale(hwnd, PanelLayout{}.height); break;
        case SB_THUMBTRACK:
        case SB_THUMBPOSITION: {
            SCROLLINFO info{sizeof(info), SIF_TRACKPOS};
            GetScrollInfo(hwnd, SB_VERT, &info);
            y = info.nTrackPos;
            break;
        }
        default: return 0;
        }
        SetPanelScroll(y);
        return 0;
    }
    case WM_MOUSEWHEEL:
        if (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VSCROLL) {
            SetPanelScroll(g_app.scrollY - MulDiv(GET_WHEEL_DELTA_WPARAM(wParam), Scale(hwnd, 60), WHEEL_DELTA));
        }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC hdc = BeginPaint(hwnd, &ps);
        PaintWindowCards(hwnd, hdc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_PRINTCLIENT:
        PaintWindowCards(hwnd, reinterpret_cast<HDC>(wParam));
        return 0;
    case WM_DRAWITEM:
        DrawOwnerButton(*reinterpret_cast<const DRAWITEMSTRUCT*>(lParam));
        return TRUE;
    case WM_CTLCOLORSTATIC: {
        HDC hdc = reinterpret_cast<HDC>(wParam);
        HWND ctrl = reinterpret_cast<HWND>(lParam);
        SetBkMode(hdc, TRANSPARENT);
        if (ctrl == g_app.lblUpdateBanner) {
            SetTextColor(hdc, RGB(22, 92, 200));
            return reinterpret_cast<LRESULT>(g_app.brushBanner);
        }
        if (ctrl == g_app.lblLogBadge) {
            SetTextColor(hdc, g_app.state.detailedLogs ? RGB(180, 83, 9) : RGB(95, 108, 123));
        } else if (ctrl == g_app.lblStatus) {
            SetTextColor(hdc, g_app.state.serviceRunning ? kGreen : kSecondary);
        } else if (ctrl == g_app.lblStatsCost) {
            SetTextColor(hdc, kGreen);
        } else if (ctrl == g_app.lblBackend || ctrl == g_app.lblStatsSub || ctrl == g_app.lblStatsTokens || ctrl == g_app.lblPricingNote ||
                   ctrl == g_app.lblAgPath || ctrl == g_app.lblGuardianAuth || ctrl == g_app.lblVersionInfo) {
            SetTextColor(hdc, kSecondary);
        } else {
            SetTextColor(hdc, kText);
        }
        if (ctrl == g_app.lblTitle) return reinterpret_cast<LRESULT>(g_app.brushBg);
        return reinterpret_cast<LRESULT>(g_app.brushCard);
    }
    case WM_CTLCOLORBTN:
        SetBkMode(reinterpret_cast<HDC>(wParam), TRANSPARENT);
        return reinterpret_cast<LRESULT>(g_app.brushCard);
    case WM_APP_TRAY:
        if (LOWORD(lParam) == WM_LBUTTONUP || LOWORD(lParam) == WM_LBUTTONDBLCLK) {
            if (IsWindowVisible(hwnd)) ShowWindow(hwnd, SW_HIDE);
            else ShowPanelWindow();
        } else if (LOWORD(lParam) == WM_RBUTTONUP) {
            ShowTrayContextMenu();
        }
        return 0;
    case WM_APP_SHOW_EXISTING:
        ShowPanelWindow();
        return 0;
    case WM_APP_STATS_DONE: {
        std::unique_ptr<StatsResult> result(reinterpret_cast<StatsResult*>(lParam));
        g_app.stats = std::move(*result);
        g_app.statsLoaded = true;
        g_app.statsRunning = false;
        if (g_app.statsPending) {
            g_app.statsPending = false;
            StartStatsWorker();
        }
        SyncStatsToUi();
        return 0;
    }
    case WM_APP_WORK_DONE: {
        std::unique_ptr<WorkResult> res(reinterpret_cast<WorkResult*>(lParam));
        if (!res) return 0;
        if (res->kind == WorkKind::ToggleApprovalTakeover) {
            g_app.busyAction = false;
            g_app.busyTakeover = false;
            ++g_app.state.takeoverRevision;
            g_app.state.takeoverEnabled = res->snapshot.takeoverEnabled;
            SyncControlsToUi();
            if (!res->ok)
                MessageBoxW(hwnd, L"无法确认插件接管状态，请刷新后重试。", L"切换插件接管", MB_OK | MB_ICONERROR);
        } else if (res->kind == WorkKind::ToggleDetailedLogs) {
            if (res->ok) {
                g_app.state.detailedLogs = res->targetDetailedLogs;
                SyncControlsToUi();
            } else {
                SyncControlsToUi();
                MessageBoxW(hwnd, res->message.c_str(), L"详细日志设置失败", MB_OK | MB_ICONERROR);
            }
        } else if (res->kind == WorkKind::LaunchAntigravity) {
            if (res->ok) StartRefreshWorker(false, false, true);
            else MessageBoxW(hwnd, L"无法启动 Antigravity.exe，请检查文件路径和权限。", L"启动失败", MB_OK | MB_ICONERROR);
        } else if (res->kind == WorkKind::CheckAndMaybeUpdate || res->kind == WorkKind::DownloadUpdate) {
            g_app.state.updateChecked = res->snapshot.updateChecked;
            g_app.state.updateAvailable = res->snapshot.updateAvailable;
            g_app.state.updateDownloaded = res->snapshot.updateDownloaded;
            g_app.state.waitingAntigravityExit = res->snapshot.waitingAntigravityExit;
            g_app.state.availableUpdate = res->snapshot.availableUpdate;
            g_app.state.downloadedZipPath = res->snapshot.downloadedZipPath;
            SyncControlsToUi();
            if (res->triggerImmediateApply) {
                if (g_app.uninstallPromptOpen) {
                    g_app.state.waitingAntigravityExit = true;
                    SetTimer(hwnd, ID_TIMER_DEFERRED_UPDATE, 5000, nullptr);
                    return 0;
                }
                ExecutePendingUpdateAndExit();
                return 0;
            }
            if (g_app.state.waitingAntigravityExit) {
                SetTimer(hwnd, ID_TIMER_DEFERRED_UPDATE, 5000, nullptr);
            }
            if (!res->ok && !res->message.empty()) {
                if (res->kind == WorkKind::DownloadUpdate || IsWindowVisible(hwnd)) {
                    MessageBoxW(hwnd, res->message.c_str(), L"检查/下载更新", MB_OK | MB_ICONWARNING);
                }
            } else if (res->kind == WorkKind::CheckAndMaybeUpdate && !res->snapshot.updateAvailable && IsWindowVisible(hwnd) && !res->message.empty()) {
                // Only show "already up to date" when user explicitly triggered check? Let's show unobtrusive title or message only on explicit check via status text
                SetWindowTextW(g_app.lblVersionInfo, L"面板 v" PANEL_VERSION_WIDE L"（已是最新）");
            }
        } else {
            // Preserve update state across stats/service refreshes
            bool updAvail = g_app.state.updateAvailable;
            bool updDl = g_app.state.updateDownloaded;
            bool waitAg = g_app.state.waitingAntigravityExit;
            auto updMan = g_app.state.availableUpdate;
            auto dlZip = g_app.state.downloadedZipPath;
            if (g_app.busyTakeover || res->snapshot.takeoverRevision != g_app.state.takeoverRevision) {
                res->snapshot.takeoverEnabled = g_app.state.takeoverEnabled;
                res->snapshot.takeoverRevision = g_app.state.takeoverRevision;
            }
            g_app.state = std::move(res->snapshot);
            g_app.state.updateAvailable = updAvail;
            g_app.state.updateDownloaded = updDl;
            g_app.state.waitingAntigravityExit = waitAg;
            g_app.state.availableUpdate = updMan;
            g_app.state.downloadedZipPath = dlZip;
            SyncControlsToUi();
            if (res->kind == WorkKind::CompactLogs || res->kind == WorkKind::InstallOrRepair)
                StartStatsWorker();
            if ((res->kind == WorkKind::CompactLogs || res->kind == WorkKind::InstallOrRepair || !res->ok) && !res->message.empty()) {
                MessageBoxW(hwnd, res->message.c_str(), res->ok ? L"操作完成" : L"操作提示", MB_OK | (res->ok ? MB_ICONINFORMATION : MB_ICONWARNING));
            }
        }
        return 0;
    }
    case WM_TIMER:
        if (g_app.uninstallPromptOpen) return 0;
        if (wParam == ID_TIMER_REFRESH) {
            if (IsWindowVisible(hwnd)) StartRefreshWorker(false, false, true);
        } else if (wParam == ID_TIMER_DEFERRED_UPDATE) {
            if (g_app.state.waitingAntigravityExit && !g_app.state.downloadedZipPath.empty()) {
                std::wstring agPath;
                {
                    std::lock_guard<std::mutex> lk(g_app.cfgMutex);
                    agPath = g_app.cfg.antigravityPath;
                }
                if (agPath.empty() || !IsProcessRunningByPath(agPath)) {
                    KillTimer(hwnd, ID_TIMER_DEFERRED_UPDATE);
                    ExecutePendingUpdateAndExit();
                }
            } else {
                KillTimer(hwnd, ID_TIMER_DEFERRED_UPDATE);
            }
        }
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wParam);
        switch (id) {
        case ID_BTN_LAUNCH_AG:
        case ID_MENU_LAUNCH_AG:
            LaunchAntigravityAction();
            break;
        case ID_BTN_SERVICE_ACTION:
            if (g_app.state.pluginInstalled) StartServiceWorker();
            else StartInstallScriptWorker();
            break;
        case ID_BTN_APPROVAL_TAKEOVER:
            if (HIWORD(wParam) == BN_CLICKED) StartTakeoverWorker();
            break;
        case ID_BTN_REFRESH:
        case ID_MENU_REFRESH:
            StartRefreshWorker(false, false, true);
            break;
        case ID_BTN_STATS_DATE:
            ShowStatsPeriodMenu(hwnd);
            break;
        case ID_BTN_PREFERENCES:
            g_app.preferencesOpen = !g_app.preferencesOpen;
            ResizePanelToContent();
            InvalidateRect(g_app.btnPreferences, nullptr, FALSE);
            break;
        case ID_CHK_DETAILED_LOGS: {
            bool wantEnable = !g_app.state.detailedLogs;
            if (wantEnable) {
                int ans = MessageBoxW(
                    hwnd,
                    L"开启详细日志会完整记录每次审批的上下文、工具参数与模型原始评估，磁盘写入量与占用空间会显著增大。\n\n建议日常保持关闭，仅在需要排查问题（Debug）时临时开启。\n\n确定要开启详细日志吗？",
                    L"开启详细日志提示",
                    MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
                if (ans != IDYES) {
                    SendMessageW(g_app.chkDetailedLogs, BM_SETCHECK, BST_UNCHECKED, 0);
                    break;
                }
            }
            StartDetailedLogsWorker(wantEnable);
            break;
        }
        case ID_BTN_OPEN_LOGS: {
            std::wstring logsDir = JoinPath(g_app.cfg.dataDirectory, L"logs");
            EnsureDirectoryTree(logsDir);
            OpenPathWithShell(logsDir);
            break;
        }
        case ID_BTN_COMPACT_LOGS:
            StartCompactLogsWorker();
            break;
        case ID_CHK_AUTOSTART: {
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            bool next = !g_app.cfg.autostart;
            if (SetAutostart(next, GetExecutablePath())) {
                g_app.cfg.autostart = next;
                SavePanelConfig(g_app.cfg);
            } else {
                MessageBoxW(hwnd, L"写入开机自启动注册表项失败。", L"开机自启动", MB_OK | MB_ICONERROR);
            }
            SendMessageW(g_app.chkAutostart, BM_SETCHECK, g_app.cfg.autostart ? BST_CHECKED : BST_UNCHECKED, 0);
            break;
        }
        case ID_CHK_AUTO_UPDATE: {
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            g_app.cfg.autoUpdate = !g_app.cfg.autoUpdate;
            SavePanelConfig(g_app.cfg);
            SendMessageW(g_app.chkAutoUpdate, BM_SETCHECK, g_app.cfg.autoUpdate ? BST_CHECKED : BST_UNCHECKED, 0);
            break;
        }
        case ID_BTN_CHECK_UPDATE:
        case ID_MENU_CHECK_UPDATE:
            StartCheckUpdateWorker(false);
            break;
        case ID_BTN_UPDATE_NOW:
            StartDownloadAndApplyWorker();
            break;
        case ID_BTN_OPEN_PRICING: {
            std::wstring pricing = GetPricingJsonPath(g_app.cfg);
            if (FileExists(pricing)) OpenPathWithShell(pricing);
            else MessageBoxW(hwnd, L"未找到 pricing.json 文件。", L"计价配置", MB_OK | MB_ICONINFORMATION);
            break;
        }
        case ID_BTN_BROWSE_AG: {
            std::wstring picked = BrowseExecutableFile(hwnd, L"选择 Antigravity.exe", g_app.cfg.antigravityPath.c_str());
            if (!picked.empty()) {
                {
                    std::lock_guard<std::mutex> lk(g_app.cfgMutex);
                    g_app.cfg.antigravityPath = picked;
                    SavePanelConfig(g_app.cfg);
                }
                StartRefreshWorker(false, true, true);
            }
            break;
        }
        case ID_BTN_DETECT_ENV:
            StartRefreshWorker(false, true, false);
            break;
        case ID_BTN_INSTALL_REPAIR:
            StartInstallScriptWorker();
            break;
        case ID_BTN_UNINSTALL:
            StartUninstallAndExit(hwnd);
            break;
        case ID_MENU_OPEN:
            ShowPanelWindow();
            break;
        case ID_MENU_EXIT:
            if (g_app.trayAdded) {
                Shell_NotifyIconW(NIM_DELETE, &g_app.nid);
                g_app.trayAdded = false;
            }
            DestroyWindow(hwnd);
            break;
        }
        return 0;
    }
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    case WM_DESTROY:
        if (g_app.trayAdded) {
            Shell_NotifyIconW(NIM_DELETE, &g_app.nid);
            g_app.trayAdded = false;
        }
        for (HFONT f : {g_app.fontTitle, g_app.fontHeading, g_app.fontBold, g_app.fontRegular, g_app.fontSmall, g_app.fontMetric}) {
            if (f) DeleteObject(f);
        }
        for (HBRUSH b : {g_app.brushBg, g_app.brushCard, g_app.brushBanner}) {
            if (b) DeleteObject(b);
        }
        for (HICON ic : {g_app.iconGreen, g_app.iconBlue, g_app.iconAmber, g_app.iconRed}) {
            if (ic) DestroyIcon(ic);
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int RunSelfTest(const std::wstring& localFeedDir) {
    auto check = [](bool cond, const char* msg) {
        if (!cond) {
            WriteStdoutUtf8(std::string("FAIL ") + msg + "\n");
            return false;
        }
        return true;
    };

    // 1. JSON Unicode & Windows path roundtrip
    JsonValue parsed;
    std::string err;
    const char* sample = "{\"name\":\"审批面板\",\"path\":\"C:\\\\Users\\\\Demo\\\\ag-guardian-host.exe\",\"count\":42,\"ok\":true}";
    if (!check(JsonValue::Parse(sample, parsed, &err), "JsonValue::Parse failed")) return 1;
    if (!check(parsed.GetWide("name") == L"审批面板", "JSON UTF-8 Chinese decode failed")) return 1;
    if (!check(parsed.GetWide("path") == L"C:\\Users\\Demo\\ag-guardian-host.exe", "JSON path unescape failed")) return 1;
    if (!check(parsed.GetInt64("count") == 42 && parsed.GetBool("ok"), "JSON int/bool decode failed")) return 1;
    JsonValue reparsed;
    if (!check(JsonValue::Parse(parsed.Dump(false), reparsed) && reparsed.GetWide("name") == L"审批面板", "JSON Dump roundtrip failed")) return 1;
    WriteStdoutUtf8("PASS native panel JSON parser & Unicode roundtrip\n");

    // 2. SemVer comparison
    if (!check(CompareSemVer(L"0.6.1", L"0.6.0") > 0, "0.6.1 > 0.6.0 failed")) return 1;
    if (!check(CompareSemVer(L"1.0.0", L"0.9.9") > 0, "1.0.0 > 0.9.9 failed")) return 1;
    if (!check(CompareSemVer(L"v0.6.0", L"0.6.0") == 0, "v0.6.0 == 0.6.0 failed")) return 1;
    if (!check(CompareSemVer(L"0.6.1", L"0.6.1-rc1") > 0, "release > prerelease failed")) return 1;
    WriteStdoutUtf8("PASS SemVer comparison\n");

    // 3. BCrypt SHA-256 test vector ("abc")
    std::wstring hex;
    if (!check(ComputeBufferSha256Hex("abc", 3, hex) &&
               hex == L"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "BCrypt SHA-256 vector mismatch")) return 1;
    WriteStdoutUtf8("PASS Windows CNG BCrypt SHA-256\n");

    // A helper can exit while a background process still owns its output handles.
    wchar_t systemDir[MAX_PATH]{};
    GetSystemDirectoryW(systemDir, static_cast<UINT>(std::size(systemDir)));
    const auto shell = JoinPath(systemDir, L"cmd.exe");
    const auto powershell = JoinPath(systemDir, L"WindowsPowerShell\\v1.0\\powershell.exe");
    const auto startedAt = GetTickCount64();
    const auto command = RunHiddenCommand(shell,
        L"/d /q /c echo panel-output & echo panel-error 1>&2 & start \"\" /b \"" + powershell +
        L"\" -NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 5\"", systemDir, 2500);
    if (!check(command.started && !command.timedOut && command.exitCode == 0 && GetTickCount64() - startedAt < 3500 &&
               command.stdoutUtf8.find("panel-output") != std::string::npos &&
               command.stderrUtf8.find("panel-error") != std::string::npos,
               "hidden command did not finish while a background process held its output")) return 1;
    WriteStdoutUtf8("PASS hidden command returns with inherited output handles open\n");

    // Optional local update feed verification
    if (!localFeedDir.empty()) {
        UpdateConfig ucfg{};
        ucfg.localFeedDirectory = localFeedDir;
        ucfg.manifestAsset = L"release-manifest.json";
        UpdateCheckResult chk = CheckForUpdate(ucfg, PANEL_VERSION_WIDE);
        if (!check(chk.ok && chk.hasUpdate, ("Local update feed check failed: " + WideToUtf8(chk.error)).c_str())) return 1;

        wchar_t tempBuf[MAX_PATH]{};
        GetTempPathW(static_cast<DWORD>(std::size(tempBuf)), tempBuf);
        std::wstring stage = JoinPath(tempBuf, L"ag-panel-selftest-" + std::to_wstring(GetCurrentProcessId()));
        std::wstring zipOut, dlErr;
        bool dlOk = DownloadAndVerifyUpdate(ucfg, chk.manifest, stage, zipOut, dlErr);
        bool exists = dlOk && FileExists(zipOut);
        if (!zipOut.empty()) DeleteFileW(zipOut.c_str());
        RemoveDirectoryW(stage.c_str());
        if (!check(dlOk && exists, ("Local feed download/verify failed: " + WideToUtf8(dlErr)).c_str())) return 1;
        WriteStdoutUtf8("PASS local update feed check and BCrypt SHA-256 verification\n");
    }

    return 0;
}

} // namespace
} // namespace panel

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int nCmdShow) {
    using namespace panel;

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool minimized = false;
    bool selfTest = false;
    std::wstring optPlugin, optData, optGemini, optLocalFeed;

    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--minimized") minimized = true;
        else if (a == L"--self-test") selfTest = true;
        else if (a == L"--plugin-dir" && i + 1 < argc) optPlugin = argv[++i];
        else if (a == L"--data-dir" && i + 1 < argc) optData = argv[++i];
        else if (a == L"--gemini-root" && i + 1 < argc) optGemini = argv[++i];
        else if (a == L"--local-feed" && i + 1 < argc) optLocalFeed = argv[++i];
    }
    if (argv) LocalFree(argv);

    if (selfTest) {
        if (!optPlugin.empty() && !optData.empty() && !optGemini.empty()) {
            g_app.cfg.pluginDirectory = optPlugin;
            g_app.cfg.dataDirectory = optData;
            g_app.cfg.geminiRoot = optGemini;
            LoadPanelPreferences(g_app.cfg);
            RuntimeState snapshot;
            QueryCoreSnapshot(g_app.cfg, snapshot, true, false);
            if (!snapshot.pluginInstalled || !snapshot.serviceRunning || snapshot.guardianAuthStatus != L"credentials_found") {
                WriteStdoutUtf8("FAIL panel could not read the installed Guardian authentication state\n");
                return 1;
            }
            WriteStdoutUtf8("PASS panel detected the installed Guardian and its test credentials\n");
        }
        return RunSelfTest(optLocalFeed);
    }

    InitPathsAndConfig(optPlugin, optData, optGemini);

    std::wstring mutexName = L"Local\\AntigravityCodexApprovalPanel";
    HANDLE hMutex = CreateMutexW(nullptr, TRUE, mutexName.c_str());
    if (hMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND existing = FindWindowW(kWindowClass, nullptr);
        if (existing) PostMessageW(existing, WM_APP_SHOW_EXISTING, 0, 0);
        CloseHandle(hMutex);
        return 0;
    }

    INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_STANDARD_CLASSES | ICC_DATE_CLASSES};
    InitCommonControlsEx(&icc);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    g_app.hInst = hInst;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kWindowClass;
    wc.hbrBackground = nullptr;
    RegisterClassExW(&wc);

    UINT dpi = GetDpiForSystem();
    if (dpi == 0) dpi = 96;
    int winW = MulDiv(kPanelWidth, static_cast<int>(dpi), 96);
    int winH = MulDiv(kCompactHeight, static_cast<int>(dpi), 96);
    RECT adj{0, 0, winW, winH};
    AdjustWindowRectExForDpi(&adj, kPanelStyle, FALSE, kPanelExStyle, dpi);
    int fullW = adj.right - adj.left;
    int fullH = adj.bottom - adj.top;

    RECT wa{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = wa.right - fullW - MulDiv(16, static_cast<int>(dpi), 96);
    int y = wa.bottom - fullH - MulDiv(16, static_cast<int>(dpi), 96);
    if (x < wa.left) x = wa.left + 20;
    if (y < wa.top) y = wa.top + 20;

    HWND hwnd = CreateWindowExW(
        kPanelExStyle, kWindowClass, L"Gravity Steward",
        kPanelStyle, x, y, fullW, fullH,
        nullptr, nullptr, hInst, nullptr);
    if (!hwnd) {
        if (hMutex) CloseHandle(hMutex);
        return 1;
    }

    if (!minimized) {
        ShowWindow(hwnd, nCmdShow);
        UpdateWindow(hwnd);
    }

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (IsDialogMessageW(hwnd, &msg)) {
            if (msg.message == WM_KEYDOWN && msg.wParam == VK_TAB) ScrollFocusIntoView(hwnd);
        } else {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    if (hMutex) CloseHandle(hMutex);
    return static_cast<int>(msg.wParam);
}
