#include "resource.h"
#include "updater.h"
#include "util.h"
#include "version.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace panel {

namespace {

constexpr wchar_t kWindowClass[] = L"GravityGuardianPanelWnd";
constexpr UINT kDwmWindowCornerPreference = 33;
constexpr DWORD kDwmRound = 2;
// Approximately two thirds of the 406 x 902 reference, in logical pixels.
constexpr int kPanelWidth = 272;
constexpr int kHeaderHeight = 36;
constexpr int kCompactHeight = 600;
constexpr int kContentInset = 10;
constexpr int kBannerSpace = 44;
constexpr int kPreferencesSpace = 192;
// Keep DWM's shadow, without a native caption or caption buttons for Windows to
// repaint during the system move loop. All window actions use our own controls.
constexpr DWORD kPanelStyle = WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN;
constexpr DWORD kPanelExStyle = WS_EX_APPWINDOW;

constexpr COLORREF kText = RGB(28, 28, 30);
constexpr COLORREF kSecondary = RGB(110, 110, 115);
constexpr COLORREF kTertiary = RGB(142, 142, 147);
constexpr COLORREF kBlue = RGB(0, 113, 227);
constexpr COLORREF kBlueHover = RGB(0, 102, 204);
constexpr COLORREF kBluePressed = RGB(0, 88, 179);
constexpr COLORREF kGreen = RGB(34, 154, 102);
constexpr COLORREF kRed = RGB(215, 48, 56);
constexpr COLORREF kBackground = RGB(255, 255, 255);
constexpr COLORREF kSubtleFill = RGB(245, 246, 248);
constexpr COLORREF kBorder = RGB(232, 234, 239);
constexpr COLORREF kDivider = RGB(232, 232, 235);

struct PanelConfig {
    std::wstring portableRoot;
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
    std::wstring pricingLabel = L"GPT-6 Luna 低思考 × 1.5（估算）";
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
    bool delegateProtectedPaths = true;

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
    ToggleProtectedDelegation,
    CompactLogs,
    CheckAndMaybeUpdate,
    DownloadUpdate,
    InstallOrRepair
};

enum class UpdatePhase { Idle, Checking, Current, Available, CheckFailed, Downloading, Ready, Waiting, DownloadFailed };
enum class UpdateAction { Close, Check, Download, OpenDownloads };

struct UpdateNotice {
    std::wstring title;
    std::wstring body;
    std::wstring detail;
    std::wstring currentVersion;
    std::wstring latestVersion;
    std::wstring primaryLabel;
    UpdateAction action = UpdateAction::Close;
    bool busy = false;
    bool showSecondary = false;
    int icon = ID_BTN_CHECK_UPDATE;
    COLORREF accent = kBlue;
};

struct WorkResult {
    WorkKind kind{};
    bool ok = false;
    std::wstring message;
    RuntimeState snapshot;
    bool triggerImmediateApply = false;
    bool requestExit = false;
    bool targetDetailedLogs = false;
    bool targetProtectedDelegation = true;
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
    HFONT fontSmallLatin = nullptr;
    HFONT fontMetric = nullptr;
    HFONT fontSubMetric = nullptr;
    HFONT fontDialogTitle = nullptr;
    HBRUSH brushBg = nullptr;
    HBRUSH brushCard = nullptr;
    HWND tooltip = nullptr;
    HWND hoveredControl = nullptr;

    HICON iconAppSmall = nullptr;
    HICON iconAppLarge = nullptr;
    HICON iconNormal = nullptr;
    HICON iconGray = nullptr;
    std::unique_ptr<Gdiplus::Bitmap> brandBitmap;

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
    bool startupUpdatePending = true;
    StatsPeriod period = StatsPeriod::Today;
    std::optional<DateRange> customDates;
    StatsResult stats;
    bool preferencesOpen = false;
    int scrollY = 0;
    bool needsScroll = false;
    HWND scrollbar = nullptr;
    UpdatePhase updatePhase = UpdatePhase::Idle;
    std::wstring updateError;
    std::wstring updateCurrentVersion = PANEL_VERSION_WIDE;
    HWND updatePopup = nullptr;
    HWND lblUpdatePopupTitle = nullptr;
    HWND lblUpdatePopupBody = nullptr;
    HWND lblUpdatePopupDetail = nullptr;
    HWND lblUpdatePopupCurrent = nullptr;
    HWND lblUpdatePopupLatest = nullptr;
    HWND btnUpdatePopupPrimary = nullptr;
    HWND btnUpdatePopupSecondary = nullptr;
    HWND btnUpdatePopupClose = nullptr;
    HWND updatePopupTooltip = nullptr;

    // Child controls
    HWND lblTitle = nullptr;
    HWND btnHeaderUpdate = nullptr;
    HWND btnGitHub = nullptr;
    HWND btnHide = nullptr;
    HWND lblStatus = nullptr;
    HWND btnApprovalTakeover = nullptr;
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
    HWND lblStatsTokenDetail = nullptr;
    HWND lblStatsInputTitle = nullptr;
    HWND lblStatsOutputTitle = nullptr;
    HWND lblStatsCacheTitle = nullptr;
    HWND lblStatsOutput = nullptr;
    HWND lblStatsCacheRate = nullptr;
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
    HWND chkProtectedDelegation = nullptr;
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
void UpdateTrayAppearance();
void SyncUpdatePopup();
void ShowUpdatePopup(bool show = true);
void PositionUpdatePopup();

void ConfigureFramelessWindow(HWND hwnd) {
    const DWORD round = kDwmRound;
    DwmSetWindowAttribute(hwnd, kDwmWindowCornerPreference, &round, sizeof(round));
    const MARGINS shadow{1, 1, 1, 1};
    DwmExtendFrameIntoClientArea(hwnd, &shadow);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

UpdateNotice GetUpdateNotice() {
    UpdateNotice notice;
    notice.currentVersion = L"v" + g_app.updateCurrentVersion;
    notice.latestVersion = g_app.state.availableUpdate.version.empty() ? L"尚未获取" : L"v" + g_app.state.availableUpdate.version;
    notice.primaryLabel = L"知道了";
    switch (g_app.updatePhase) {
    case UpdatePhase::Idle:
        notice.title = L"检查应用更新";
        notice.body = L"检查是否有可用的新版本。";
        notice.primaryLabel = L"检查更新";
        notice.action = UpdateAction::Check;
        break;
    case UpdatePhase::Checking:
        notice.title = L"正在检查更新";
        notice.body = L"正在连接更新服务，确认是否有新版本。\n请稍候，这通常只需几秒。";
        notice.latestVersion = L"检查中…";
        notice.primaryLabel = L"正在检查…";
        notice.busy = notice.showSecondary = true;
        break;
    case UpdatePhase::Current:
        notice.title = L"当前无需更新";
        notice.body = L"你正在使用最新版本。\n可以继续正常使用 Gravity Guardian。";
        if (g_app.state.availableUpdate.version.empty()) notice.latestVersion = notice.currentVersion;
        notice.icon = ID_ICON_UPDATE_SUCCESS;
        notice.accent = kGreen;
        break;
    case UpdatePhase::Available:
        notice.title = L"发现新版本";
        notice.body = g_app.state.pluginInstalled ? L"有新版本可用，建议更新以获得最新改进。\n更新包会在安装前完成校验。" :
            L"有新版本可用。\n打开项目发布页即可下载最新安装包。";
        notice.primaryLabel = g_app.state.pluginInstalled ? L"下载并更新" : L"前往下载";
        notice.action = g_app.state.pluginInstalled ? UpdateAction::Download : UpdateAction::OpenDownloads;
        notice.showSecondary = true;
        break;
    case UpdatePhase::CheckFailed:
        notice.title = L"暂时无法检查更新";
        notice.body = L"暂时无法确认是否需要更新。\n请检查网络连接后重试。";
        notice.detail = g_app.updateError;
        notice.primaryLabel = L"重新检查";
        notice.action = UpdateAction::Check;
        notice.showSecondary = true;
        notice.icon = ID_ICON_UPDATE_ERROR;
        notice.accent = kRed;
        break;
    case UpdatePhase::Downloading:
        notice.title = L"正在准备更新";
        notice.body = L"正在下载并校验更新包。\n完成后会自动继续安装。";
        notice.primaryLabel = L"正在准备…";
        notice.busy = notice.showSecondary = true;
        break;
    case UpdatePhase::Ready:
        notice.title = L"更新已准备就绪";
        notice.body = L"更新包已下载并通过校验。\n现在可以安装新版本。";
        notice.primaryLabel = L"立即更新";
        notice.action = UpdateAction::Download;
        notice.showSecondary = true;
        break;
    case UpdatePhase::Waiting:
        notice.title = L"等待应用关闭后更新";
        notice.body = L"更新包已就绪。关闭 Antigravity 后，\n将自动安装并重新打开面板。";
        notice.icon = ID_ICON_UPDATE_SUCCESS;
        notice.accent = kGreen;
        break;
    case UpdatePhase::DownloadFailed:
        notice.title = L"更新暂未完成";
        notice.body = L"更新遇到问题，你可以稍后重试。\n已下载的有效文件会继续复用。";
        notice.detail = g_app.updateError;
        notice.primaryLabel = L"重试更新";
        notice.action = UpdateAction::Download;
        notice.showSecondary = true;
        notice.icon = ID_ICON_UPDATE_ERROR;
        notice.accent = kRed;
        break;
    }
    return notice;
}

void SetControlTooltip(HWND control, const wchar_t* text) {
    if (!g_app.tooltip) return;
    TOOLINFOW tool{sizeof(tool)};
    tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    tool.hwnd = g_app.hwnd;
    tool.uId = reinterpret_cast<UINT_PTR>(control);
    tool.lpszText = const_cast<wchar_t*>(text);
    SendMessageW(g_app.tooltip, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool));
}

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

HICON CreateGrayscaleIcon(HICON source) {
    ICONINFO original{};
    if (!GetIconInfo(source, &original)) return nullptr;

    BITMAP bitmap{};
    const bool hasColor = original.hbmColor && GetObjectW(original.hbmColor, sizeof(bitmap), &bitmap);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = bitmap.bmWidth;
    bmi.bmiHeader.biHeight = -bitmap.bmHeight;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HDC screen = GetDC(nullptr);
    HBITMAP grayBitmap = hasColor ? CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0) : nullptr;
    HICON icon = nullptr;

    if (grayBitmap && bits && GetDIBits(screen, original.hbmColor, 0,
            static_cast<UINT>(bitmap.bmHeight), bits, &bmi, DIB_RGB_COLORS) == bitmap.bmHeight) {
        auto* pixels = static_cast<uint32_t*>(bits);
        const size_t count = static_cast<size_t>(bitmap.bmWidth) * bitmap.bmHeight;
        for (size_t i = 0; i < count; ++i) {
            const uint32_t pixel = pixels[i];
            const uint32_t gray = (77 * ((pixel >> 16) & 0xff) +
                                   150 * ((pixel >> 8) & 0xff) + 29 * (pixel & 0xff) + 128) >> 8;
            // Keep the original alpha and mask so transparent edges stay transparent.
            pixels[i] = (pixel & 0xff000000) | (gray << 16) | (gray << 8) | gray;
        }

        ICONINFO grayInfo = original;
        grayInfo.hbmColor = grayBitmap;
        icon = CreateIconIndirect(&grayInfo);
    }

    if (grayBitmap) DeleteObject(grayBitmap);
    if (original.hbmColor) DeleteObject(original.hbmColor);
    if (original.hbmMask) DeleteObject(original.hbmMask);
    ReleaseDC(nullptr, screen);
    return icon;
}

std::unique_ptr<Gdiplus::Bitmap> LoadBrandBitmap(WORD resId) {
    HICON raw = static_cast<HICON>(LoadImageW(g_app.hInst, MAKEINTRESOURCEW(resId), IMAGE_ICON, 256, 256, LR_DEFAULTCOLOR));
    if (!raw) return nullptr;

    ICONINFO info{};
    std::unique_ptr<Gdiplus::Bitmap> result;
    if (GetIconInfo(raw, &info)) {
        BITMAP bm{};
        if (info.hbmColor && GetObjectW(info.hbmColor, sizeof(bm), &bm) && bm.bmWidth > 0 && bm.bmHeight > 0) {
            BITMAPINFO bmi{};
            bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            bmi.bmiHeader.biWidth = bm.bmWidth;
            bmi.bmiHeader.biHeight = -bm.bmHeight;
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;
            std::vector<uint32_t> pixels(static_cast<size_t>(bm.bmWidth) * static_cast<size_t>(bm.bmHeight));
            HDC screen = GetDC(nullptr);
            const bool ok = GetDIBits(screen, info.hbmColor, 0, static_cast<UINT>(bm.bmHeight),
                                      pixels.data(), &bmi, DIB_RGB_COLORS) == bm.bmHeight;
            ReleaseDC(nullptr, screen);
            if (ok) {
                auto bmp = std::make_unique<Gdiplus::Bitmap>(bm.bmWidth, bm.bmHeight, PixelFormat32bppPARGB);
                Gdiplus::BitmapData bmpData{};
                const Gdiplus::Rect lockRect(0, 0, bm.bmWidth, bm.bmHeight);
                if (bmp->LockBits(&lockRect, Gdiplus::ImageLockModeWrite, PixelFormat32bppPARGB, &bmpData) == Gdiplus::Ok) {
                    auto* dstBase = static_cast<uint8_t*>(bmpData.Scan0);
                    for (int y = 0; y < bm.bmHeight; ++y) {
                        auto* dstRow = reinterpret_cast<uint32_t*>(dstBase + static_cast<ptrdiff_t>(y) * bmpData.Stride);
                        const uint32_t* srcRow = pixels.data() + static_cast<size_t>(y) * static_cast<size_t>(bm.bmWidth);
                        for (int x = 0; x < bm.bmWidth; ++x) {
                            const uint32_t px = srcRow[x];
                            const uint32_t a = (px >> 24) & 0xffu;
                            const uint32_t r = (((px >> 16) & 0xffu) * a + 127u) / 255u;
                            const uint32_t g = (((px >> 8) & 0xffu) * a + 127u) / 255u;
                            const uint32_t b = ((px & 0xffu) * a + 127u) / 255u;
                            dstRow[x] = (a << 24) | (r << 16) | (g << 8) | b;
                        }
                    }
                    bmp->UnlockBits(&bmpData);
                    result = std::move(bmp);
                }
            }
        }
        if (info.hbmColor) DeleteObject(info.hbmColor);
        if (info.hbmMask) DeleteObject(info.hbmMask);
    }
    DestroyIcon(raw);
    return result;
}

bool LoadPanelIcons(HWND hwnd) {
    const UINT dpi = GetDpiForWindow(hwnd);
    auto load = [dpi](WORD resId, int widthMetric, int heightMetric) {
        return static_cast<HICON>(LoadImageW(g_app.hInst, MAKEINTRESOURCEW(resId), IMAGE_ICON,
            GetSystemMetricsForDpi(widthMetric, dpi), GetSystemMetricsForDpi(heightMetric, dpi), LR_DEFAULTCOLOR));
    };
    HICON appSmall = load(IDI_APP_ICON, SM_CXSMICON, SM_CYSMICON);
    HICON appLarge = load(IDI_APP_ICON, SM_CXICON, SM_CYICON);
    HICON normal = load(IDI_TRAY_ICON, SM_CXSMICON, SM_CYSMICON);
    HICON gray = normal ? CreateGrayscaleIcon(normal) : nullptr;
    std::unique_ptr<Gdiplus::Bitmap> brand;
    if (!g_app.brandBitmap) {
        brand = LoadBrandBitmap(IDI_TRAY_ICON);
    }
    if (!appSmall || !appLarge || !normal || !gray || (!g_app.brandBitmap && !brand)) {
        for (HICON icon : {appSmall, appLarge, normal, gray}) {
            if (icon) DestroyIcon(icon);
        }
        return false;
    }

    const HICON previous[] = {g_app.iconAppSmall, g_app.iconAppLarge, g_app.iconNormal, g_app.iconGray};
    g_app.iconAppSmall = appSmall;
    g_app.iconAppLarge = appLarge;
    g_app.iconNormal = normal;
    g_app.iconGray = gray;
    if (brand) {
        g_app.brandBitmap = std::move(brand);
    }
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(g_app.iconAppSmall));
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(g_app.iconAppLarge));
    UpdateTrayAppearance();
    for (HICON icon : previous) {
        if (icon) DestroyIcon(icon);
    }
    return true;
}

std::wstring GetUserProfileDir() {
    wchar_t buf[MAX_PATH]{};
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", buf, static_cast<DWORD>(std::size(buf)));
    return n > 0 ? std::wstring(buf, n) : L"";
}

std::wstring PanelSettingsPath(const PanelConfig& cfg) {
    return JoinPath(cfg.portableRoot.empty() ? cfg.dataDirectory : JoinPath(cfg.portableRoot, L"config"), L"panel-settings.json");
}

std::wstring ApprovalConfigPath(const PanelConfig& cfg) {
    return cfg.portableRoot.empty() ? JoinPath(cfg.pluginDirectory, L"approval.json") : JoinPath(cfg.portableRoot, L"config\\approval.json");
}

bool PortableConnected(const PanelConfig& cfg) {
    if (cfg.portableRoot.empty()) return true;
    std::string raw;
    JsonValue binding;
    const auto path = JoinPath(cfg.geminiRoot, L"config\\plugins\\gravity-guardian\\binding.json");
    return ReadFileUtf8(path, raw) && JsonValue::Parse(raw, binding) &&
        binding.GetWide("storageMode") == L"portable" && _wcsicmp(binding.GetWide("portableRoot").c_str(), cfg.portableRoot.c_str()) == 0;
}

void SavePanelConfig(const PanelConfig& cfg) {
    std::wstring path = PanelSettingsPath(cfg);
    EnsureDirectoryTree(GetDirectoryName(path));

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

    if (cfg.portableRoot.empty()) {
        setStr("geminiRoot", cfg.geminiRoot);
        setStr("dataDirectory", cfg.dataDirectory);
        setStr("pluginDirectory", cfg.pluginDirectory);
    }
    setStr("antigravityPath", cfg.antigravityPath);
    doc.objVal.erase("codexPath");
    setBool("autoCheckUpdates", cfg.autoCheckUpdates);
    setBool("autoUpdate", cfg.autoUpdate);
    if (cfg.portableRoot.empty()) setBool("autostart", cfg.autostart);

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
    if (cfg.portableRoot.empty()) cfg.autostart = doc.GetBool("autostart", false);
}

bool SamePanelPath(const std::wstring& left, const std::wstring& right) {
    auto full = [](const std::wstring& path) {
        wchar_t buffer[MAX_PATH * 2]{};
        const DWORD length = GetFullPathNameW(path.c_str(), static_cast<DWORD>(std::size(buffer)), buffer, nullptr);
        if (path.empty() || length == 0 || length >= std::size(buffer)) return std::wstring{};
        std::wstring value(buffer, length);
        std::replace(value.begin(), value.end(), L'/', L'\\');
        while (value.size() > 3 && value.back() == L'\\') value.pop_back();
        return value;
    };
    const auto a = full(left), b = full(right);
    return !a.empty() && !b.empty() && _wcsicmp(a.c_str(), b.c_str()) == 0;
}

void RestoreInstalledPanelPaths(PanelConfig& cfg, const std::wstring& exeDir,
                                bool explicitPlugin, bool explicitData, bool explicitGemini) {
    if (!cfg.portableRoot.empty()) return;
    // An installed panel can locate its own custom Gemini root. Extracted bundles
    // have no installation approval.json and cannot replace this identity check.
    std::vector<std::wstring> candidates;
    if (!explicitPlugin && !explicitGemini) candidates.push_back(GetDirectoryName(exeDir));
    candidates.push_back(cfg.pluginDirectory);
    for (const auto& plugin : candidates) {
        std::string raw;
        JsonValue identity, approval;
        if (!ReadFileUtf8(JoinPath(plugin, L"plugin.json"), raw) || !JsonValue::Parse(raw, identity) ||
            identity.GetWide("name") != L"gravity-guardian" ||
            !ReadFileUtf8(JoinPath(plugin, L"approval.json"), raw) || !JsonValue::Parse(raw, approval)) continue;
        const auto configRoot = approval.GetWide("antigravityConfigDirectory");
        if (configRoot.empty() || !SamePanelPath(plugin, JoinPath(configRoot, L"plugins\\gravity-guardian"))) continue;
        if (explicitGemini && !SamePanelPath(configRoot, JoinPath(cfg.geminiRoot, L"config"))) continue;
        cfg.pluginDirectory = plugin;
        if (!explicitGemini) cfg.geminiRoot = GetDirectoryName(configRoot);
        if (!explicitData) cfg.dataDirectory = approval.GetWide("dataDirectory", JoinPath(cfg.geminiRoot, L"gravity-guardian-data"));
        return;
    }
}

void InitPathsAndConfig(const std::wstring& optPlugin, const std::wstring& optData, const std::wstring& optGemini) {
    std::wstring exeDir = GetDirectoryName(GetExecutablePath());
    std::wstring parentDir = GetDirectoryName(exeDir);
    std::wstring profile = GetUserProfileDir();

    PanelConfig cfg{};
    cfg.geminiRoot = !optGemini.empty() ? optGemini : JoinPath(profile, L".gemini");
    cfg.dataDirectory = !optData.empty() ? optData : JoinPath(cfg.geminiRoot, L"gravity-guardian-data");
    cfg.pluginDirectory = !optPlugin.empty() ? optPlugin : JoinPath(cfg.geminiRoot, L"config\\plugins\\gravity-guardian");

    if (FileExists(JoinPath(exeDir, L"portable.json"))) {
        std::string raw;
        JsonValue marker;
        if (!ReadFileUtf8(JoinPath(exeDir, L"portable.json"), raw) || !JsonValue::Parse(raw, marker) ||
            marker.GetWide("storageMode") != L"portable" || marker.GetInt64("layoutVersion", 0) != 1) {
            MessageBoxW(nullptr, L"免安装版目录标记无效，请重新完整解压程序。", L"Gravity Guardian", MB_OK | MB_ICONERROR);
            ExitProcess(1);
        }
        cfg.portableRoot = exeDir;
        const auto transactionPath = JoinPath(exeDir, L"data\\update-transaction.json");
        if (FileExists(transactionPath)) {
            JsonValue transaction;
            if (!ReadFileUtf8(transactionPath, raw) || !JsonValue::Parse(raw, transaction)) {
                MessageBoxW(nullptr, L"更新恢复记录损坏，请保留 data 文件夹并重新解压程序文件。", L"更新恢复", MB_OK | MB_ICONERROR);
                ExitProcess(1);
            }
            const auto workerPid = static_cast<DWORD>(transaction.GetInt64("workerPid", 0));
            bool activeWorker = false;
            if (HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, workerPid)) {
                FILETIME created{}, exited{}, kernel{}, user{};
                DWORD exitCode = 0;
                if (GetExitCodeProcess(process, &exitCode) && exitCode == STILL_ACTIVE && GetProcessTimes(process, &created, &exited, &kernel, &user)) {
                    const uint64_t started = (static_cast<uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
                    activeWorker = std::to_wstring(started) == transaction.GetWide("workerStarted");
                }
                CloseHandle(process);
            }
            if (activeWorker) {
                MessageBoxW(nullptr, L"程序正在更新，请等待更新完成。", L"Gravity Guardian", MB_OK | MB_ICONINFORMATION);
                ExitProcess(0);
            }
            wchar_t system[MAX_PATH]{};
            GetSystemDirectoryW(system, static_cast<DWORD>(std::size(system)));
            const auto powershell = JoinPath(system, L"WindowsPowerShell\\v1.0\\powershell.exe");
            const auto script = JoinPath(exeDir, L"data\\updates\\Apply-Update.ps1");
            const auto args = L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
                L"\" -RecoverPortable -RelaunchPanel -WaitPid " + std::to_wstring(GetCurrentProcessId()) +
                L" -PluginDirectory \"" + JoinPath(exeDir, L"app") + L"\" -DataDirectory \"" + JoinPath(exeDir, L"data") + L"\"";
            if (!FileExists(script) || !LaunchDetached(powershell, args, system, true)) {
                MessageBoxW(nullptr, L"无法启动更新恢复。请保留 config 和 data 文件夹，重新解压程序文件。", L"更新恢复", MB_OK | MB_ICONERROR);
                ExitProcess(1);
            }
            ExitProcess(0);
        }
        cfg.dataDirectory = JoinPath(exeDir, L"data");
        cfg.pluginDirectory = JoinPath(exeDir, L"app");
        cfg.bundleDirectory = cfg.pluginDirectory;
        JsonValue installed;
        if (ReadFileUtf8(JoinPath(cfg.dataDirectory, L"installation.json"), raw) && JsonValue::Parse(raw, installed)) {
            cfg.geminiRoot = installed.GetWide("geminiRoot", cfg.geminiRoot);
        }
    }

    RestoreInstalledPanelPaths(cfg, exeDir, !optPlugin.empty(), !optData.empty(), !optGemini.empty());

    // Either distribution may be installed or opened as a portable panel.
    std::wstring nestedBundle = JoinPath(exeDir, L"artifacts\\gravity-guardian");
    if (!cfg.portableRoot.empty()) {
        cfg.bundleDirectory = cfg.pluginDirectory;
    } else if (FileExists(JoinPath(cfg.pluginDirectory, L"scripts\\gravity-guardian.dll"))) {
        cfg.bundleDirectory = cfg.pluginDirectory;
    } else if (FileExists(JoinPath(parentDir, L"scripts\\gravity-guardian.dll"))) {
        cfg.bundleDirectory = parentDir;
    } else if (FileExists(JoinPath(nestedBundle, L"scripts\\gravity-guardian.dll"))) {
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
    if (!cfg.portableRoot.empty()) {
        cfg.autostart = IsAutostartMatching(exePath);
    } else if (!GetAutostartCommand().empty()) {
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

std::wstring GetDistribution(const std::wstring& bundle) {
    std::string raw;
    JsonValue metadata;
    if (ReadFileUtf8(JoinPath(bundle, L"distribution.json"), raw) &&
        JsonValue::Parse(raw, metadata) && metadata.GetWide("type") == L"lite") {
        return L"lite";
    }
    return L"standalone";
}

std::wstring GetBundleDotnet(const std::wstring& bundle) {
    if (GetDistribution(bundle) == L"standalone") return JoinPath(bundle, L"runtime\\dotnet.exe");
    std::string raw;
    JsonValue sidecar;
    if (ReadFileUtf8(JoinPath(bundle, L"sidecars\\reviewer\\sidecar.json"), raw) && JsonValue::Parse(raw, sidecar)) {
        return sidecar.GetWide("command");
    }
    const auto resolver = JoinPath(bundle, L"scripts\\Resolve-Runtime.ps1");
    if (!FileExists(resolver)) return {};
    wchar_t system[MAX_PATH]{};
    GetSystemDirectoryW(system, static_cast<DWORD>(std::size(system)));
    const auto powershell = JoinPath(system, L"WindowsPowerShell\\v1.0\\powershell.exe");
    const auto result = RunHiddenCommand(powershell,
        L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + resolver + L"\" -Bundle \"" + bundle + L"\"",
        bundle, 10000);
    if (!result.started || result.timedOut || result.exitCode != 0) return {};
    auto runtime = Utf8ToWide(result.stdoutUtf8);
    const auto end = runtime.find_last_not_of(L"\r\n");
    if (end == std::wstring::npos) return {};
    runtime.resize(end + 1);
    return runtime;
}

std::wstring GetDotnetExe(const PanelConfig& cfg) {
    if (FileExists(JoinPath(cfg.pluginDirectory, L"scripts\\gravity-guardian.dll"))) return GetBundleDotnet(cfg.pluginDirectory);
    return GetBundleDotnet(cfg.bundleDirectory);
}

std::wstring GetAssemblyDll(const PanelConfig& cfg) {
    std::wstring p1 = JoinPath(cfg.pluginDirectory, L"scripts\\gravity-guardian.dll");
    if (FileExists(p1)) return p1;
    return JoinPath(cfg.bundleDirectory, L"scripts\\gravity-guardian.dll");
}

std::wstring GetPricingJsonPath(const PanelConfig& cfg) {
    if (!cfg.portableRoot.empty()) {
        const auto overridePath = JoinPath(cfg.portableRoot, L"config\\pricing.json");
        if (FileExists(overridePath)) return overridePath;
    }
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
    for (const auto& bundle : {GetDirectoryName(exeDir), JoinPath(exeDir, L"artifacts\\gravity-guardian")}) {
        auto bundledDotnet = GetBundleDotnet(bundle);
        auto bundledDll = JoinPath(bundle, L"scripts\\gravity-guardian.dll");
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

std::wstring FormatCacheHitRate(const ApprovalStats& stats) {
    if (stats.inputTokens <= 0) return L"—";
    wchar_t rate[32]{};
    swprintf_s(rate, L"%.1f%%", 100.0 * static_cast<double>(stats.cachedTokens) / static_cast<double>(stats.inputTokens));
    return rate;
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
        SetWindowTextW(g_app.lblStatsTokens, L"—");
        SetWindowTextW(g_app.lblStatsOutput, L"—");
        SetWindowTextW(g_app.lblStatsCacheRate, L"—");
        SetWindowTextW(g_app.lblStatsTokenDetail, L"");
        SetWindowTextW(g_app.lblStatsCost, L"");
    } else {
        const auto& s = **value;
        auto count = FormatIntWithCommas(s.total);
        auto sub = L"模型 " + FormatIntWithCommas(s.model) + L" · 批准 " + FormatIntWithCommas(s.approved) +
                   L" / 拒绝 " + FormatIntWithCommas(s.denied) + L" · 放行 " + FormatIntWithCommas(s.delegated);
        auto tokens = FormatIntWithCommas(s.inputTokens);
        auto output = FormatIntWithCommas(s.outputTokens);
        auto rate = FormatCacheHitRate(s);
        auto detail = s.unknownUsage > 0 ? L"另有 " + FormatIntWithCommas(s.unknownUsage) + L" 次未回报用量" : L"";
        auto cost = L"预估 " + FormatUsd(s.costUsd);
        SetWindowTextW(g_app.lblStatsCount, count.c_str());
        SetWindowTextW(g_app.lblStatsSub, sub.c_str());
        SetWindowTextW(g_app.lblStatsTokens, tokens.c_str());
        SetWindowTextW(g_app.lblStatsOutput, output.c_str());
        SetWindowTextW(g_app.lblStatsCacheRate, rate.c_str());
        SetWindowTextW(g_app.lblStatsTokenDetail, detail.c_str());
        SetWindowTextW(g_app.lblStatsCost, cost.c_str());
        SetControlTooltip(g_app.lblStatsSub, sub.c_str());
        SetControlTooltip(g_app.lblStatsTokenDetail, detail.c_str());
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
    const auto dotnet = GetBundleDotnet(cfg.pluginDirectory);
    const auto dll = JoinPath(cfg.pluginDirectory, L"scripts\\gravity-guardian.dll");
    const auto approvalCfg = ApprovalConfigPath(cfg);
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
    std::wstring approvalCfg = ApprovalConfigPath(cfg);
    std::wstring pluginJson = JoinPath(cfg.pluginDirectory, L"plugin.json");
    snap.pluginInstalled = FileExists(approvalCfg) && FileExists(pluginJson) && PortableConnected(cfg);
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
                snap.delegateProtectedPaths = app.GetBool("delegateProtectedPaths", true);
            }
        }
    }

    std::wstring dotnet = GetDotnetExe(cfg);
    std::wstring dll = GetAssemblyDll(cfg);
    if (!FileExists(dotnet) || !FileExists(dll)) {
        snap.serviceRunning = false;
        snap.serviceDetail = GetDistribution(cfg.bundleDirectory) == L"lite" ?
            L"Lite 需要可用的 x64 .NET 10 运行时" : L"缺少内置运行组件";
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
            snap.delegateProtectedPaths = stJson.GetBool("delegateProtectedPaths", snap.delegateProtectedPaths);
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
        CommandResult dRes = RunHiddenCommand(dotnet, dArgs, GetDirectoryName(dll), 18000);
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
    if (!g_app.hwnd) return;
    const bool active = g_app.state.pluginInstalled && g_app.state.serviceRunning &&
                        g_app.state.takeoverEnabled.value_or(false);
    HICON hIcon = active ? g_app.iconNormal : g_app.iconGray;
    std::wstring tip = L"Gravity Guardian v" + g_app.state.serviceVersion;
    if (!g_app.state.pluginInstalled || !g_app.state.serviceRunning) {
        tip += g_app.state.pluginInstalled ? L" · 服务未运行" : L" · 未安装";
    } else if (!g_app.state.takeoverEnabled.has_value()) {
        tip += L" · 接管状态未知";
    } else if (g_app.state.takeoverEnabled == false) {
        tip += L" · 插件接管已关闭";
    } else if (g_app.state.updateAvailable) {
        tip += L" · 发现新版本 v" + g_app.state.availableUpdate.version;
    } else if (g_app.state.detailedLogs || g_app.state.guardianAuthStatus != L"credentials_found") {
        tip += g_app.state.detailedLogs ? L" · 详细日志已开启" : L" · 请确认 Codex 登录";
    } else {
        tip += L" · 运行正常";
    }

    g_app.nid.hIcon = hIcon;
    wcsncpy_s(g_app.nid.szTip, tip.c_str(), _TRUNCATE);
    g_app.nid.uFlags = NIF_ICON | NIF_TIP;
    if (g_app.trayAdded) Shell_NotifyIconW(NIM_MODIFY, &g_app.nid);
}

void SyncControlsToUi() {
    const auto& s = g_app.state;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }

    SetWindowTextW(g_app.lblStatus, s.serviceDetail.c_str());
    const wchar_t* takeoverText = L"审批接管状态未知";
    if (g_app.busyTakeover) takeoverText = L"切换中…";
    else if (s.takeoverEnabled.has_value()) takeoverText = *s.takeoverEnabled ? L"关闭审批接管" : L"开启审批接管";
    SetWindowTextW(g_app.btnApprovalTakeover, takeoverText);
    SetControlTooltip(g_app.btnApprovalTakeover, takeoverText);
    EnableWindow(g_app.btnApprovalTakeover, s.pluginInstalled && s.takeoverEnabled.has_value() && !g_app.busyTakeover);
    InvalidateRect(g_app.btnApprovalTakeover, nullptr, FALSE);
    SetControlTooltip(g_app.lblStatus, s.serviceDetail.c_str());
    const auto updateNotice = GetUpdateNotice();
    SetControlTooltip(g_app.btnHeaderUpdate, updateNotice.title.c_str());
    SetControlTooltip(g_app.btnCheckUpdate, updateNotice.title.c_str());
    SetControlTooltip(g_app.btnRefresh, g_app.busyRefresh ? L"正在刷新…" : L"刷新状态与统计");
    EnableWindow(g_app.btnHeaderUpdate, !g_app.busyUpdate);
    EnableWindow(g_app.btnRefresh, !g_app.busyRefresh);
    InvalidateRect(g_app.btnHeaderUpdate, nullptr, FALSE);
    InvalidateRect(g_app.btnRefresh, nullptr, FALSE);
    SetWindowTextW(g_app.btnServiceAction, s.pluginInstalled ? (s.serviceRunning ? L"重启服务" : L"启动服务") : (g_app.cfg.portableRoot.empty() ? L"安装插件" : L"连接 Antigravity"));
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
    EnableWindow(g_app.chkDetailedLogs, s.pluginInstalled);
    InvalidateRect(g_app.chkDetailedLogs, nullptr, FALSE);
    SetWindowTextW(g_app.lblLogBadge, s.detailedLogs ? L"高写入已开启" : L"");

    EnableWindow(g_app.chkProtectedDelegation, s.pluginInstalled);
    InvalidateRect(g_app.chkProtectedDelegation, nullptr, FALSE);

    InvalidateRect(g_app.chkAutostart, nullptr, FALSE);
    InvalidateRect(g_app.chkAutoUpdate, nullptr, FALSE);

    SetWindowTextW(g_app.lblVersionInfo, L"v" PANEL_VERSION_WIDE);

    // Environment
    std::wstring agText = cfgCopy.antigravityPath.empty() ? L"未检测到，请手动选择" : cfgCopy.antigravityPath;
    SetWindowTextW(g_app.lblAgTitle, (s.agVersion.empty() ? L"Antigravity" : L"Antigravity · v" + s.agVersion).c_str());
    SetWindowTextW(g_app.lblAgPath, agText.c_str());
    SetControlTooltip(g_app.lblAgPath, agText.c_str());

    const wchar_t* authText = L"未检测";
    if (s.guardianAuthStatus == L"credentials_found") authText = L"已读取本机凭据";
    else if (s.guardianAuthStatus == L"credentials_missing") authText = L"未找到登录凭据";
    else if (s.guardianAuthStatus == L"store_unavailable") authText = L"无法读取凭据存储";
    SetWindowTextW(g_app.lblGuardianAuth, authText);

    EnableWindow(g_app.btnUninstall, FileExists(JoinPath(cfgCopy.dataDirectory, L"installation.json")) && PortableConnected(cfgCopy));
    UpdateTrayAppearance();
    ResizePanelToContent();
    SyncUpdatePopup();
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
    EnableWindow(g_app.btnRefresh, FALSE);
    SetControlTooltip(g_app.btnRefresh, L"正在刷新…");
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    RuntimeState baseSnap = g_app.state;

    std::thread([cfgCopy, baseSnap, initialStartup, runDetect, skipLoginCheck]() mutable {
        // On initial startup, ensure approval host if plugin is already installed
        if (initialStartup && PortableConnected(cfgCopy) && FileExists(ApprovalConfigPath(cfgCopy))) {
            std::wstring dotnet = GetDotnetExe(cfgCopy);
            std::wstring dll = GetAssemblyDll(cfgCopy);
            std::wstring appCfg = ApprovalConfigPath(cfgCopy);
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

bool TakeStartupUpdateCheck(WorkKind completedKind) {
    if (completedKind != WorkKind::InitialRefresh || !g_app.startupUpdatePending) return false;
    g_app.startupUpdatePending = false;
    return g_app.cfg.autoCheckUpdates;
}

void StartCheckUpdateWorker(bool allowAutoApply) {
    if (g_app.busyUpdate.exchange(true)) {
        if (!allowAutoApply) ShowUpdatePopup();
        return;
    }
    EnableWindow(g_app.btnHeaderUpdate, FALSE);
    SetControlTooltip(g_app.btnHeaderUpdate, L"正在检查更新…");
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
    g_app.updateCurrentVersion = currentVer;
    g_app.updatePhase = UpdatePhase::Checking;
    g_app.updateError.clear();
    SyncUpdatePopup();
    if (!allowAutoApply) ShowUpdatePopup();
    bool installed = baseSnap.pluginInstalled;

    std::thread([cfgCopy, updCopy, baseSnap, currentVer, allowAutoApply, installed]() mutable {
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::CheckAndMaybeUpdate;
        res->snapshot = std::move(baseSnap);
        res->snapshot.updateChecked = true;

        UpdateCheckResult check = CheckForUpdate(updCopy, currentVer, cfgCopy.portableRoot.empty() ? GetDistribution(cfgCopy.pluginDirectory) : L"portable");
        if (!check.ok) {
            res->ok = false;
            res->message = check.error;
            PostWorkResult(std::move(res));
            return;
        }

        res->ok = true;
        if (!check.hasUpdate || res->snapshot.availableUpdate.version != check.manifest.version) {
            res->snapshot.updateDownloaded = false;
            res->snapshot.waitingAntigravityExit = false;
            res->snapshot.downloadedZipPath.clear();
        }
        res->snapshot.updateAvailable = check.hasUpdate;
        res->snapshot.availableUpdate = check.manifest;
        if (!check.hasUpdate) {
            res->message = L"当前已是最新版本 (v" + currentVer + L")";
            PostWorkResult(std::move(res));
            return;
        }

        if (allowAutoApply && cfgCopy.autoUpdate && installed) {
            PostMessageW(g_app.hwnd, WM_APP_UPDATE_PROGRESS, 0, 0);
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
        PostWorkResult(std::move(res));
    }).detach();
}

void StartDownloadAndApplyWorker() {
    if (g_app.busyUpdate.exchange(true)) return;
    g_app.updatePhase = UpdatePhase::Downloading;
    g_app.updateError.clear();
    SyncControlsToUi();
    ShowUpdatePopup();
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
            PostWorkResult(std::move(res));
            return;
        }

        std::wstring zipPath = snapCopy.downloadedZipPath;
        if (zipPath.empty() || !FileExists(zipPath)) {
            std::wstring dlErr;
            if (!DownloadAndVerifyUpdate(updCopy, snapCopy.availableUpdate, JoinPath(cfgCopy.dataDirectory, L"updates"), zipPath, dlErr)) {
                res->ok = false;
                res->message = dlErr;
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
        g_app.updatePhase = UpdatePhase::DownloadFailed;
        g_app.updateError = err;
        SyncUpdatePopup();
        if (IsWindowVisible(g_app.hwnd)) ShowUpdatePopup();
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
        std::wstring appCfg = ApprovalConfigPath(cfgCopy);
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

void StartProtectedDelegationWorker(bool enable) {
    if (g_app.busyAction.exchange(true)) return;
    PanelConfig cfgCopy;
    {
        std::lock_guard<std::mutex> lk(g_app.cfgMutex);
        cfgCopy = g_app.cfg;
    }
    std::thread([cfgCopy, enable]() {
        std::wstring dotnet = GetDotnetExe(cfgCopy);
        std::wstring dll = GetAssemblyDll(cfgCopy);
        std::wstring appCfg = ApprovalConfigPath(cfgCopy);
        std::wstring args = L"\"" + dll + L"\" set-protected-delegation --config \"" + appCfg + L"\" --enabled " + (enable ? L"true" : L"false");
        CommandResult cr = RunHiddenCommand(dotnet, args, cfgCopy.pluginDirectory, 8000);

        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::ToggleProtectedDelegation;
        res->targetProtectedDelegation = enable;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0;
        if (!res->ok) {
            res->message = L"切换受保护目录审核失败: " + Utf8ToWide(cr.stderrUtf8);
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
        std::wstring appCfg = ApprovalConfigPath(cfgCopy);
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

bool IsPathWithinDirectory(const std::wstring& path, const std::wstring& directory) {
    if (path.empty() || directory.empty()) return false;
    wchar_t fullPath[MAX_PATH * 2]{}, fullDir[MAX_PATH * 2]{};
    DWORD pathLen = GetFullPathNameW(path.c_str(), static_cast<DWORD>(std::size(fullPath)), fullPath, nullptr);
    DWORD dirLen = GetFullPathNameW(directory.c_str(), static_cast<DWORD>(std::size(fullDir)), fullDir, nullptr);
    if (pathLen == 0 || pathLen >= std::size(fullPath) || dirLen == 0 || dirLen >= std::size(fullDir)) return false;
    std::wstring normPath(fullPath, pathLen);
    std::wstring normDir(fullDir, dirLen);
    while (normDir.size() > 3 && (normDir.back() == L'\\' || normDir.back() == L'/')) normDir.pop_back();
    if (normDir.empty()) return false;
    if (normDir.back() != L'\\') normDir.push_back(L'\\');
    if (normPath.size() < normDir.size()) return false;
    return _wcsnicmp(normPath.c_str(), normDir.c_str(), normDir.size()) == 0;
}

bool CopyDirectoryTree(const std::wstring& sourceDir, const std::wstring& destDir) {
    if (!EnsureDirectoryTree(destDir)) return false;
    WIN32_FIND_DATAW fd{};
    std::wstring pattern = JoinPath(sourceDir, L"*");
    HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    bool ok = true;
    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring src = JoinPath(sourceDir, name);
        std::wstring dst = JoinPath(destDir, name);
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            if ((fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                ok = false;
                break;
            }
            if (!CopyDirectoryTree(src, dst)) {
                ok = false;
                break;
            }
        } else {
            if (!CopyFileW(src.c_str(), dst.c_str(), FALSE)) {
                ok = false;
                break;
            }
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return ok;
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
    std::wstring exePath = GetExecutablePath();
    std::wstring exeDir = GetDirectoryName(exePath);

    // When invoked from inside the installed plugin directory, Install.ps1 replaces pluginDirectory
    // and cannot run while this panel holds file/working-directory locks inside it.
    if (IsPathWithinDirectory(exePath, cfgCopy.pluginDirectory)) {
        if (!cfgCopy.antigravityPath.empty() && IsProcessRunningByPath(cfgCopy.antigravityPath)) {
            g_app.busyAction = false;
            MessageBoxW(g_app.hwnd, L"请先完全退出 Antigravity，再修复插件。", L"修复插件", MB_OK | MB_ICONINFORMATION);
            return;
        }
        std::wstring updatesDir = JoinPath(cfgCopy.dataDirectory, L"updates");
        std::wstring stagedBundle = JoinPath(updatesDir, L"repair-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
        if (!CopyDirectoryTree(cfgCopy.pluginDirectory, stagedBundle)) {
            g_app.busyAction = false;
            MessageBoxW(g_app.hwnd, L"无法创建临时修复目录，请确认数据目录可写后重试。", L"修复插件", MB_OK | MB_ICONERROR);
            return;
        }
        std::wstring stagedScript = JoinPath(stagedBundle, L"scripts\\Install.ps1");
        if (!FileExists(stagedScript)) {
            g_app.busyAction = false;
            MessageBoxW(g_app.hwnd, L"缺少安装脚本 Install.ps1，无法执行修复。", L"修复插件", MB_OK | MB_ICONERROR);
            return;
        }
        wchar_t sysDir[MAX_PATH]{};
        GetSystemDirectoryW(sysDir, static_cast<DWORD>(std::size(sysDir)));
        std::wstring psExe = JoinPath(sysDir, L"WindowsPowerShell\\v1.0\\powershell.exe");
        std::wstring args = L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + stagedScript + L"\"" +
                            L" -BundlePath \"" + stagedBundle + L"\"" +
                            L" -GeminiRoot \"" + cfgCopy.geminiRoot + L"\"" +
                            L" -DataDirectory \"" + cfgCopy.dataDirectory + L"\"" +
                            L" -WaitPid " + std::to_wstring(GetCurrentProcessId()) +
                            L" -RelaunchPanel -ShowResult -CleanupBundlePath";
        if (!cfgCopy.antigravityPath.empty()) args += L" -AntigravityPath \"" + cfgCopy.antigravityPath + L"\"";
        if (!LaunchDetached(psExe, args, sysDir, true)) {
            g_app.busyAction = false;
            MessageBoxW(g_app.hwnd, L"无法启动独立修复进程。", L"修复插件", MB_OK | MB_ICONERROR);
            return;
        }
        if (g_app.trayAdded) {
            Shell_NotifyIconW(NIM_DELETE, &g_app.nid);
            g_app.trayAdded = false;
        }
        DestroyWindow(g_app.hwnd);
        return;
    }

    std::thread([cfgCopy, snapBase, exeDir]() mutable {
        wchar_t sysDir[MAX_PATH]{};
        GetSystemDirectoryW(sysDir, static_cast<DWORD>(std::size(sysDir)));
        std::wstring psExe = JoinPath(sysDir, L"WindowsPowerShell\\v1.0\\powershell.exe");

        std::wstring script = GetLifecycleScriptPath(cfgCopy, exeDir, L"Install.ps1");
        std::wstring workDir = GetDirectoryName(script);
        if (IsPathWithinDirectory(workDir, cfgCopy.pluginDirectory)) {
            workDir = sysDir;
        }
        std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -GeminiRoot \"" + cfgCopy.geminiRoot +
                            L"\" -DataDirectory \"" + cfgCopy.dataDirectory + L"\"";
        if (!cfgCopy.antigravityPath.empty()) args += L" -AntigravityPath \"" + cfgCopy.antigravityPath + L"\"";

        CommandResult cr = RunHiddenCommand(psExe, args, workDir, cfgCopy.portableRoot.empty() ? 45000 : 120000);
        QueryCoreSnapshot(cfgCopy, snapBase, false, true);
        auto res = std::make_unique<WorkResult>();
        res->kind = WorkKind::InstallOrRepair;
        res->ok = cr.started && !cr.timedOut && cr.exitCode == 0;
        res->snapshot = std::move(snapBase);
        if (res->ok) {
            res->message = cfgCopy.portableRoot.empty() ? L"插件已成功安装并启用审批服务。" : L"已连接 Antigravity，配置和审批日志保存在当前文件夹。";
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
        cfg.portableRoot.empty() ? L"面板将退出。卸载会移除已安装的插件，并永久删除本地审批日志、统计、设置和备份。\n\n确认完整卸载吗？" : L"面板将退出并断开与 Antigravity 的连接。配置和审批日志会保留在当前文件夹。\n\n确认断开连接吗？",
        cfg.portableRoot.empty() ? L"完整卸载 Gravity Guardian" : L"断开连接", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
    g_app.uninstallPromptOpen = false;
    if (answer != IDYES) return;

    wchar_t systemDir[MAX_PATH]{};
    GetSystemDirectoryW(systemDir, static_cast<DWORD>(std::size(systemDir)));
    std::wstring powershell = JoinPath(systemDir, L"WindowsPowerShell\\v1.0\\powershell.exe");
    std::wstring args = L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
        L"\" -DataDirectory \"" + cfg.dataDirectory + L"\"" + (cfg.portableRoot.empty() ? L" -PurgeData" : L"") + L" -WaitPid " + std::to_wstring(GetCurrentProcessId()) +
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
            const auto appCfg = ApprovalConfigPath(cfgCopy);
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

bool HasFontFamily(HDC hdc, const wchar_t* face) {
    bool found = false;
    LOGFONTW query{};
    query.lfCharSet = DEFAULT_CHARSET;
    wcsncpy_s(query.lfFaceName, face, _TRUNCATE);
    EnumFontFamiliesExW(
        hdc, &query,
        [](const LOGFONTW*, const TEXTMETRICW*, DWORD, LPARAM param) -> int {
            *reinterpret_cast<bool*>(param) = true;
            return 0;
        },
        reinterpret_cast<LPARAM>(&found), 0);
    return found;
}

void CreateFonts(HWND hwnd) {
    HDC screen = GetDC(hwnd);
    auto choose = [&](std::initializer_list<const wchar_t*> faces) {
        for (auto face : faces) {
            if (screen && HasFontFamily(screen, face)) return face;
        }
        return *faces.begin();
    };
    const wchar_t* displayFace = choose({L"SF Pro Display", L"SF Pro", L"Segoe UI Variable Display", L"Segoe UI"});
    const wchar_t* textFace = choose({L"SF Pro Text", L"SF Pro", L"Segoe UI Variable Text", L"Segoe UI"});
    const wchar_t* smallFace = choose({L"SF Pro Text", L"SF Pro", L"Segoe UI Variable Small", L"Segoe UI"});
    const wchar_t* cjkFace = choose({L"PingFang SC", L"Noto Sans SC", L"Microsoft YaHei UI"});
    if (screen) ReleaseDC(hwnd, screen);

    auto make = [&](int size, int weight, const wchar_t* face) {
        return CreateFontW(-Scale(hwnd, size), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
    };
    // Use installed Apple faces when available, with explicit Latin/CJK fallbacks
    // so mixed-language labels do not inherit oversized Windows FontLink metrics.
    g_app.fontTitle = make(11, FW_MEDIUM, displayFace);
    g_app.fontHeading = make(11, FW_MEDIUM, cjkFace);
    g_app.fontBold = make(11, FW_MEDIUM, cjkFace);
    g_app.fontRegular = make(11, FW_NORMAL, cjkFace);
    g_app.fontSmall = make(10, FW_NORMAL, cjkFace);
    g_app.fontSmallLatin = make(10, FW_NORMAL, smallFace);
    g_app.fontDialogTitle = make(14, FW_MEDIUM, cjkFace);
    g_app.fontMetric = make(24, FW_MEDIUM, displayFace);
    g_app.fontSubMetric = make(11, FW_MEDIUM, textFace);
}

LRESULT CALLBACK ControlSubclass(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam, UINT_PTR id, DWORD_PTR data) {
    if (data == 1 && msg == WM_NCHITTEST) return HTTRANSPARENT;
    if (data == 0 && msg == WM_MOUSEMOVE && g_app.hoveredControl != hwnd) {
        if (g_app.hoveredControl) InvalidateRect(g_app.hoveredControl, nullptr, FALSE);
        g_app.hoveredControl = hwnd;
        TRACKMOUSEEVENT tracking{sizeof(tracking), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tracking);
        InvalidateRect(hwnd, nullptr, FALSE);
    } else if (msg == WM_MOUSELEAVE && g_app.hoveredControl == hwnd) {
        g_app.hoveredControl = nullptr;
        InvalidateRect(hwnd, nullptr, FALSE);
    } else if (data == 0 && msg == WM_SETCURSOR && IsWindowEnabled(hwnd)) {
        SetCursor(LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
    } else if (msg == WM_NCDESTROY) {
        if (g_app.hoveredControl == hwnd) g_app.hoveredControl = nullptr;
        RemoveWindowSubclass(hwnd, ControlSubclass, id);
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

void CreateChildControls(HWND hwnd) {
    CreateFonts(hwnd);
    auto label = [&](const wchar_t* txt, DWORD style = SS_LEFT) {
        return CreateWindowExW(0, L"STATIC", txt, WS_CHILD | SS_NOPREFIX | SS_NOTIFY | style,
                               0, 0, 0, 0, hwnd, nullptr, g_app.hInst, nullptr);
    };
    auto button = [&](const wchar_t* txt, int id, DWORD style = BS_OWNERDRAW) {
        HWND control = CreateWindowExW(0, L"BUTTON", txt, WS_CHILD | WS_TABSTOP | style,
                               0, 0, 0, 0, hwnd, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g_app.hInst, nullptr);
        SetWindowSubclass(control, ControlSubclass, 1, 0);
        return control;
    };

    g_app.lblTitle = label(L"Gravity Guardian");
    SetWindowSubclass(g_app.lblTitle, ControlSubclass, 1, 1);
    g_app.btnHeaderUpdate = button(L"检查应用更新", ID_BTN_CHECK_UPDATE);
    g_app.btnGitHub = button(L"打开 GitHub 项目", ID_BTN_GITHUB);
    g_app.btnRefresh = button(L"刷新状态与统计", ID_BTN_REFRESH);
    g_app.btnHide = button(L"关闭窗口并收回托盘", ID_BTN_HIDE);
    g_app.lblStatus = label(L"", SS_ENDELLIPSIS);
    g_app.btnApprovalTakeover = button(L"接管状态未知", ID_BTN_APPROVAL_TAKEOVER);
    g_app.btnServiceAction = button(L"启动服务", ID_BTN_SERVICE_ACTION);
    g_app.btnLaunchAg = button(L"启动 Antigravity", ID_BTN_LAUNCH_AG);
    g_app.lblUpdateBanner = label(L"");
    g_app.btnUpdateNow = button(L"立即更新", ID_BTN_UPDATE_NOW);
    g_app.lblStatsTitle = label(L"今日审批");
    g_app.btnStatsDate = button(L"选择审批日期", ID_BTN_STATS_DATE);
    g_app.lblStatsCount = label(L"");
    g_app.lblStatsSub = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsTokens = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsTokenDetail = label(L"");
    g_app.lblStatsInputTitle = label(L"输入");
    g_app.lblStatsOutputTitle = label(L"输出");
    g_app.lblStatsCacheTitle = label(L"缓存命中率");
    g_app.lblStatsOutput = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsCacheRate = label(L"", SS_ENDELLIPSIS);
    g_app.lblStatsCost = label(L"", SS_RIGHT | SS_ENDELLIPSIS);
    g_app.lblPricingTitle = label(L"计价基准");
    g_app.lblPricingNote = label(L"", SS_ENDELLIPSIS);
    g_app.btnOpenPricing = button(L"修改单价", ID_BTN_OPEN_PRICING);

    g_app.lblAppsTitle = label(L"应用与插件");
    g_app.lblAgTitle = label(L"Antigravity");
    g_app.lblAgPath = label(L"", SS_PATHELLIPSIS);
    g_app.btnBrowseAg = button(L"更改…", ID_BTN_BROWSE_AG);
    g_app.lblGuardianTitle = label(L"审批账号");
    g_app.lblGuardianAuth = label(L"", SS_ENDELLIPSIS);
    g_app.btnDetectEnv = button(L"检测", ID_BTN_DETECT_ENV);
    g_app.btnInstallRepair = button(g_app.cfg.portableRoot.empty() ? L"安装 / 修复插件" : L"连接 / 修复连接", ID_BTN_INSTALL_REPAIR);
    g_app.btnUninstall = button(g_app.cfg.portableRoot.empty() ? L"完整卸载" : L"断开连接", ID_BTN_UNINSTALL);

    g_app.btnPreferences = button(L"偏好设置", ID_BTN_PREFERENCES);
    g_app.chkDetailedLogs = button(L"详细调试日志", ID_CHK_DETAILED_LOGS);
    g_app.lblLogBadge = label(L"", SS_RIGHT);
    g_app.lblLogSize = label(L"");
    g_app.btnOpenLogs = button(L"打开日志", ID_BTN_OPEN_LOGS);
    g_app.btnCompactLogs = button(L"压缩清理", ID_BTN_COMPACT_LOGS);
    g_app.chkProtectedDelegation = button(L"受保护目录交由插件审核", ID_CHK_PROTECTED_DELEGATION);
    g_app.chkAutostart = button(L"开机自启 · 收回托盘", ID_CHK_AUTOSTART);
    g_app.chkAutoUpdate = button(L"启动时自动更新", ID_CHK_AUTO_UPDATE);
    g_app.lblVersionInfo = label(L"");
    g_app.btnCheckUpdate = button(L"检查更新", ID_BTN_CHECK_UPDATE);
    g_app.scrollbar = CreateWindowExW(0, L"SCROLLBAR", nullptr, WS_CHILD | SBS_VERT,
        0, 0, 0, 0, hwnd, nullptr, g_app.hInst, nullptr);

    g_app.tooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        hwnd, nullptr, g_app.hInst, nullptr);
    SendMessageW(g_app.tooltip, TTM_SETMAXTIPWIDTH, 0, Scale(hwnd, 360));
    for (HWND control : {g_app.btnHeaderUpdate, g_app.btnGitHub, g_app.btnRefresh, g_app.btnHide,
                         g_app.btnStatsDate, g_app.btnApprovalTakeover, g_app.lblStatus, g_app.lblAgPath,
                         g_app.lblStatsSub, g_app.lblStatsTokenDetail, g_app.lblStatsCacheTitle,
                         g_app.lblStatsCacheRate, g_app.chkProtectedDelegation, g_app.btnCheckUpdate}) {
        wchar_t text[96]{};
        GetWindowTextW(control, text, static_cast<int>(std::size(text)));
        TOOLINFOW tool{sizeof(tool)};
        tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
        tool.hwnd = hwnd;
        tool.uId = reinterpret_cast<UINT_PTR>(control);
        tool.lpszText = text;
        SendMessageW(g_app.tooltip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    }
    SetControlTooltip(g_app.lblStatsCacheTitle, L"缓存命中率 = 缓存 Token ÷ 输入 Token");
    SetControlTooltip(g_app.lblStatsCacheRate, L"缓存命中率 = 缓存 Token ÷ 输入 Token");
    SetControlTooltip(g_app.chkProtectedDelegation,
        L"开启后，工作区 .cache 读写与 .git / .vscode 只读会跳过原生无来源弹窗并由 Codex Guardian 逐次审核；暂停接管、停止服务或卸载时自动撤销（不包含 .git 写入和 .env / .ssh）。");
}

struct PanelLayout {
    int stats = 116 + (g_app.state.updateAvailable ? kBannerSpace : 0);
    int pricing = stats + 172;
    int apps = pricing + 64;
    int prefs = apps + 212;
    int height = prefs + 36 + (g_app.preferencesOpen ? kPreferencesSpace : 0);
};

void PositionControls(const PanelLayout& layout) {
    auto& a = g_app;
    auto S = [&](int dip) { return Scale(a.hwnd, dip); };
    auto place = [&](HWND control, HFONT font, int x, int y, int w, int h, bool show = true, bool header = false) {
        if (reinterpret_cast<HFONT>(SendMessageW(control, WM_GETFONT, 0, 0)) != font)
            SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
        const int top = S(y) - (header ? 0 : a.scrollY);
        SetWindowPos(control, nullptr, S(x), top, S(w), S(h),
                     SWP_NOZORDER | SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
        // The custom title bar stays fixed when a short display needs scrolling.
        const int clipped = header ? 0 : std::clamp(S(kHeaderHeight) - top, 0, S(h));
        SetWindowRgn(control, clipped ? CreateRectRgn(0, clipped, S(w), S(h)) : nullptr, TRUE);
    };
    place(a.lblTitle, a.fontTitle, 30, 11, 138, 16, true, true);
    place(a.btnHeaderUpdate, a.fontRegular, 174, 7, 22, 22, true, true);
    place(a.btnGitHub, a.fontRegular, 196, 7, 22, 22, true, true);
    place(a.btnRefresh, a.fontRegular, 218, 7, 22, 22, true, true);
    place(a.btnHide, a.fontRegular, 240, 7, 22, 22, true, true);
    place(a.lblStatus, a.fontRegular, 24, 53, a.state.pluginInstalled ? 202 : 238, 16);
    place(a.btnApprovalTakeover, a.fontSmall, 232, 50, 30, 20, a.state.pluginInstalled);
    place(a.btnServiceAction, a.fontSmall, 10, 80, 74, 25);
    place(a.btnLaunchAg, a.fontRegular, 90, 80, 172, 25);
    place(a.lblUpdateBanner, a.fontSmall, 10, 123, 176, 30, a.state.updateAvailable);
    place(a.btnUpdateNow, a.fontSmall, 190, 126, 72, 24, a.state.updateAvailable);

    const int stats = layout.stats;
    place(a.lblStatsTitle, a.fontHeading, 10, stats + 15, 222, 17);
    place(a.btnStatsDate, a.fontRegular, 240, stats + 11, 22, 22);
    place(a.lblStatsCount, a.fontMetric, 10, stats + 41, 166, 30);
    place(a.lblStatsCost, a.fontSmall, 180, stats + 53, 82, 15);
    place(a.lblStatsSub, a.fontSmall, 10, stats + 80, 252, 16);
    place(a.lblStatsInputTitle, a.fontSmall, 10, stats + 113, 96, 15);
    place(a.lblStatsOutputTitle, a.fontSmall, 116, stats + 113, 68, 15);
    place(a.lblStatsCacheTitle, a.fontSmall, 194, stats + 113, 68, 15);
    place(a.lblStatsTokens, a.fontSubMetric, 10, stats + 132, 96, 17);
    place(a.lblStatsOutput, a.fontSubMetric, 116, stats + 132, 68, 17);
    place(a.lblStatsCacheRate, a.fontSubMetric, 194, stats + 132, 68, 17);
    place(a.lblStatsTokenDetail, a.fontSmall, 10, stats + 153, 252, 14);

    const int pricing = layout.pricing;
    place(a.lblPricingTitle, a.fontHeading, 10, pricing + 14, 172, 17);
    place(a.lblPricingNote, a.fontSmall, 10, pricing + 37, 252, 15);
    place(a.btnOpenPricing, a.fontSmall, 204, pricing + 11, 58, 24);

    const int apps = layout.apps;
    place(a.lblAppsTitle, a.fontHeading, 10, apps + 15, 252, 17);
    place(a.lblAgTitle, a.fontRegular, 32, apps + 47, 184, 17);
    place(a.lblAgPath, a.fontSmall, 32, apps + 69, 184, 15);
    place(a.btnBrowseAg, a.fontSmall, 222, apps + 51, 40, 24);
    place(a.lblGuardianTitle, a.fontRegular, 32, apps + 109, 184, 17);
    place(a.lblGuardianAuth, a.fontSmall, 32, apps + 131, 184, 15);
    place(a.btnDetectEnv, a.fontSmall, 222, apps + 113, 40, 24);
    place(a.btnInstallRepair, a.fontSmall, 10, apps + 169, 122, 25);
    place(a.btnUninstall, a.fontSmall, 140, apps + 169, 122, 25);

    const int prefs = layout.prefs;
    place(a.btnPreferences, a.fontSmall, 10, prefs, 252, 36);
    const bool expanded = a.preferencesOpen;
    place(a.chkDetailedLogs, a.fontRegular, 10, prefs + 47, 158, 20, expanded);
    place(a.lblLogBadge, a.fontSmall, 174, prefs + 50, 88, 15, expanded);
    place(a.lblLogSize, a.fontSmall, 10, prefs + 77, 120, 15, expanded);
    place(a.btnOpenLogs, a.fontSmall, 136, prefs + 73, 60, 24, expanded);
    place(a.btnCompactLogs, a.fontSmall, 202, prefs + 73, 60, 24, expanded);
    place(a.chkProtectedDelegation, a.fontRegular, 10, prefs + 109, 252, 20, expanded);
    place(a.chkAutostart, a.fontRegular, 10, prefs + 135, 252, 20, expanded);
    place(a.chkAutoUpdate, a.fontRegular, 10, prefs + 161, 252, 20, expanded);
    place(a.lblVersionInfo, a.fontSmallLatin, 10, prefs + 204, 180, 15, expanded);
    place(a.btnCheckUpdate, a.fontSmall, 202, prefs + 199, 60, 24, expanded);

    RECT client{};
    GetClientRect(a.hwnd, &client);
    const int scrollWidth = GetSystemMetricsForDpi(SM_CXVSCROLL, GetDpiForWindow(a.hwnd));
    SetWindowPos(a.scrollbar, nullptr, client.right - scrollWidth, S(kHeaderHeight), scrollWidth,
                 std::max(0L, client.bottom - S(kHeaderHeight)), SWP_NOZORDER | SWP_NOACTIVATE |
                 (a.needsScroll ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));

    InvalidateRect(a.hwnd, nullptr, FALSE);
}

void SetPanelScroll(int proposed) {
    PanelLayout layout;
    RECT client{};
    GetClientRect(g_app.hwnd, &client);
    int total = Scale(g_app.hwnd, layout.height);
    g_app.scrollY = std::clamp(proposed, 0, std::max(0, total - static_cast<int>(client.bottom)));
    const int header = Scale(g_app.hwnd, kHeaderHeight);
    SCROLLINFO info{sizeof(info), SIF_RANGE | SIF_PAGE | SIF_POS, 0, total - header - 1,
                    static_cast<UINT>(std::max(0L, client.bottom - header)), g_app.scrollY, 0};
    SetScrollInfo(g_app.scrollbar, SB_CTL, &info, TRUE);
    PositionControls(layout);
}

void ScrollFocusIntoView(HWND hwnd) {
    auto focus = GetFocus();
    if (!focus || !IsChild(hwnd, focus) || !g_app.needsScroll) return;

    RECT bounds{}, client{};
    GetWindowRect(focus, &bounds);
    MapWindowPoints(HWND_DESKTOP, hwnd, reinterpret_cast<POINT*>(&bounds), 2);
    GetClientRect(hwnd, &client);
    const int padding = Scale(hwnd, 8);
    if (bounds.top < Scale(hwnd, kHeaderHeight) &&
        (focus == g_app.btnHeaderUpdate || focus == g_app.btnGitHub || focus == g_app.btnRefresh || focus == g_app.btnHide)) return;
    const int top = Scale(hwnd, kHeaderHeight) + padding;
    if (bounds.top < top) SetPanelScroll(g_app.scrollY + bounds.top - top);
    else if (bounds.bottom > client.bottom - padding) SetPanelScroll(g_app.scrollY + bounds.bottom - client.bottom + padding);
}

void ResizePanelToContent() {
    auto hwnd = g_app.hwnd;
    auto dpi = GetDpiForWindow(hwnd);
    PanelLayout layout;
    RECT frame{0, 0, Scale(hwnd, kPanelWidth), Scale(hwnd, layout.height)};
    RECT bounds{};
    GetWindowRect(hwnd, &bounds);
    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    const RECT& work = monitor.rcWork;
    LONG width = frame.right - frame.left;
    LONG height = frame.bottom - frame.top;
    const bool scroll = height > work.bottom - work.top;
    g_app.needsScroll = scroll;
    if (scroll) {
        height = work.bottom - work.top;
        width += GetSystemMetricsForDpi(SM_CXVSCROLL, dpi);
    }
    LONG x = std::clamp(bounds.left, work.left, std::max(work.left, work.right - width));
    LONG y = std::clamp(bounds.top, work.top, work.bottom - height);
    if (bounds.left != x || bounds.top != y || bounds.right != x + width || bounds.bottom != y + height)
        SetWindowPos(hwnd, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    SetPanelScroll(g_app.scrollY);
}

void FillRoundedRect(HDC hdc, RECT r, int radius, COLORREF fill, COLORREF border) {
    Gdiplus::Graphics graphics(hdc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    const float x = static_cast<float>(r.left) + 0.5f;
    const float y = static_cast<float>(r.top) + 0.5f;
    const float w = static_cast<float>(r.right - r.left) - 1.0f;
    const float h = static_cast<float>(r.bottom - r.top) - 1.0f;
    const float d = std::min({static_cast<float>(radius), w, h});
    Gdiplus::GraphicsPath path;
    path.AddArc(x, y, d, d, 180.0f, 90.0f);
    path.AddArc(x + w - d, y, d, d, 270.0f, 90.0f);
    path.AddArc(x + w - d, y + h - d, d, d, 0.0f, 90.0f);
    path.AddArc(x, y + h - d, d, d, 90.0f, 90.0f);
    path.CloseFigure();
    Gdiplus::SolidBrush brush(Gdiplus::Color(255, GetRValue(fill), GetGValue(fill), GetBValue(fill)));
    Gdiplus::Pen pen(Gdiplus::Color(255, GetRValue(border), GetGValue(border), GetBValue(border)), 1.0f);
    graphics.FillPath(&brush, &path);
    if (fill != border) graphics.DrawPath(&pen, &path);
}

void DrawLineIcon(HDC hdc, RECT bounds, int id, COLORREF ink) {
    using Gdiplus::PointF;
    Gdiplus::Graphics graphics(hdc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.TranslateTransform(static_cast<float>(bounds.left), static_cast<float>(bounds.top));
    graphics.ScaleTransform(static_cast<float>(bounds.right - bounds.left) / 24.0f,
                            static_cast<float>(bounds.bottom - bounds.top) / 24.0f);
    Gdiplus::Pen pen(Gdiplus::Color(255, GetRValue(ink), GetGValue(ink), GetBValue(ink)), 1.5f);
    pen.SetStartCap(Gdiplus::LineCapRound);
    pen.SetEndCap(Gdiplus::LineCapRound);
    pen.SetLineJoin(Gdiplus::LineJoinRound);
    auto line = [&](float x1, float y1, float x2, float y2) { graphics.DrawLine(&pen, x1, y1, x2, y2); };
    if (id == ID_BTN_HIDE || id == ID_UPDATE_CLOSE) {
        line(6, 6, 18, 18);
        line(18, 6, 6, 18);
    } else if (id == ID_BTN_CHECK_UPDATE) {
        graphics.DrawEllipse(&pen, 3.0f, 3.0f, 18.0f, 18.0f);
        line(12, 17, 12, 7);
        line(8, 11, 12, 7);
        line(12, 7, 16, 11);
    } else if (id == ID_ICON_UPDATE_SUCCESS) {
        graphics.DrawEllipse(&pen, 3.0f, 3.0f, 18.0f, 18.0f);
        line(7, 12, 10, 15);
        line(10, 15, 17, 8);
    } else if (id == ID_ICON_UPDATE_ERROR) {
        graphics.DrawEllipse(&pen, 3.0f, 3.0f, 18.0f, 18.0f);
        line(12, 7, 12, 13);
        line(12, 16, 12, 16.2f);
    } else if (id == ID_BTN_REFRESH) {
        graphics.DrawArc(&pen, 4.0f, 4.0f, 16.0f, 16.0f, 40.0f, 295.0f);
        PointF arrow[] = {{15, 3}, {20, 5}, {18, 10}};
        graphics.DrawLines(&pen, arrow, static_cast<INT>(std::size(arrow)));
    } else if (id == ID_BTN_GITHUB) {
        Gdiplus::GraphicsPath cat;
        cat.AddLine(9.0f, 21.0f, 9.0f, 17.0f);
        cat.AddBezier(9.0f, 17.0f, 2.0f, 17.0f, 3.0f, 10.0f, 5.5f, 7.0f);
        cat.AddBezier(5.5f, 7.0f, 5.0f, 6.0f, 5.0f, 4.0f, 5.5f, 3.0f);
        cat.AddLine(5.5f, 3.0f, 9.0f, 4.5f);
        cat.AddBezier(9.0f, 4.5f, 11.0f, 4.0f, 13.0f, 4.0f, 15.0f, 4.5f);
        cat.AddLine(15.0f, 4.5f, 18.5f, 3.0f);
        cat.AddBezier(18.5f, 3.0f, 19.0f, 4.0f, 19.0f, 6.0f, 18.5f, 7.0f);
        cat.AddBezier(18.5f, 7.0f, 21.0f, 10.0f, 22.0f, 17.0f, 15.0f, 17.0f);
        cat.AddLine(15.0f, 17.0f, 15.0f, 21.0f);
        graphics.DrawPath(&pen, &cat);
        Gdiplus::GraphicsPath tail;
        tail.AddBezier(9.0f, 19.0f, 4.0f, 21.0f, 4.0f, 16.0f, 2.0f, 16.0f);
        graphics.DrawPath(&pen, &tail);
    } else if (id == ID_BTN_STATS_DATE) {
        graphics.DrawRectangle(&pen, 4.0f, 5.0f, 16.0f, 16.0f);
        line(4, 10, 20, 10);
        line(8, 3, 8, 7);
        line(16, 3, 16, 7);
    } else if (id == ID_BTN_PREFERENCES) {
        graphics.DrawEllipse(&pen, 5.0f, 5.0f, 14.0f, 14.0f);
        graphics.DrawEllipse(&pen, 9.0f, 9.0f, 6.0f, 6.0f);
        for (int i = 0; i < 8; ++i) {
            const float angle = static_cast<float>(i) * 3.14159265f / 4.0f;
            line(12.0f + std::cos(angle) * 7.0f, 12.0f + std::sin(angle) * 7.0f,
                 12.0f + std::cos(angle) * 9.0f, 12.0f + std::sin(angle) * 9.0f);
        }
    } else if (id == ID_BTN_BROWSE_AG) {
        graphics.DrawRectangle(&pen, 3.0f, 4.0f, 18.0f, 12.0f);
        line(12, 16, 12, 21);
        line(7, 21, 17, 21);
    } else if (id == ID_BTN_DETECT_ENV) {
        graphics.DrawRectangle(&pen, 3.0f, 4.0f, 18.0f, 16.0f);
        line(7, 9, 10, 12);
        line(10, 12, 7, 15);
        line(13, 15, 17, 15);
    }
}

void DrawOwnerButton(const DRAWITEMSTRUCT& item) {
    HDC hdc = item.hDC;
    RECT rc = item.rcItem;
    auto S = [&](int dp) { return Scale(g_app.hwnd, dp); };
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool hovered = !disabled && g_app.hoveredControl == item.hwndItem;
    const bool takeover = item.CtlID == ID_BTN_APPROVAL_TAKEOVER;
    const bool checkbox = item.CtlID == ID_CHK_DETAILED_LOGS || item.CtlID == ID_CHK_PROTECTED_DELEGATION || item.CtlID == ID_CHK_AUTOSTART || item.CtlID == ID_CHK_AUTO_UPDATE;
    const bool primary = item.CtlID == ID_BTN_LAUNCH_AG || item.CtlID == ID_UPDATE_PRIMARY;
    const bool disclosure = item.CtlID == ID_BTN_PREFERENCES;
    const bool danger = item.CtlID == ID_BTN_UNINSTALL;
    const bool header = item.hwndItem == g_app.btnHeaderUpdate || item.hwndItem == g_app.btnGitHub ||
                        item.hwndItem == g_app.btnRefresh || item.hwndItem == g_app.btnHide;
    const bool iconOnly = header || item.CtlID == ID_BTN_STATS_DATE || item.CtlID == ID_UPDATE_CLOSE;
    const bool focus = (item.itemState & ODS_FOCUS) && !(item.itemState & ODS_NOFOCUSRECT);
    FillRect(hdc, &rc, g_app.brushCard);
    COLORREF fill = pressed ? RGB(234, 236, 241) : hovered ? RGB(244, 245, 248) : RGB(255, 255, 255);
    COLORREF border = fill;
    COLORREF ink = disabled ? RGB(174, 174, 178) : danger ? kRed : iconOnly || disclosure ? kSecondary : kBlue;
    if (iconOnly) {
        fill = pressed ? RGB(229, 232, 238) : hovered ? RGB(236, 239, 244) : header ? kBackground : RGB(255, 255, 255);
        border = fill;
    } else if (disclosure) {
        fill = pressed ? RGB(238, 240, 244) : hovered ? kSubtleFill : kBackground;
        border = fill;
    }
    if (danger) {
        fill = pressed ? RGB(254, 226, 226) : hovered ? RGB(254, 242, 242) : RGB(255, 255, 255);
        border = fill;
    }
    if (primary) {
        fill = disabled ? kSubtleFill : pressed ? kBluePressed : hovered ? kBlueHover : kBlue;
        if (item.CtlID == ID_BTN_LAUNCH_AG) {
            fill = pressed ? RGB(221, 234, 249) : hovered ? RGB(235, 242, 252) : kSubtleFill;
        }
        border = fill;
        if (!disabled) ink = item.CtlID == ID_BTN_LAUNCH_AG ? kBlue : RGB(255, 255, 255);
    }
    if (focus) {
        FillRoundedRect(hdc, rc, S(16), RGB(56, 148, 246), RGB(56, 148, 246));
        InflateRect(&rc, -S(2), -S(2));
        FillRoundedRect(hdc, rc, S(12), RGB(255, 255, 255), RGB(255, 255, 255));
        InflateRect(&rc, -S(1), -S(1));
    } else if (pressed && !takeover && !checkbox) {
        InflateRect(&rc, -S(1), -S(1));
    }
    const int cy = (rc.top + rc.bottom) / 2;
    if (takeover) {
        const bool enabled = g_app.state.takeoverEnabled.value_or(false);
        const int cx = (rc.left + rc.right) / 2;
        const RECT track{cx - S(13), cy - S(7), cx + S(13), cy + S(7)};
        const COLORREF trackColor = disabled ? RGB(210, 214, 222) : enabled ? (hovered ? kBlueHover : kBlue) : RGB(199, 202, 210);
        FillRoundedRect(hdc, track, S(14), trackColor, trackColor);
        const int thumb = enabled ? track.right - S(7) : track.left + S(7);
        const RECT knob{thumb - S(5), cy - S(5), thumb + S(5), cy + S(5)};
        constexpr COLORREF white = RGB(255, 255, 255);
        FillRoundedRect(hdc, knob, S(10), white, white);
    } else if (checkbox) {
        bool checked = false;
        if (item.CtlID == ID_CHK_DETAILED_LOGS) checked = g_app.state.detailedLogs;
        else if (item.CtlID == ID_CHK_PROTECTED_DELEGATION) checked = g_app.state.delegateProtectedPaths;
        else {
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            checked = item.CtlID == ID_CHK_AUTOSTART ? g_app.cfg.autostart : g_app.cfg.autoUpdate;
        }
        const int boxSize = S(14);
        const RECT box{rc.left, cy - boxSize / 2, rc.left + boxSize, cy - boxSize / 2 + boxSize};
        const COLORREF boxFill = checked
            ? (disabled ? RGB(199, 202, 210) : hovered ? kBlueHover : kBlue)
            : (hovered ? RGB(244, 245, 248) : RGB(255, 255, 255));
        const COLORREF boxBorder = checked ? boxFill : (hovered ? RGB(180, 185, 196) : RGB(204, 209, 218));
        FillRoundedRect(hdc, box, S(8), boxFill, boxBorder);
        if (checked) {
            Gdiplus::Graphics graphics(hdc);
            graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            Gdiplus::Pen checkPen(Gdiplus::Color(255, 255, 255, 255), std::max(1.4f, static_cast<float>(S(15)) / 10.0f));
            checkPen.SetStartCap(Gdiplus::LineCapRound);
            checkPen.SetEndCap(Gdiplus::LineCapRound);
            checkPen.SetLineJoin(Gdiplus::LineJoinRound);
            const float x0 = static_cast<float>(box.left) + boxSize * 0.24f;
            const float y0 = static_cast<float>(box.top) + boxSize * 0.52f;
            const float x1 = static_cast<float>(box.left) + boxSize * 0.43f;
            const float y1 = static_cast<float>(box.top) + boxSize * 0.72f;
            const float x2 = static_cast<float>(box.left) + boxSize * 0.76f;
            const float y2 = static_cast<float>(box.top) + boxSize * 0.32f;
            Gdiplus::PointF pts[] = {{x0, y0}, {x1, y1}, {x2, y2}};
            graphics.DrawLines(&checkPen, pts, 3);
        }
        wchar_t text[96]{};
        GetWindowTextW(item.hwndItem, text, static_cast<int>(std::size(text)));
        auto oldFont = SelectObject(hdc, reinterpret_cast<HFONT>(SendMessageW(item.hwndItem, WM_GETFONT, 0, 0)));
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, disabled ? kTertiary : kText);
        RECT textRect = rc;
        textRect.left = box.right + S(8);
        DrawTextW(hdc, text, -1, &textRect, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(hdc, oldFont);
    } else {
        FillRoundedRect(hdc, rc, S(disclosure ? 20 : 14), fill, border);
    }
    if (iconOnly) {
        const int cx = (rc.left + rc.right) / 2;
        DrawLineIcon(hdc, {cx - S(6), cy - S(6), cx + S(6), cy + S(6)}, static_cast<int>(item.CtlID), ink);
        if (item.hwndItem == g_app.btnHeaderUpdate && g_app.state.updateAvailable) {
            FillRoundedRect(hdc, {rc.right - S(6), rc.top + S(3), rc.right - S(1), rc.top + S(8)}, S(5), kBlue, kBlue);
        }
    } else if (!takeover && !checkbox) {
        wchar_t text[96]{};
        GetWindowTextW(item.hwndItem, text, static_cast<int>(std::size(text)));
        auto oldFont = SelectObject(hdc, reinterpret_cast<HFONT>(SendMessageW(item.hwndItem, WM_GETFONT, 0, 0)));
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, ink);
        RECT textRect = rc;
        if (disclosure) textRect.left += S(20);
        DrawTextW(hdc, text, -1, &textRect, (disclosure ? DT_LEFT : DT_CENTER) | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(hdc, oldFont);
        if (disclosure) {
            DrawLineIcon(hdc, {rc.left, cy - S(6), rc.left + S(12), cy + S(6)}, ID_BTN_PREFERENCES, kSecondary);
            Gdiplus::Graphics graphics(hdc);
            graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            Gdiplus::Pen chevronPen(Gdiplus::Color(255, static_cast<BYTE>(kTertiary & 0xff),
                                                   static_cast<BYTE>((kTertiary >> 8) & 0xff),
                                                   static_cast<BYTE>((kTertiary >> 16) & 0xff)),
                                    std::max(1.3f, static_cast<float>(S(14)) / 10.0f));
            chevronPen.SetStartCap(Gdiplus::LineCapRound);
            chevronPen.SetEndCap(Gdiplus::LineCapRound);
            chevronPen.SetLineJoin(Gdiplus::LineJoinRound);
            const float x = static_cast<float>(rc.right - S(5));
            const float fcy = static_cast<float>(cy);
            const float arm = static_cast<float>(S(3));
            if (g_app.preferencesOpen) {
                Gdiplus::PointF arrow[] = {{x - arm, fcy - arm * 0.55f}, {x, fcy + arm * 0.55f}, {x + arm, fcy - arm * 0.55f}};
                graphics.DrawLines(&chevronPen, arrow, 3);
            } else {
                Gdiplus::PointF arrow[] = {{x - arm * 0.55f, fcy - arm}, {x + arm * 0.55f, fcy}, {x - arm * 0.55f, fcy + arm}};
                graphics.DrawLines(&chevronPen, arrow, 3);
            }
        }
    }
}

void PaintPanelSurface(HWND hwnd, HDC hdc) {
    RECT client{};
    GetClientRect(hwnd, &client);
    FillRect(hdc, &client, g_app.brushBg);

    auto S = [&](int dp) { return Scale(hwnd, dp); };
    auto Y = [&](int dp) { return S(dp) - g_app.scrollY; };
    PanelLayout layout;
    const int saved = SaveDC(hdc);
    IntersectClipRect(hdc, 0, S(kHeaderHeight), client.right, client.bottom);

    // A continuous white surface, with reference-style inset hairlines.
    HPEN divider = CreatePen(PS_SOLID, 1, kDivider);
    auto oldPen = SelectObject(hdc, divider);
    auto separate = [&](int y, int left = kContentInset) {
        MoveToEx(hdc, S(left), Y(y), nullptr);
        LineTo(hdc, S(kPanelWidth - kContentInset), Y(y));
    };
    for (int y : {layout.stats, layout.pricing, layout.apps, layout.prefs}) separate(y);
    if (g_app.state.updateAvailable) separate(116);
    separate(layout.apps + 96, 32);
    // Keep numeric columns readable without surrounding them with another box.
    for (int x : {110, 188}) {
        MoveToEx(hdc, S(x), Y(layout.stats + 117), nullptr);
        LineTo(hdc, S(x), Y(layout.stats + 147));
    }
    if (g_app.preferencesOpen) {
        separate(layout.prefs + 102);
        separate(layout.prefs + 190);
    }
    SelectObject(hdc, oldPen);
    DeleteObject(divider);

    const COLORREF statusColor = g_app.state.serviceRunning ? kGreen : kTertiary;
    FillRoundedRect(hdc, {S(11), Y(57), S(17), Y(63)}, S(6), statusColor, statusColor);
    for (int row : {49, 111}) {
        DrawLineIcon(hdc, {S(10), Y(layout.apps + row), S(24), Y(layout.apps + row + 14)},
                     row == 49 ? ID_BTN_BROWSE_AG : ID_BTN_DETECT_ENV, kSecondary);
    }
    RestoreDC(hdc, saved);

    RECT header{0, 0, client.right, S(kHeaderHeight)};
    FillRect(hdc, &header, g_app.brushBg);
    // The brand keeps its colors; the tray icon continues to reflect runtime state.
    if (g_app.brandBitmap) {
        Gdiplus::Graphics graphics(hdc);
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeHighQuality);
        graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
        graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
        graphics.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
        Gdiplus::ImageAttributes attrs;
        attrs.SetWrapMode(Gdiplus::WrapModeTileFlipXY);
        // Crop excess outer transparent padding (shield spans ~38..218 in 256x256)
        // so the shield fills the compact brand slot cleanly while staying centered.
        const Gdiplus::RectF dest(static_cast<Gdiplus::REAL>(S(10)), static_cast<Gdiplus::REAL>(S(11)),
                                  static_cast<Gdiplus::REAL>(S(14)), static_cast<Gdiplus::REAL>(S(14)));
        graphics.DrawImage(g_app.brandBitmap.get(), dest, 34.0f, 34.0f, 188.0f, 188.0f,
                           Gdiplus::UnitPixel, &attrs);
    }
}

void PositionUpdatePopup() {
    if (!g_app.updatePopup) return;
    RECT owner{};
    GetWindowRect(g_app.hwnd, &owner);
    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromWindow(g_app.hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    const int width = Scale(g_app.hwnd, 316);
    const int height = Scale(g_app.hwnd, 264);
    const LONG x = std::clamp((owner.left + owner.right - width) / 2, monitor.rcWork.left,
                              std::max(monitor.rcWork.left, monitor.rcWork.right - width));
    const LONG y = std::clamp((owner.top + owner.bottom - height) / 2, monitor.rcWork.top,
                              std::max(monitor.rcWork.top, monitor.rcWork.bottom - height));
    SetWindowPos(g_app.updatePopup, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}

void SyncUpdatePopup() {
    if (!g_app.updatePopup) return;
    const auto notice = GetUpdateNotice();
    auto place = [&](HWND control, HFONT font, int x, int y, int w, int h, bool visible = true) {
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
        SetWindowPos(control, nullptr, Scale(g_app.updatePopup, x), Scale(g_app.updatePopup, y),
                     Scale(g_app.updatePopup, w), Scale(g_app.updatePopup, h),
                     SWP_NOZORDER | SWP_NOACTIVATE | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    };
    SetWindowTextW(g_app.updatePopup, notice.title.c_str());
    SetWindowTextW(g_app.lblUpdatePopupTitle, notice.title.c_str());
    SetWindowTextW(g_app.lblUpdatePopupBody, notice.body.c_str());
    SetWindowTextW(g_app.lblUpdatePopupDetail, notice.detail.c_str());
    SetWindowTextW(g_app.lblUpdatePopupCurrent, notice.currentVersion.c_str());
    SetWindowTextW(g_app.lblUpdatePopupLatest, notice.latestVersion.c_str());
    SetWindowTextW(g_app.btnUpdatePopupPrimary, notice.primaryLabel.c_str());
    SetWindowTextW(g_app.btnUpdatePopupSecondary, g_app.updatePhase == UpdatePhase::Available ||
        g_app.updatePhase == UpdatePhase::Ready ? L"稍后" : L"关闭");
    EnableWindow(g_app.btnUpdatePopupPrimary, !notice.busy);
    place(g_app.btnUpdatePopupClose, g_app.fontRegular, 276, 12, 26, 26);
    place(g_app.lblUpdatePopupTitle, g_app.fontDialogTitle, 68, 20, 200, 22);
    place(g_app.lblUpdatePopupBody, g_app.fontRegular, 20, 72, 276, 38);
    place(g_app.lblUpdatePopupDetail, g_app.fontSmall, 20, 114, 276, 16, !notice.detail.empty());
    place(g_app.lblUpdatePopupCurrent, g_app.fontSmallLatin, 130, 146, 154, 16);
    place(g_app.lblUpdatePopupLatest, g_app.fontSmallLatin, 130, 174, 154, 16);
    place(g_app.btnUpdatePopupSecondary, g_app.fontSmall, 20, 218, 86, 28, notice.showSecondary);
    place(g_app.btnUpdatePopupPrimary, g_app.fontBold, notice.showSecondary ? 114 : 20, 218,
          notice.showSecondary ? 182 : 276, 28);
    TOOLINFOW tool{sizeof(tool)};
    tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    tool.hwnd = g_app.updatePopup;
    tool.uId = reinterpret_cast<UINT_PTR>(g_app.lblUpdatePopupDetail);
    tool.lpszText = const_cast<wchar_t*>(notice.detail.c_str());
    SendMessageW(g_app.updatePopupTooltip, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool));
    InvalidateRect(g_app.updatePopup, nullptr, TRUE);
}

void PaintUpdatePopup(HWND hwnd, HDC hdc) {
    RECT client{};
    GetClientRect(hwnd, &client);
    FillRect(hdc, &client, g_app.brushCard);
    auto S = [&](int dip) { return Scale(hwnd, dip); };
    const auto notice = GetUpdateNotice();
    FillRoundedRect(hdc, client, S(22), RGB(255, 255, 255), kBorder);
    const COLORREF badge = notice.accent == kRed ? RGB(254, 242, 242) :
        notice.accent == kGreen ? RGB(235, 249, 242) : RGB(238, 245, 255);
    FillRoundedRect(hdc, {S(20), S(20), S(58), S(58)}, S(20), badge, badge);
    DrawLineIcon(hdc, {S(30), S(30), S(48), S(48)}, notice.icon, notice.accent);
    HPEN rowSep = CreatePen(PS_SOLID, 1, kDivider);
    auto oldPen = SelectObject(hdc, rowSep);
    MoveToEx(hdc, S(20), S(134), nullptr);
    LineTo(hdc, S(296), S(134));
    MoveToEx(hdc, S(32), S(168), nullptr);
    LineTo(hdc, S(284), S(168));
    SelectObject(hdc, oldPen);
    DeleteObject(rowSep);
    auto oldFont = SelectObject(hdc, g_app.fontSmallLatin);
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, kTertiary);
    RECT brand{S(68), S(43), S(268), S(58)};
    DrawTextW(hdc, L"Gravity Guardian", -1, &brand, DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(hdc, g_app.fontSmall);
    SetTextColor(hdc, kSecondary);
    RECT current{S(32), S(146), S(124), S(162)};
    RECT latest{S(32), S(174), S(124), S(190)};
    DrawTextW(hdc, L"当前版本", -1, &current, DT_SINGLELINE | DT_NOPREFIX);
    DrawTextW(hdc, L"最新版本", -1, &latest, DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(hdc, oldFont);
}

LRESULT CALLBACK UpdatePopupProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        g_app.updatePopup = hwnd;
        ConfigureFramelessWindow(hwnd);
        auto label = [&](DWORD style = SS_LEFT) {
            return CreateWindowExW(0, L"STATIC", L"", WS_CHILD | SS_NOPREFIX | SS_NOTIFY | style,
                0, 0, 0, 0, hwnd, nullptr, g_app.hInst, nullptr);
        };
        auto button = [&](const wchar_t* text, int id) {
            HWND control = CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_TABSTOP | BS_OWNERDRAW,
                0, 0, 0, 0, hwnd, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g_app.hInst, nullptr);
            SetWindowSubclass(control, ControlSubclass, 1, 0);
            return control;
        };
        g_app.lblUpdatePopupTitle = label();
        g_app.lblUpdatePopupBody = label();
        g_app.lblUpdatePopupDetail = label(SS_ENDELLIPSIS);
        g_app.lblUpdatePopupCurrent = label(SS_RIGHT);
        g_app.lblUpdatePopupLatest = label(SS_RIGHT);
        g_app.btnUpdatePopupPrimary = button(L"", ID_UPDATE_PRIMARY);
        g_app.btnUpdatePopupSecondary = button(L"关闭", ID_UPDATE_SECONDARY);
        g_app.btnUpdatePopupClose = button(L"关闭更新提示", ID_UPDATE_CLOSE);
        g_app.updatePopupTooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr,
            WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, 0, 0, 0, 0, hwnd, nullptr, g_app.hInst, nullptr);
        SendMessageW(g_app.updatePopupTooltip, TTM_SETMAXTIPWIDTH, 0, Scale(hwnd, 320));
        for (HWND control : {g_app.lblUpdatePopupDetail, g_app.btnUpdatePopupClose}) {
            TOOLINFOW tool{sizeof(tool)};
            tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
            tool.hwnd = hwnd;
            tool.uId = reinterpret_cast<UINT_PTR>(control);
            tool.lpszText = const_cast<wchar_t*>(L"关闭更新提示");
            SendMessageW(g_app.updatePopupTooltip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
        }
        SyncUpdatePopup();
        return 0;
    }
    case WM_NCCALCSIZE:
    case WM_NCPAINT:
        return 0;
    case WM_NCACTIVATE:
        return TRUE;
    case WM_NCHITTEST:
        return HTCLIENT;
    case WM_ERASEBKGND:
        return 1;
    case WM_DPICHANGED: {
        const auto* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        SyncUpdatePopup();
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC hdc = BeginPaint(hwnd, &paint);
        PaintUpdatePopup(hwnd, hdc);
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_PRINTCLIENT:
        PaintUpdatePopup(hwnd, reinterpret_cast<HDC>(wParam));
        return 0;
    case WM_DRAWITEM:
        DrawOwnerButton(*reinterpret_cast<const DRAWITEMSTRUCT*>(lParam));
        return TRUE;
    case WM_CTLCOLORSTATIC: {
        HDC hdc = reinterpret_cast<HDC>(wParam);
        HWND control = reinterpret_cast<HWND>(lParam);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, control == g_app.lblUpdatePopupBody ? kSecondary : control == g_app.lblUpdatePopupDetail ? kTertiary : kText);
        return reinterpret_cast<LRESULT>(g_app.brushCard);
    }
    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case ID_UPDATE_CLOSE:
        case ID_UPDATE_SECONDARY:
        case IDCANCEL:
            SendMessageW(hwnd, WM_CLOSE, 0, 0);
            return 0;
        case IDOK:
        case ID_UPDATE_PRIMARY: {
            const auto notice = GetUpdateNotice();
            if (notice.busy) return 0;
            switch (notice.action) {
            case UpdateAction::Check: StartCheckUpdateWorker(false); break;
            case UpdateAction::Download: StartDownloadAndApplyWorker(); break;
            case UpdateAction::OpenDownloads:
                OpenPathWithShell(L"https://github.com/CarlosZ16420/gravity-guardian/releases/latest");
                break;
            case UpdateAction::Close: SendMessageW(hwnd, WM_CLOSE, 0, 0); break;
            }
            return 0;
        }
        }
        break;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_SYSKEYDOWN:
        if (wParam == VK_F4) { SendMessageW(hwnd, WM_CLOSE, 0, 0); return 0; }
        break;
    case WM_DESTROY:
        g_app.updatePopup = nullptr;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void ShowUpdatePopup(bool show) {
    if (!g_app.updatePopup) {
        static bool registered = false;
        constexpr wchar_t popupClass[] = L"GravityGuardianUpdatePopup";
        if (!registered) {
            WNDCLASSEXW windowClass{sizeof(windowClass)};
            windowClass.lpfnWndProc = UpdatePopupProc;
            windowClass.hInstance = g_app.hInst;
            windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
            windowClass.lpszClassName = popupClass;
            registered = RegisterClassExW(&windowClass) != 0;
        }
        if (!registered) return;
        CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT, popupClass, L"应用更新",
            kPanelStyle, 0, 0, Scale(g_app.hwnd, 316), Scale(g_app.hwnd, 264),
            g_app.hwnd, nullptr, g_app.hInst, nullptr);
    }
    if (!g_app.updatePopup) return;
    PositionUpdatePopup();
    SyncUpdatePopup();
    if (show) {
        ShowWindow(g_app.updatePopup, SW_SHOWNORMAL);
        SetForegroundWindow(g_app.updatePopup);
        SetFocus(GetUpdateNotice().busy ? g_app.btnUpdatePopupSecondary : g_app.btnUpdatePopupPrimary);
    }
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

UINT TaskbarCreatedMessage() {
    static const UINT message = RegisterWindowMessageW(L"TaskbarCreated");
    return message;
}

void AddTrayIcon(HWND hwnd) {
    g_app.nid.cbSize = sizeof(g_app.nid);
    g_app.nid.hWnd = hwnd;
    g_app.nid.uID = IDI_APP_ICON;
    g_app.nid.uCallbackMessage = WM_APP_TRAY;
    g_app.nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_app.trayAdded = Shell_NotifyIconW(NIM_ADD, &g_app.nid) == TRUE;
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (TaskbarCreatedMessage() != 0 && msg == TaskbarCreatedMessage()) {
        g_app.trayAdded = false;
        UpdateTrayAppearance();
        AddTrayIcon(hwnd);
        return 0;
    }
    switch (msg) {
    case WM_CREATE: {
        g_app.hwnd = hwnd;
        ConfigureFramelessWindow(hwnd);
        g_app.brushBg = CreateSolidBrush(kBackground);
        g_app.brushCard = CreateSolidBrush(RGB(255, 255, 255));
        if (!LoadPanelIcons(hwnd)) return -1;

        CreateChildControls(hwnd);

        g_app.nid.hIcon = g_app.iconGray;
        wcsncpy_s(g_app.nid.szTip, L"Gravity Guardian", _TRUNCATE);
        AddTrayIcon(hwnd);

        SyncControlsToUi();
        SetTimer(hwnd, ID_TIMER_REFRESH, 30000, nullptr);
        StartRefreshWorker(true, true, false);
        return 0;
    }
    case WM_NCCALCSIZE:
        return 0;
    case WM_NCPAINT:
        return 0;
    case WM_NCACTIVATE:
        return TRUE;
    case WM_MOVE:
        PositionUpdatePopup();
        return 0;
    case WM_SYSKEYDOWN:
        if (wParam == VK_F4) { SendMessageW(hwnd, WM_CLOSE, 0, 0); return 0; }
        break;
    case WM_NCHITTEST: {
        POINT point{static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))};
        ScreenToClient(hwnd, &point);
        if (point.y >= 0 && point.y < Scale(hwnd, kHeaderHeight) &&
            ChildWindowFromPointEx(hwnd, point, CWP_SKIPINVISIBLE | CWP_SKIPDISABLED) == hwnd) return HTCAPTION;
        if (point.y >= 0 && point.y < Scale(hwnd, kHeaderHeight)) {
            RECT title{};
            GetWindowRect(g_app.lblTitle, &title);
            MapWindowPoints(HWND_DESKTOP, hwnd, reinterpret_cast<POINT*>(&title), 2);
            if (PtInRect(&title, point)) return HTCAPTION;
        }
        return HTCLIENT;
    }
    case WM_NCLBUTTONDBLCLK:
        if (wParam == HTCAPTION) return 0;
        break;
    case WM_SYSCOMMAND:
        if ((wParam & 0xfff0) == SC_MAXIMIZE || (wParam & 0xfff0) == SC_SIZE) return 0;
        if ((wParam & 0xfff0) == SC_MINIMIZE) { ShowWindow(hwnd, SW_HIDE); return 0; }
        break;
    case WM_ERASEBKGND:
        return 1;
    case WM_DPICHANGED: {
        const HFONT oldFonts[] = {g_app.fontTitle, g_app.fontHeading, g_app.fontBold,
                                  g_app.fontRegular, g_app.fontSmall, g_app.fontSmallLatin,
                                  g_app.fontMetric, g_app.fontSubMetric, g_app.fontDialogTitle};
        auto suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER);
        CreateFonts(hwnd);
        ResizePanelToContent();
        LoadPanelIcons(hwnd);
        PositionUpdatePopup();
        SyncUpdatePopup();
        SendMessageW(g_app.tooltip, TTM_SETMAXTIPWIDTH, 0, Scale(hwnd, 360));
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
            GetScrollInfo(g_app.scrollbar, SB_CTL, &info);
            y = info.nTrackPos;
            break;
        }
        default: return 0;
        }
        SetPanelScroll(y);
        return 0;
    }
    case WM_MOUSEWHEEL:
        if (g_app.needsScroll) {
            SetPanelScroll(g_app.scrollY - MulDiv(GET_WHEEL_DELTA_WPARAM(wParam), Scale(hwnd, 60), WHEEL_DELTA));
        }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC hdc = BeginPaint(hwnd, &ps);
        PaintPanelSurface(hwnd, hdc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_PRINTCLIENT:
        PaintPanelSurface(hwnd, reinterpret_cast<HDC>(wParam));
        return 0;
    case WM_DRAWITEM:
        DrawOwnerButton(*reinterpret_cast<const DRAWITEMSTRUCT*>(lParam));
        return TRUE;
    case WM_CTLCOLORSTATIC: {
        HDC hdc = reinterpret_cast<HDC>(wParam);
        HWND ctrl = reinterpret_cast<HWND>(lParam);
        SetBkMode(hdc, TRANSPARENT);
        if (ctrl == g_app.lblUpdateBanner) {
            SetTextColor(hdc, kBlue);
            return reinterpret_cast<LRESULT>(g_app.brushCard);
        }
        if (ctrl == g_app.lblLogBadge) {
            SetTextColor(hdc, g_app.state.detailedLogs ? RGB(180, 83, 9) : kTertiary);
        } else if (ctrl == g_app.lblStatus) {
            SetTextColor(hdc, g_app.state.serviceRunning ? kGreen : kSecondary);
        } else if (ctrl == g_app.lblStatsInputTitle || ctrl == g_app.lblStatsOutputTitle ||
                   ctrl == g_app.lblStatsCacheTitle || ctrl == g_app.lblStatsTokenDetail ||
                   ctrl == g_app.lblVersionInfo) {
            SetTextColor(hdc, kTertiary);
        } else if (ctrl == g_app.lblStatsCost || ctrl == g_app.lblStatsSub || ctrl == g_app.lblPricingNote ||
                   ctrl == g_app.lblAgPath || ctrl == g_app.lblGuardianAuth) {
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
            if (IsWindowVisible(hwnd)) SendMessageW(hwnd, WM_CLOSE, 0, 0);
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
    case WM_APP_UPDATE_PROGRESS:
        if (g_app.busyUpdate) {
            g_app.updatePhase = UpdatePhase::Downloading;
            SyncUpdatePopup();
        }
        return 0;
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
        } else if (res->kind == WorkKind::ToggleProtectedDelegation) {
            if (res->ok) {
                g_app.state.delegateProtectedPaths = res->targetProtectedDelegation;
                SyncControlsToUi();
            } else {
                SyncControlsToUi();
                MessageBoxW(hwnd, res->message.c_str(), L"受保护目录设置失败", MB_OK | MB_ICONERROR);
            }
        } else if (res->kind == WorkKind::LaunchAntigravity) {
            if (res->ok) StartRefreshWorker(false, false, true);
            else MessageBoxW(hwnd, L"无法启动 Antigravity.exe，请检查文件路径和权限。", L"启动失败", MB_OK | MB_ICONERROR);
        } else if (res->kind == WorkKind::CheckAndMaybeUpdate || res->kind == WorkKind::DownloadUpdate) {
            const bool downloading = g_app.updatePhase == UpdatePhase::Downloading;
            g_app.busyUpdate = false;
            g_app.state.updateChecked = res->snapshot.updateChecked;
            g_app.state.updateAvailable = res->snapshot.updateAvailable;
            g_app.state.updateDownloaded = res->snapshot.updateDownloaded;
            g_app.state.waitingAntigravityExit = res->snapshot.waitingAntigravityExit;
            g_app.state.availableUpdate = res->snapshot.availableUpdate;
            g_app.state.downloadedZipPath = res->snapshot.downloadedZipPath;
            g_app.updateError = res->ok ? L"" : res->message;
            if (!res->ok) {
                g_app.updatePhase = res->kind == WorkKind::DownloadUpdate || downloading ?
                    UpdatePhase::DownloadFailed : UpdatePhase::CheckFailed;
            } else if (g_app.state.waitingAntigravityExit) {
                g_app.updatePhase = UpdatePhase::Waiting;
            } else if (g_app.state.updateDownloaded) {
                g_app.updatePhase = UpdatePhase::Ready;
            } else {
                g_app.updatePhase = g_app.state.updateAvailable ? UpdatePhase::Available : UpdatePhase::Current;
            }
            SyncControlsToUi();
            if (res->triggerImmediateApply) {
                if (g_app.uninstallPromptOpen) {
                    g_app.state.waitingAntigravityExit = true;
                    g_app.updatePhase = UpdatePhase::Waiting;
                    SyncUpdatePopup();
                    SetTimer(hwnd, ID_TIMER_DEFERRED_UPDATE, 5000, nullptr);
                    return 0;
                }
                ExecutePendingUpdateAndExit();
                return 0;
            }
            if (g_app.state.waitingAntigravityExit) {
                SetTimer(hwnd, ID_TIMER_DEFERRED_UPDATE, 5000, nullptr);
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
            if (TakeStartupUpdateCheck(res->kind)) StartCheckUpdateWorker(true);
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
        case ID_BTN_GITHUB:
            OpenPathWithShell(L"https://github.com/CarlosZ16420/gravity-guardian");
            break;
        case ID_BTN_HIDE:
        case IDCANCEL:
            SendMessageW(hwnd, WM_CLOSE, 0, 0);
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
                    InvalidateRect(g_app.chkDetailedLogs, nullptr, FALSE);
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
        case ID_CHK_PROTECTED_DELEGATION: {
            bool wantEnable = !g_app.state.delegateProtectedPaths;
            StartProtectedDelegationWorker(wantEnable);
            break;
        }
        case ID_CHK_AUTOSTART: {
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            bool next = !g_app.cfg.autostart;
            if (SetAutostart(next, GetExecutablePath())) {
                g_app.cfg.autostart = next;
                SavePanelConfig(g_app.cfg);
            } else {
                MessageBoxW(hwnd, L"写入开机自启动注册表项失败。", L"开机自启动", MB_OK | MB_ICONERROR);
            }
            InvalidateRect(g_app.chkAutostart, nullptr, FALSE);
            break;
        }
        case ID_CHK_AUTO_UPDATE: {
            std::lock_guard<std::mutex> lk(g_app.cfgMutex);
            g_app.cfg.autoUpdate = !g_app.cfg.autoUpdate;
            SavePanelConfig(g_app.cfg);
            InvalidateRect(g_app.chkAutoUpdate, nullptr, FALSE);
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
            if (!g_app.cfg.portableRoot.empty()) {
                const auto target = JoinPath(g_app.cfg.portableRoot, L"config\\pricing.json");
                EnsureDirectoryTree(GetDirectoryName(target));
                if (!FileExists(target)) CopyFileW(pricing.c_str(), target.c_str(), TRUE);
                pricing = target;
            }
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
        if (g_app.updatePopup) DestroyWindow(g_app.updatePopup);
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    case WM_DESTROY:
        if (g_app.updatePopup) DestroyWindow(g_app.updatePopup);
        if (g_app.trayAdded) {
            Shell_NotifyIconW(NIM_DELETE, &g_app.nid);
            g_app.trayAdded = false;
        }
        for (HFONT f : {g_app.fontTitle, g_app.fontHeading, g_app.fontBold, g_app.fontRegular, g_app.fontSmall, g_app.fontSmallLatin, g_app.fontMetric, g_app.fontSubMetric, g_app.fontDialogTitle}) {
            if (f) DeleteObject(f);
        }
        for (HBRUSH b : {g_app.brushBg, g_app.brushCard}) {
            if (b) DeleteObject(b);
        }
        for (HICON ic : {g_app.iconAppSmall, g_app.iconAppLarge, g_app.iconNormal, g_app.iconGray}) {
            if (ic) DestroyIcon(ic);
        }
        g_app.brandBitmap.reset();
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

        std::string manifestRaw;
        JsonValue manifestDoc;
        if (ReadFileUtf8(JoinPath(localFeedDir, L"release-manifest.json"), manifestRaw) &&
            JsonValue::Parse(manifestRaw, manifestDoc) && manifestDoc.Get("distributions")) {
            const auto lite = CheckForUpdate(ucfg, PANEL_VERSION_WIDE, L"lite");
            if (!check(lite.ok && lite.hasUpdate && lite.manifest.assetName != chk.manifest.assetName,
                       "Local feed did not select the Lite asset")) return 1;
            dlOk = DownloadAndVerifyUpdate(ucfg, lite.manifest, stage, zipOut, dlErr);
            exists = dlOk && FileExists(zipOut);
            if (!zipOut.empty()) DeleteFileW(zipOut.c_str());
            RemoveDirectoryW(stage.c_str());
            if (!check(dlOk && exists, ("Lite download/verify failed: " + WideToUtf8(dlErr)).c_str())) return 1;
            WriteStdoutUtf8("PASS local feed selected and verified separate Lite asset\n");
        }
    }

    return 0;
}

} // namespace
} // namespace panel

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int nCmdShow) {
    using namespace panel;
    SetCurrentProcessExplicitAppUserModelID(L"GravityGuardian.Panel");

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

    std::wstring mutexName = L"Local\\GravityGuardianPanel";
    std::wstring windowClass = kWindowClass;
    if (!g_app.cfg.portableRoot.empty()) {
        std::wstring identity;
        ComputeBufferSha256Hex(g_app.cfg.portableRoot.data(), g_app.cfg.portableRoot.size() * sizeof(wchar_t), identity);
        mutexName += L"_" + identity.substr(0, 16);
        windowClass += L"_" + identity.substr(0, 16);
    }
    HANDLE hMutex = CreateMutexW(nullptr, TRUE, mutexName.c_str());
    if (hMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND existing = FindWindowW(windowClass.c_str(), nullptr);
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
    wc.hIcon = static_cast<HICON>(LoadImageW(hInst, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR | LR_SHARED));
    wc.hIconSm = static_cast<HICON>(LoadImageW(hInst, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR | LR_SHARED));
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = windowClass.c_str();
    wc.hbrBackground = nullptr;
    RegisterClassExW(&wc);

    UINT dpi = GetDpiForSystem();
    if (dpi == 0) dpi = 96;
    int winW = MulDiv(kPanelWidth, static_cast<int>(dpi), 96);
    int winH = MulDiv(kCompactHeight, static_cast<int>(dpi), 96);
    RECT adj{0, 0, winW, winH};
    int fullW = adj.right - adj.left;
    int fullH = adj.bottom - adj.top;

    RECT wa{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = wa.right - fullW - MulDiv(16, static_cast<int>(dpi), 96);
    int y = wa.bottom - fullH - MulDiv(16, static_cast<int>(dpi), 96);
    if (x < wa.left) x = wa.left + 20;
    if (y < wa.top) y = wa.top + 20;

    Gdiplus::GdiplusStartupInput graphicsInput;
    ULONG_PTR graphicsToken = 0;
    if (Gdiplus::GdiplusStartup(&graphicsToken, &graphicsInput, nullptr) != Gdiplus::Ok) {
        if (hMutex) CloseHandle(hMutex);
        return 1;
    }
    HWND hwnd = CreateWindowExW(
        kPanelExStyle, windowClass.c_str(), g_app.cfg.portableRoot.empty() ? L"Gravity Guardian" : L"Gravity Guardian 免安装版",
        kPanelStyle, x, y, fullW, fullH,
        nullptr, nullptr, hInst, nullptr);
    if (!hwnd) {
        Gdiplus::GdiplusShutdown(graphicsToken);
        if (hMutex) CloseHandle(hMutex);
        return 1;
    }

    if (!minimized) {
        ShowWindow(hwnd, nCmdShow);
        UpdateWindow(hwnd);
    }

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (g_app.updatePopup && IsDialogMessageW(g_app.updatePopup, &msg)) {
            continue;
        } else if (IsDialogMessageW(hwnd, &msg)) {
            if (msg.message == WM_KEYDOWN && msg.wParam == VK_TAB) ScrollFocusIntoView(hwnd);
        } else {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    Gdiplus::GdiplusShutdown(graphicsToken);
    if (hMutex) CloseHandle(hMutex);
    return static_cast<int>(msg.wParam);
}
