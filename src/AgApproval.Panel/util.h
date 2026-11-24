#pragma once

#include <windows.h>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace panel {

std::wstring Utf8ToWide(std::string_view utf8);
std::string WideToUtf8(std::wstring_view wide);
std::wstring TrimWide(std::wstring_view text);
std::wstring GetExecutablePath();
std::wstring GetDirectoryName(std::wstring_view path);
std::wstring JoinPath(std::wstring_view base, std::wstring_view child);
bool FileExists(const std::wstring& path);
bool DirectoryExists(const std::wstring& path);
bool EnsureDirectoryTree(const std::wstring& dir);
bool ReadFileUtf8(const std::wstring& path, std::string& out);
bool WriteFileUtf8Atomic(const std::wstring& path, std::string_view content);
uint64_t SumFilesSize(const std::wstring& dir, const std::wstring& extensionLower);

struct JsonValue {
    enum class Kind { Null, Bool, Int, Double, String, Array, Object };

    Kind kind = Kind::Null;
    bool boolVal = false;
    int64_t intVal = 0;
    double doubleVal = 0.0;
    std::string strVal;
    std::vector<JsonValue> arrVal;
    std::map<std::string, JsonValue, std::less<>> objVal;

    static bool Parse(std::string_view input, JsonValue& out, std::string* err = nullptr);
    std::string Dump(bool pretty = false, int indent = 0) const;

    const JsonValue* Get(std::string_view key) const;
    JsonValue* GetMut(std::string_view key);
    std::string GetString(std::string_view key, std::string_view fallback = "") const;
    std::wstring GetWide(std::string_view key, std::wstring_view fallback = L"") const;
    int64_t GetInt64(std::string_view key, int64_t fallback = 0) const;
    double GetDouble(std::string_view key, double fallback = 0.0) const;
    bool GetBool(std::string_view key, bool fallback = false) const;
};

struct CommandResult {
    bool started = false;
    bool timedOut = false;
    DWORD exitCode = 0;
    std::string stdoutUtf8;
    std::string stderrUtf8;
};

CommandResult RunHiddenCommand(
    const std::wstring& exe,
    const std::wstring& args,
    const std::wstring& workDir,
    DWORD timeoutMs = 15000);

bool LaunchDetached(
    const std::wstring& exe,
    const std::wstring& args,
    const std::wstring& workDir,
    bool hidden = false);

bool IsProcessRunningByPath(const std::wstring& exePath);

std::wstring GetAutostartCommand();
bool IsAutostartMatching(const std::wstring& exePath);
bool SetAutostart(bool enabled, const std::wstring& exePath);

std::wstring BrowseExecutableFile(HWND owner, const wchar_t* title, const wchar_t* defaultFile);
void OpenPathWithShell(const std::wstring& path);

std::wstring FormatBytes(uint64_t bytes);
std::wstring FormatIntWithCommas(int64_t value);
std::wstring FormatUsd(double usd);

} // namespace panel
