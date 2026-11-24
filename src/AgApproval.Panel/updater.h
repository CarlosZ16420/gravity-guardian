#pragma once

#include <windows.h>
#include <cstdint>
#include <string>

namespace panel {

struct UpdateConfig {
    std::wstring provider = L"github-releases";
    std::wstring repository = L"CarlosZ16420/gravity-steward";
    std::wstring channel = L"stable";
    std::wstring manifestAsset = L"release-manifest.json";
    std::wstring localFeedDirectory;
};

struct UpdateManifest {
    std::wstring version;
    std::wstring publishedAt;
    std::wstring assetName;
    std::wstring downloadUrl;
    std::wstring sha256;
    uint64_t sizeBytes = 0;
    std::wstring minAntigravityVersion;
    std::wstring releaseNotes;
};

struct UpdateCheckResult {
    bool ok = false;
    bool hasUpdate = false;
    UpdateManifest manifest;
    std::wstring error;
};

int CompareSemVer(const std::wstring& a, const std::wstring& b);
bool IsValidSha256Hex(const std::wstring& hex);
bool IsSafeFileName(const std::wstring& name);

bool ComputeBufferSha256Hex(const void* data, size_t length, std::wstring& outHex);
bool ComputeFileSha256Hex(const std::wstring& filePath, std::wstring& outHex, std::wstring& outError);

UpdateConfig LoadUpdateConfig(const std::wstring& path);

UpdateCheckResult CheckForUpdate(const UpdateConfig& config, const std::wstring& currentVersion);

bool DownloadAndVerifyUpdate(
    const UpdateConfig& config,
    const UpdateManifest& manifest,
    const std::wstring& stagingDir,
    std::wstring& outZipPath,
    std::wstring& outError);

bool LaunchApplyUpdate(
    const std::wstring& zipPath,
    const std::wstring& expectedSha256,
    const std::wstring& applyScriptSource,
    const std::wstring& pluginDir,
    const std::wstring& dataDir,
    bool relaunchPanel,
    std::wstring& outError);

} // namespace panel
