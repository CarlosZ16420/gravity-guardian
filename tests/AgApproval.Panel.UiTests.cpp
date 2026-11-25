// Exercise the real native controls and window procedure without starting services,
// checking the network, changing startup settings, or using the user's data.
#define wWinMain PanelApplicationEntry
#include "../src/AgApproval.Panel/main.cpp"
#undef wWinMain

using namespace panel;

LRESULT CALLBACK UiTestWindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_CREATE) {
        g_app.hwnd = hwnd;
        ConfigureFramelessWindow(hwnd);
        g_app.brushBg = CreateSolidBrush(kBackground);
        g_app.brushCard = CreateSolidBrush(RGB(255, 255, 255));
        g_app.brushBanner = CreateSolidBrush(RGB(239, 246, 255));
        if (!LoadPanelIcons(hwnd)) return -1;
        CreateChildControls(hwnd);
        SyncControlsToUi();
        return 0;
    }
    return WndProc(hwnd, message, wParam, lParam);
}

bool SavePopupPreview(const wchar_t* filename) {
    RECT client{};
    GetClientRect(g_app.updatePopup, &client);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = client.right;
    info.bmiHeader.biHeight = -client.bottom;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    HDC hdc = CreateCompatibleDC(nullptr);
    if (!bitmap || !hdc) return false;
    auto previous = SelectObject(hdc, bitmap);
    SendMessageW(g_app.updatePopup, WM_PRINT, reinterpret_cast<WPARAM>(hdc), PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND);
    SelectObject(hdc, previous);
    DeleteDC(hdc);
    UINT count = 0, size = 0;
    Gdiplus::GetImageEncodersSize(&count, &size);
    std::vector<BYTE> buffer(size);
    auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
    Gdiplus::GetImageEncoders(count, size, codecs);
    bool saved = false;
    {
        Gdiplus::Bitmap image(bitmap, nullptr);
        for (UINT i = 0; i < count; ++i) {
            if (std::wstring(codecs[i].MimeType) == L"image/png") {
                saved = image.Save(JoinPath(GetDirectoryName(GetExecutablePath()), filename).c_str(), &codecs[i].Clsid) == Gdiplus::Ok;
                break;
            }
        }
    }
    DeleteObject(bitmap);
    return saved;
}

int wmain(int argc, wchar_t** argv) {
    const bool interactive = argc > 1 && std::wstring(argv[1]) == L"--interactive";
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    INITCOMMONCONTROLSEX common{sizeof(common), ICC_STANDARD_CLASSES | ICC_DATE_CLASSES};
    InitCommonControlsEx(&common);
    Gdiplus::GdiplusStartupInput graphicsInput;
    ULONG_PTR graphicsToken = 0;
    if (Gdiplus::GdiplusStartup(&graphicsToken, &graphicsInput, nullptr) != Gdiplus::Ok) return 1;
    g_app.hInst = GetModuleHandleW(nullptr);
    g_app.cfg.autoCheckUpdates = false;
    g_app.cfg.dataDirectory = JoinPath(GetDirectoryName(GetExecutablePath()), L"unused-test-data");
    g_app.cfg.pluginDirectory = JoinPath(g_app.cfg.dataDirectory, L"unused-plugin");
    WNDCLASSEXW windowClass{sizeof(windowClass)};
    windowClass.lpfnWndProc = UiTestWindowProc;
    windowClass.hInstance = g_app.hInst;
    windowClass.lpszClassName = L"GravityStewardPanelUiTests";
    RegisterClassExW(&windowClass);
    HWND hwnd = CreateWindowExW(kPanelExStyle, windowClass.lpszClassName, L"Panel UI tests",
        kPanelStyle, 0, 0, 414, 714, nullptr, nullptr, g_app.hInst, nullptr);
    if (!hwnd) return 1;
    int failed = 0;
    auto check = [&](bool ok, const char* label) {
        WriteStdoutUtf8(std::string(ok ? "PASS " : "FAIL ") + label + "\n");
        if (!ok) ++failed;
    };
    auto rect = [&](HWND control) {
        RECT value{};
        GetWindowRect(control, &value);
        MapWindowPoints(HWND_DESKTOP, hwnd, reinterpret_cast<POINT*>(&value), 2);
        return value;
    };
    auto hit = [&](int x, int y) {
        POINT point{Scale(hwnd, x), Scale(hwnd, y)};
        ClientToScreen(hwnd, &point);
        return SendMessageW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(point.x, point.y));
    };
    check((GetWindowLongPtrW(hwnd, GWL_STYLE) & (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)) == 0,
          "native caption and caption buttons are absent from the actual window style");
    for (WPARAM active : {FALSE, TRUE, FALSE, TRUE}) SendMessageW(hwnd, WM_NCACTIVATE, active, 0);
    SendMessageW(hwnd, WM_ENTERSIZEMOVE, 0, 0);
    SetWindowPos(hwnd, nullptr, 10, 10, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    SendMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0);
    RECT windowBounds{}, clientBounds{};
    GetWindowRect(hwnd, &windowBounds);
    GetClientRect(hwnd, &clientBounds);
    check((GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CAPTION) == 0 &&
          windowBounds.right - windowBounds.left == clientBounds.right &&
          windowBounds.bottom - windowBounds.top == clientBounds.bottom && !IsWindowVisible(hwnd),
          "activation and move-frame changes retain a caption-free full client area without showing the window");
    check(hit(30, 30) == HTCAPTION && hit(110, 30) == HTCAPTION && hit(240, 30) == HTCAPTION,
          "brand and empty header support native window dragging");
    check(hit(277, 30) == HTCLIENT && hit(311, 30) == HTCLIENT &&
          hit(345, 30) == HTCLIENT && hit(379, 30) == HTCLIENT,
          "header actions are clickable, outside the drag region");
    wchar_t name[96]{};
    GetWindowTextW(g_app.btnHide, name, static_cast<int>(std::size(name)));
    check(std::wstring(name).find(L"托盘") != std::wstring::npos,
          "icon-only close button exposes its tray behavior to accessibility");

    for (bool banner : {false, true}) {
        for (bool preferences : {false, true}) {
            g_app.state.pluginInstalled = true;
            g_app.state.serviceRunning = true;
            g_app.state.takeoverEnabled = true;
            g_app.state.updateAvailable = banner;
            g_app.preferencesOpen = preferences;
            SyncControlsToUi();
            const auto status = rect(g_app.lblStatus);
            const auto toggle = rect(g_app.btnApprovalTakeover);
            const auto title = rect(g_app.lblStatsTitle);
            const auto date = rect(g_app.btnStatsDate);
            check(status.right <= toggle.left && toggle.right == Scale(hwnd, 378) && title.right < date.left,
                  "status switch stays right aligned and date action stays clear of its title");
        }
    }

    ApprovalStats usage;
    usage.inputTokens = 46557750;
    usage.cachedTokens = 4215168;
    usage.outputTokens = 39226;
    g_app.stats.today = usage;
    g_app.statsLoaded = true;
    SyncStatsToUi();
    GetWindowTextW(g_app.lblStatsCacheRate, name, static_cast<int>(std::size(name)));
    check(std::wstring(name) == L"9.1%" && FormatCacheHitRate(ApprovalStats{}) == L"—",
          "cache hit rate uses cached input divided by total input and handles missing input");
    const auto inputColumn = rect(g_app.lblStatsTokens);
    const auto outputColumn = rect(g_app.lblStatsOutput);
    const auto cacheColumn = rect(g_app.lblStatsCacheRate);
    check(inputColumn.right < outputColumn.left && outputColumn.right < cacheColumn.left &&
          inputColumn.top == outputColumn.top && outputColumn.top == cacheColumn.top,
          "input, output and cache hit rate occupy separate aligned columns");
    GetWindowTextW(g_app.lblLogBadge, name, static_cast<int>(std::size(name)));
    check(std::wstring(name).empty(), "logging disabled has no compact-mode badge");
    GetWindowTextW(g_app.lblVersionInfo, name, static_cast<int>(std::size(name)));
    check(std::wstring(name) == L"v" PANEL_VERSION_WIDE, "settings footer contains only the version number");

    g_app.state.updateAvailable = false;
    g_app.state.availableUpdate = {};
    g_app.updatePhase = UpdatePhase::Checking;
    g_app.busyUpdate = true;
    ShowUpdatePopup(false);
    check(g_app.updatePopup && !IsWindowVisible(g_app.updatePopup) && !IsWindowEnabled(g_app.btnUpdatePopupPrimary) &&
          GetUpdateNotice().title == L"正在检查更新", "checking popup is headless and prevents duplicate actions");
    check((GetWindowLongPtrW(g_app.updatePopup, GWL_STYLE) & WS_CAPTION) == 0 &&
          SavePopupPreview(L"update-checking.png"), "update popup has no system caption and renders offscreen");
    auto finishUpdate = [&](bool ok, bool available, WorkKind kind = WorkKind::CheckAndMaybeUpdate) {
        auto result = std::make_unique<WorkResult>();
        result->kind = kind;
        result->ok = ok;
        result->message = ok ? L"" : L"测试错误：更新服务暂时不可用（HTTP 503）";
        result->snapshot = g_app.state;
        result->snapshot.updateAvailable = available;
        result->snapshot.updateDownloaded = false;
        result->snapshot.waitingAntigravityExit = false;
        result->snapshot.availableUpdate.version = available ? L"999.0.0" : PANEL_VERSION_WIDE;
        g_app.busyUpdate = true;
        SendMessageW(hwnd, WM_APP_WORK_DONE, 0, reinterpret_cast<LPARAM>(result.release()));
    };
    finishUpdate(true, false);
    check(!g_app.busyUpdate && g_app.updatePhase == UpdatePhase::Current && IsWindowEnabled(g_app.btnUpdatePopupPrimary) &&
          GetUpdateNotice().action == UpdateAction::Close && SavePopupPreview(L"update-current.png"),
          "successful current-version result clearly states no update is required");
    finishUpdate(false, false);
    check(g_app.updatePhase == UpdatePhase::CheckFailed && GetUpdateNotice().action == UpdateAction::Check &&
          !GetUpdateNotice().detail.empty() && SavePopupPreview(L"update-error.png"),
          "failed check offers retry and retains diagnostic detail without a native message box");
    g_app.state.pluginInstalled = true;
    finishUpdate(true, true);
    check(g_app.updatePhase == UpdatePhase::Available && GetUpdateNotice().action == UpdateAction::Download &&
          GetUpdateNotice().latestVersion == L"v999.0.0" && SavePopupPreview(L"update-available.png"),
          "new-version result displays both versions and offers download and update");
    g_app.state.pluginInstalled = false;
    SyncUpdatePopup();
    check(GetUpdateNotice().action == UpdateAction::OpenDownloads,
          "portable panel directs users to downloads instead of an unavailable in-place update");
    g_app.busyUpdate = true;
    SendMessageW(hwnd, WM_APP_UPDATE_PROGRESS, 0, 0);
    check(g_app.updatePhase == UpdatePhase::Downloading && !IsWindowEnabled(g_app.btnUpdatePopupPrimary),
          "download progress disables duplicate update requests");
    finishUpdate(false, true, WorkKind::DownloadUpdate);
    check(g_app.updatePhase == UpdatePhase::DownloadFailed && GetUpdateNotice().action == UpdateAction::Download,
          "download failure offers the correct update retry");
    SendMessageW(g_app.updatePopup, WM_COMMAND, IDCANCEL, 0);
    check(!g_app.updatePopup, "Escape dismisses the update popup independently");
    finishUpdate(true, false);
    check(!g_app.updatePopup && !IsWindowVisible(hwnd), "background completion never opens or activates a desktop window");

    // Drive the actual asynchronous checker with an isolated local feed. No
    // Internet, executable launch, installation or user configuration is involved.
    const auto feed = JoinPath(GetDirectoryName(GetExecutablePath()), L"update-feed-fixture");
    EnsureDirectoryTree(feed);
    const std::string payload = "panel-update-test-fixture";
    std::wstring payloadHash;
    ComputeBufferSha256Hex(payload.data(), payload.size(), payloadHash);
    WriteFileUtf8Atomic(JoinPath(feed, L"ui-test.zip"), payload);
    auto writeManifest = [&](const std::wstring& version) {
        return WriteFileUtf8Atomic(JoinPath(feed, L"release-manifest.json"),
            "{\"version\":\"" + WideToUtf8(version) + "\",\"assetName\":\"ui-test.zip\",\"sha256\":\"" +
            WideToUtf8(payloadHash) + "\",\"sizeBytes\":" + std::to_string(payload.size()) + "}");
    };
    auto waitForCheck = [&]() {
        const auto deadline = GetTickCount64() + 10000;
        while (g_app.busyUpdate && GetTickCount64() < deadline) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
            Sleep(5);
        }
        return !g_app.busyUpdate;
    };
    g_app.updateCfg.localFeedDirectory = feed;
    g_app.cfg.autoUpdate = false;
    ShowUpdatePopup(false);
    writeManifest(PANEL_VERSION_WIDE);
    StartCheckUpdateWorker(true);
    check(waitForCheck() && g_app.updatePhase == UpdatePhase::Current && !IsWindowVisible(g_app.updatePopup),
          "real async checker reports current version from the local feed without opening a window");
    writeManifest(L"999.0.0");
    StartCheckUpdateWorker(true);
    check(waitForCheck() && g_app.updatePhase == UpdatePhase::Available && g_app.state.updateAvailable,
          "real async checker propagates an available version to the popup");
    const auto available = CheckForUpdate(g_app.updateCfg, PANEL_VERSION_WIDE);
    std::wstring downloaded, downloadError;
    check(available.ok && DownloadAndVerifyUpdate(g_app.updateCfg, available.manifest, JoinPath(feed, L"staging"), downloaded, downloadError) &&
          FileExists(downloaded), "update package is copied and verified by the actual SHA-256 download path");
    auto corrupt = available.manifest;
    corrupt.sha256 = std::wstring(64, L'0');
    check(!DownloadAndVerifyUpdate(g_app.updateCfg, corrupt, JoinPath(feed, L"corrupt"), downloaded, downloadError),
          "update verifier rejects a package with an incorrect SHA-256");
    WriteFileUtf8Atomic(JoinPath(feed, L"release-manifest.json"), "{");
    StartCheckUpdateWorker(true);
    check(waitForCheck() && g_app.updatePhase == UpdatePhase::CheckFailed && !g_app.updateError.empty() &&
          !IsWindowVisible(g_app.updatePopup), "invalid update feed produces a retryable error with no desktop interruption");
    DestroyWindow(g_app.updatePopup);

    // A short viewport should scroll content while keeping all title bar actions fixed.
    g_app.needsScroll = true;
    SetWindowPos(hwnd, nullptr, 0, 0, Scale(hwnd, 414) + GetSystemMetricsForDpi(SM_CXVSCROLL, GetDpiForWindow(hwnd)),
                 Scale(hwnd, 380), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    SetPanelScroll(Scale(hwnd, PanelLayout{}.height));
    const auto header = rect(g_app.btnHide);
    const auto last = rect(g_app.btnCheckUpdate);
    RECT client{};
    GetClientRect(hwnd, &client);
    check(g_app.scrollY > 0 && header.top == Scale(hwnd, 16) &&
          last.top >= Scale(hwnd, kHeaderHeight) && last.bottom <= client.bottom,
          "short viewport reaches the final setting and keeps the title bar fixed");
    SetPanelScroll(0);
    HRGN clip = CreateRectRgn(0, 0, 0, 0);
    check(GetWindowRgn(g_app.lblStatus, clip) == ERROR,
          "scrolling back restores unclipped service controls");
    DeleteObject(clip);

    if (interactive) {
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        SendMessageW(hwnd, WM_COMMAND, ID_BTN_HIDE, 0);
        check(IsWindow(hwnd) && !IsWindowVisible(hwnd) && g_app.preferencesOpen,
              "close hides the window and retains panel state");
        SendMessageW(hwnd, WM_APP_SHOW_EXISTING, 0, 0);
        check(IsWindowVisible(hwnd), "existing-instance open restores the hidden panel");
        SendMessageW(hwnd, WM_COMMAND, IDCANCEL, 0);
        check(!IsWindowVisible(hwnd), "Escape also returns the panel to the tray");

        // Finish the read-only refresh started by the restore path before releasing controls.
        const auto deadline = GetTickCount64() + 10000;
        while ((g_app.busyRefresh || g_app.statsRunning) && GetTickCount64() < deadline) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
            Sleep(10);
        }
        check(!g_app.busyRefresh && !g_app.statsRunning, "restored panel completes its read-only refresh");
    } else {
        SendMessageW(hwnd, WM_COMMAND, ID_BTN_HIDE, 0);
        check(IsWindow(hwnd) && !IsWindowVisible(hwnd) && g_app.preferencesOpen,
              "close keeps the hidden panel alive and retains its state");
        WriteStdoutUtf8("SKIP visible restore and Escape checks; use manual testing or --interactive\n");
    }
    DestroyWindow(hwnd);
    Gdiplus::GdiplusShutdown(graphicsToken);
    return failed ? 1 : 0;
}
