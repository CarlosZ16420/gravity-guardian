#include "updater.h"
#include "util.h"
#include "version.h"
#include <bcrypt.h>
#include <winhttp.h>
#include <algorithm>
#include <cwctype>
#include <vector>

namespace panel {

namespace {

struct SemVerParts {
    int major = 0;
    int minor = 0;
    int patch = 0;
    std::wstring prerelease;
    bool valid = false;
};

SemVerParts ParseSemVer(std::wstring text) {
    text = TrimWide(text);
    if (!text.empty() && (text[0] == L'v' || text[0] == L'V')) text.erase(0, 1);
    auto plus = text.find(L'+');
    if (plus != std::wstring::npos) text.resize(plus);
    auto dash = text.find(L'-');
    SemVerParts parts{};
    if (dash != std::wstring::npos) {
        parts.prerelease = text.substr(dash + 1);
        text.resize(dash);
    }
    int nums[3] = {0, 0, 0};
    int idx = 0;
    size_t pos = 0;
    while (pos < text.size() && idx < 3) {
        auto dot = text.find(L'.', pos);
        std::wstring seg = (dot == std::wstring::npos) ? text.substr(pos) : text.substr(pos, dot - pos);
        if (seg.empty()) return {};
        for (wchar_t c : seg) {
            if (c < L'0' || c > L'9') return {};
        }
        nums[idx++] = _wtoi(seg.c_str());
        if (dot == std::wstring::npos) break;
        pos = dot + 1;
    }
    if (idx == 0) return {};
    parts.major = nums[0];
    parts.minor = nums[1];
    parts.patch = nums[2];
    parts.valid = true;
    return parts;
}

std::wstring BytesToLowerHex(const unsigned char* bytes, size_t len) {
    static constexpr wchar_t kHex[] = L"0123456789abcdef";
    std::wstring out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; ++i) {
        out.push_back(kHex[(bytes[i] >> 4) & 0xF]);
        out.push_back(kHex[bytes[i] & 0xF]);
    }
    return out;
}

bool HttpDownloadToFileOrMemory(
    const std::wstring& url,
    std::string* outMemory,
    const std::wstring& destFile,
    uint64_t maxBytes,
    std::wstring& outError) {

    URL_COMPONENTSW uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[256]{};
    wchar_t path[2048]{};
    uc.lpszHostName = host;
    uc.dwHostNameLength = static_cast<DWORD>(std::size(host));
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = static_cast<DWORD>(std::size(path));
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &uc)) {
        outError = L"更新地址无效";
        return false;
    }
    if (uc.nScheme != INTERNET_SCHEME_HTTPS) {
        outError = L"仅支持 HTTPS 安全更新源";
        return false;
    }

    HINTERNET hSession = WinHttpOpen(
        L"GravityGuardian/" PANEL_VERSION_WIDE,
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (!hSession) {
        hSession = WinHttpOpen(
            L"GravityGuardian/" PANEL_VERSION_WIDE,
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
            WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS,
            0);
    }
    if (!hSession) {
        outError = L"无法初始化 WinHTTP 网络会话";
        return false;
    }

    WinHttpSetTimeouts(hSession, 10000, 15000, 15000, 60000);
    DWORD redirectPolicy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(hSession, WINHTTP_OPTION_REDIRECT_POLICY, &redirectPolicy, sizeof(redirectPolicy));

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        outError = L"无法连接更新服务器";
        return false;
    }

    const wchar_t* acceptTypes[] = {L"*/*", nullptr};
    HINTERNET hRequest = WinHttpOpenRequest(
        hConnect,
        L"GET",
        path[0] ? path : L"/",
        nullptr,
        WINHTTP_NO_REFERER,
        acceptTypes,
        WINHTTP_FLAG_SECURE);
    if (!hRequest) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        outError = L"创建更新请求失败";
        return false;
    }

    WinHttpSetOption(hRequest, WINHTTP_OPTION_REDIRECT_POLICY, &redirectPolicy, sizeof(redirectPolicy));

    bool ok = false;
    HANDLE hFile = INVALID_HANDLE_VALUE;
    do {
        if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
            !WinHttpReceiveResponse(hRequest, nullptr)) {
            outError = L"请求更新资源失败（请检查网络连接或系统代理）";
            break;
        }

        DWORD statusCode = 0;
        DWORD statusLen = sizeof(statusCode);
        if (!WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                 WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusLen, WINHTTP_NO_HEADER_INDEX) ||
            statusCode < 200 || statusCode >= 300) {
            outError = L"更新服务器返回 HTTP 状态 " + std::to_wstring(statusCode);
            break;
        }

        if (!destFile.empty()) {
            std::wstring dir = GetDirectoryName(destFile);
            if (!dir.empty()) EnsureDirectoryTree(dir);
            hFile = CreateFileW(destFile.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (hFile == INVALID_HANDLE_VALUE) {
                outError = L"无法创建本地临时下载文件";
                break;
            }
        } else if (outMemory) {
            outMemory->clear();
        }

        uint64_t totalRead = 0;
        std::vector<char> buf(65536);
        bool streamErr = false;
        for (;;) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(hRequest, &avail)) {
                outError = L"读取更新数据失败";
                streamErr = true;
                break;
            }
            if (avail == 0) break;
            while (avail > 0) {
                DWORD toRead = static_cast<DWORD>(std::min<DWORD>(avail, static_cast<DWORD>(buf.size())));
                DWORD got = 0;
                if (!WinHttpReadData(hRequest, buf.data(), toRead, &got)) {
                    outError = L"下载更新数据中断";
                    streamErr = true;
                    break;
                }
                if (got == 0) break;
                totalRead += got;
                if (totalRead > maxBytes) {
                    outError = L"更新文件超出大小限制";
                    streamErr = true;
                    break;
                }
                if (hFile != INVALID_HANDLE_VALUE) {
                    DWORD written = 0;
                    if (!WriteFile(hFile, buf.data(), got, &written, nullptr) || written != got) {
                        outError = L"写入本地更新包失败";
                        streamErr = true;
                        break;
                    }
                } else if (outMemory) {
                    outMemory->append(buf.data(), got);
                }
                avail -= got;
            }
            if (streamErr) break;
        }
        if (!streamErr) {
            if (hFile != INVALID_HANDLE_VALUE) FlushFileBuffers(hFile);
            ok = true;
        }
    } while (false);

    if (hFile != INVALID_HANDLE_VALUE) {
        CloseHandle(hFile);
        if (!ok && !destFile.empty()) DeleteFileW(destFile.c_str());
    }
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return ok;
}

} // namespace

int CompareSemVer(const std::wstring& a, const std::wstring& b) {
    SemVerParts pa = ParseSemVer(a);
    SemVerParts pb = ParseSemVer(b);
    if (!pa.valid || !pb.valid) {
        return _wcsicmp(a.c_str(), b.c_str());
    }
    if (pa.major != pb.major) return pa.major < pb.major ? -1 : 1;
    if (pa.minor != pb.minor) return pa.minor < pb.minor ? -1 : 1;
    if (pa.patch != pb.patch) return pa.patch < pb.patch ? -1 : 1;
    if (pa.prerelease.empty() != pb.prerelease.empty()) {
        return pa.prerelease.empty() ? 1 : -1;
    }
    return _wcsicmp(pa.prerelease.c_str(), pb.prerelease.c_str());
}

bool IsValidSha256Hex(const std::wstring& hex) {
    if (hex.size() != 64) return false;
    for (wchar_t c : hex) {
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F')))
            return false;
    }
    return true;
}

bool IsSafeFileName(const std::wstring& name) {
    if (name.empty() || name == L"." || name == L"..") return false;
    for (wchar_t c : name) {
        if (c == L'\\' || c == L'/' || c == L':' || c < 32) return false;
    }
    return true;
}

bool ComputeBufferSha256Hex(const void* data, size_t length, std::wstring& outHex) {
    outHex.clear();
    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;
    if (BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return false;

    bool ok = false;
    do {
        DWORD objLen = 0, cbData = 0, hashLen = 0;
        if (BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objLen), sizeof(objLen), &cbData, 0) != 0 ||
            BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hashLen), sizeof(hashLen), &cbData, 0) != 0 ||
            hashLen != 32) {
            break;
        }
        std::vector<UCHAR> hashObj(objLen);
        std::vector<UCHAR> digest(hashLen);
        if (BCryptCreateHash(hAlg, &hHash, hashObj.data(), objLen, nullptr, 0, 0) != 0) break;
        if (length > 0 && BCryptHashData(hHash, reinterpret_cast<PUCHAR>(const_cast<void*>(data)), static_cast<ULONG>(length), 0) != 0) break;
        if (BCryptFinishHash(hHash, digest.data(), hashLen, 0) != 0) break;
        outHex = BytesToLowerHex(digest.data(), digest.size());
        ok = true;
    } while (false);

    if (hHash) BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);
    return ok;
}

bool ComputeFileSha256Hex(const std::wstring& filePath, std::wstring& outHex, std::wstring& outError) {
    outHex.clear();
    HANDLE hFile = CreateFileW(filePath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) {
        outError = L"无法打开待校验文件";
        return false;
    }

    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;
    if (BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) {
        CloseHandle(hFile);
        outError = L"无法初始化 SHA256 算法";
        return false;
    }

    bool ok = false;
    do {
        DWORD objLen = 0, cbData = 0, hashLen = 0;
        if (BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objLen), sizeof(objLen), &cbData, 0) != 0 ||
            BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hashLen), sizeof(hashLen), &cbData, 0) != 0 ||
            hashLen != 32) {
            outError = L"SHA256 属性读取失败";
            break;
        }
        std::vector<UCHAR> hashObj(objLen);
        std::vector<UCHAR> digest(hashLen);
        if (BCryptCreateHash(hAlg, &hHash, hashObj.data(), objLen, nullptr, 0, 0) != 0) {
            outError = L"无法创建 SHA256 哈希器";
            break;
        }
        std::vector<UCHAR> buf(65536);
        bool readErr = false;
        for (;;) {
            DWORD got = 0;
            if (!ReadFile(hFile, buf.data(), static_cast<DWORD>(buf.size()), &got, nullptr)) {
                readErr = true;
                break;
            }
            if (got == 0) break;
            if (BCryptHashData(hHash, buf.data(), got, 0) != 0) {
                readErr = true;
                break;
            }
        }
        if (readErr || BCryptFinishHash(hHash, digest.data(), hashLen, 0) != 0) {
            outError = L"计算文件 SHA256 失败";
            break;
        }
        outHex = BytesToLowerHex(digest.data(), digest.size());
        ok = true;
    } while (false);

    if (hHash) BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);
    CloseHandle(hFile);
    return ok;
}

UpdateConfig LoadUpdateConfig(const std::wstring& path) {
    UpdateConfig cfg{};
    std::string raw;
    if (!ReadFileUtf8(path, raw)) return cfg;
    JsonValue doc;
    if (!JsonValue::Parse(raw, doc) || doc.kind != JsonValue::Kind::Object) return cfg;
    if (auto v = doc.GetWide("provider"); !v.empty()) cfg.provider = v;
    if (auto v = doc.GetWide("repository"); !v.empty()) cfg.repository = v;
    if (auto v = doc.GetWide("channel"); !v.empty()) cfg.channel = v;
    if (auto v = doc.GetWide("manifestAsset"); !v.empty()) cfg.manifestAsset = v;
    cfg.localFeedDirectory = doc.GetWide("localFeedDirectory");
    return cfg;
}

UpdateCheckResult CheckForUpdate(const UpdateConfig& config, const std::wstring& currentVersion, const std::wstring& distribution) {
    UpdateCheckResult res{};
    std::string manifestRaw;
    if (!config.localFeedDirectory.empty()) {
        std::wstring manifestName = IsSafeFileName(config.manifestAsset) ? config.manifestAsset : L"release-manifest.json";
        std::wstring localPath = JoinPath(config.localFeedDirectory, manifestName);
        if (!ReadFileUtf8(localPath, manifestRaw)) {
            res.error = L"无法读取本地更新清单: " + localPath;
            return res;
        }
    } else {
        if (config.repository.empty() || config.repository.find(L'/') == std::wstring::npos) {
            res.error = L"尚未配置有效的 GitHub 仓库（owner/repo）";
            return res;
        }
        std::wstring manifestName = IsSafeFileName(config.manifestAsset) ? config.manifestAsset : L"release-manifest.json";
        std::wstring url = L"https://github.com/" + config.repository + L"/releases/latest/download/" + manifestName;
        if (!HttpDownloadToFileOrMemory(url, &manifestRaw, L"", 1024 * 1024, res.error)) {
            return res;
        }
    }

    JsonValue doc;
    std::string parseErr;
    if (!JsonValue::Parse(manifestRaw, doc, &parseErr) || doc.kind != JsonValue::Kind::Object) {
        res.error = L"更新清单 JSON 格式无效";
        return res;
    }

    res.manifest.version = TrimWide(doc.GetWide("version"));
    res.manifest.publishedAt = doc.GetWide("publishedAt");
    res.manifest.assetName = TrimWide(doc.GetWide("assetName"));
    res.manifest.downloadUrl = TrimWide(doc.GetWide("downloadUrl"));
    res.manifest.sha256 = TrimWide(doc.GetWide("sha256"));
    res.manifest.sizeBytes = static_cast<uint64_t>(std::max<int64_t>(0, doc.GetInt64("sizeBytes", 0)));
    res.manifest.minAntigravityVersion = doc.GetWide("minAntigravityVersion");
    res.manifest.releaseNotes = doc.GetWide("releaseNotes");

    if (distribution == L"lite" || distribution == L"portable") {
        const auto* choices = doc.Get("distributions");
        const auto* asset = choices ? choices->Get(distribution == L"portable" ? "portable" : "lite") : nullptr;
        if (!asset || asset->kind != JsonValue::Kind::Object) {
            res.error = L"此版本的更新源未提供当前类型的安装包";
            return res;
        }
        res.manifest.assetName = TrimWide(asset->GetWide("assetName"));
        res.manifest.downloadUrl = TrimWide(asset->GetWide("downloadUrl"));
        res.manifest.sha256 = TrimWide(asset->GetWide("sha256"));
        res.manifest.sizeBytes = static_cast<uint64_t>(std::max<int64_t>(0, asset->GetInt64("sizeBytes", 0)));
        if (res.manifest.sizeBytes == 0) {
            res.error = L"Lite 更新清单未提供有效的安装包大小";
            return res;
        }
    }
    if (res.manifest.version.empty() || !IsSafeFileName(res.manifest.assetName) || !IsValidSha256Hex(res.manifest.sha256)) {
        res.error = L"更新清单缺少必要字段（version / assetName / sha256）";
        return res;
    }

    res.ok = true;
    res.hasUpdate = CompareSemVer(res.manifest.version, currentVersion) > 0;
    return res;
}

bool DownloadAndVerifyUpdate(
    const UpdateConfig& config,
    const UpdateManifest& manifest,
    const std::wstring& stagingDir,
    std::wstring& outZipPath,
    std::wstring& outError) {

    outZipPath.clear();
    if (!IsSafeFileName(manifest.assetName) || !IsValidSha256Hex(manifest.sha256)) {
        outError = L"更新包清单元数据不合法";
        return false;
    }
    if (!EnsureDirectoryTree(stagingDir)) {
        outError = L"无法创建更新暂存目录";
        return false;
    }

    std::wstring finalZip = JoinPath(stagingDir, manifest.assetName);
    std::wstring partZip = finalZip + L".part";
    DeleteFileW(partZip.c_str());

    if (!config.localFeedDirectory.empty()) {
        std::wstring srcZip = JoinPath(config.localFeedDirectory, manifest.assetName);
        if (!CopyFileW(srcZip.c_str(), partZip.c_str(), FALSE)) {
            outError = L"复制本地更新包失败: " + srcZip;
            return false;
        }
    } else {
        std::wstring url = manifest.downloadUrl;
        if (url.empty()) {
            url = L"https://github.com/" + config.repository + L"/releases/latest/download/" + manifest.assetName;
        }
        if (!HttpDownloadToFileOrMemory(url, nullptr, partZip, 512ULL * 1024ULL * 1024ULL, outError)) {
            return false;
        }
    }

    WIN32_FILE_ATTRIBUTE_DATA info{};
    if (manifest.sizeBytes &&
        (!GetFileAttributesExW(partZip.c_str(), GetFileExInfoStandard, &info) ||
         ((static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow) != manifest.sizeBytes)) {
        DeleteFileW(partZip.c_str());
        outError = L"更新包大小与清单不一致";
        return false;
    }
    std::wstring actualSha;
    if (!ComputeFileSha256Hex(partZip, actualSha, outError)) {
        DeleteFileW(partZip.c_str());
        return false;
    }
    if (_wcsicmp(actualSha.c_str(), manifest.sha256.c_str()) != 0) {
        DeleteFileW(partZip.c_str());
        outError = L"更新包 SHA-256 校验不匹配，已拒绝安装";
        return false;
    }

    if (!MoveFileExW(partZip.c_str(), finalZip.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(partZip.c_str());
        outError = L"无法提交已校验的更新包";
        return false;
    }

    outZipPath = finalZip;
    return true;
}

bool LaunchApplyUpdate(
    const std::wstring& zipPath,
    const std::wstring& expectedSha256,
    const std::wstring& applyScriptSource,
    const std::wstring& pluginDir,
    const std::wstring& dataDir,
    bool relaunchPanel,
    std::wstring& outError) {

    if (!FileExists(applyScriptSource)) {
        outError = L"缺少更新脚本 Apply-Update.ps1";
        return false;
    }
    std::wstring updatesDir = JoinPath(dataDir, L"updates");
    EnsureDirectoryTree(updatesDir);
    std::wstring stagedScript = JoinPath(updatesDir, L"apply-update.ps1");
    const auto helperName = L"Review-Mode.ps1";
    const auto helperSource = JoinPath(GetDirectoryName(applyScriptSource), helperName);
    if (!CopyFileW(helperSource.c_str(), JoinPath(updatesDir, helperName).c_str(), FALSE)) {
        outError = L"无法复制更新所需的 PowerShell 脚本";
        return false;
    }
    if (!CopyFileW(applyScriptSource.c_str(), stagedScript.c_str(), FALSE)) {
        outError = L"无法复制更新事务脚本";
        return false;
    }
    {
        const auto helper = L"Portable.ps1";
        if (!CopyFileW(JoinPath(GetDirectoryName(applyScriptSource), helper).c_str(), JoinPath(updatesDir, helper).c_str(), FALSE)) {
            outError = L"无法复制免安装版更新脚本";
            return false;
        }
    }

    wchar_t sysDir[MAX_PATH]{};
    GetSystemDirectoryW(sysDir, static_cast<DWORD>(std::size(sysDir)));
    std::wstring psExe = JoinPath(sysDir, L"WindowsPowerShell\\v1.0\\powershell.exe");
    if (!FileExists(psExe)) {
        outError = L"未找到 Windows PowerShell";
        return false;
    }

    DWORD pid = GetCurrentProcessId();
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + stagedScript + L"\"" +
                        L" -WaitPid " + std::to_wstring(pid) +
                        L" -PackageZip \"" + zipPath + L"\"" +
                        L" -ExpectedSha256 \"" + expectedSha256 + L"\"" +
                        L" -PluginDirectory \"" + pluginDir + L"\"" +
                        L" -DataDirectory \"" + dataDir + L"\"";
    if (relaunchPanel) args += L" -RelaunchPanel";

    if (!LaunchDetached(psExe, args, updatesDir, true)) {
        outError = L"无法启动独立更新进程";
        return false;
    }
    return true;
}

} // namespace panel
