#include "util.h"
#include <commdlg.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cwctype>
#include <thread>

namespace panel {

std::wstring Utf8ToWide(std::string_view utf8) {
    if (utf8.empty()) return {};
    int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    if (needed <= 0) return {};
    std::wstring wide(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(), needed);
    return wide;
}

std::string WideToUtf8(std::wstring_view wide) {
    if (wide.empty()) return {};
    int needed = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return {};
    std::string utf8(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), utf8.data(), needed, nullptr, nullptr);
    return utf8;
}

std::wstring TrimWide(std::wstring_view text) {
    size_t start = 0;
    while (start < text.size() && (text[start] == L' ' || text[start] == L'\t' || text[start] == L'\r' || text[start] == L'\n')) {
        ++start;
    }
    size_t end = text.size();
    while (end > start && (text[end - 1] == L' ' || text[end - 1] == L'\t' || text[end - 1] == L'\r' || text[end - 1] == L'\n')) {
        --end;
    }
    return std::wstring(text.substr(start, end - start));
}

std::wstring GetExecutablePath() {
    std::wstring buf(MAX_PATH, L'\0');
    for (;;) {
        DWORD len = GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
        if (len == 0) return {};
        if (len < buf.size() - 1) {
            buf.resize(len);
            return buf;
        }
        buf.resize(buf.size() * 2);
    }
}

std::wstring GetDirectoryName(std::wstring_view path) {
    auto pos = path.find_last_of(L"\\/");
    if (pos == std::wstring_view::npos) return {};
    return std::wstring(path.substr(0, pos));
}

std::wstring JoinPath(std::wstring_view base, std::wstring_view child) {
    if (base.empty()) return std::wstring(child);
    if (child.empty()) return std::wstring(base);
    std::wstring out(base);
    while (!out.empty() && (out.back() == L'\\' || out.back() == L'/')) out.pop_back();
    while (!child.empty() && (child.front() == L'\\' || child.front() == L'/')) child.remove_prefix(1);
    out.push_back(L'\\');
    out.append(child);
    return out;
}

bool FileExists(const std::wstring& path) {
    if (path.empty()) return false;
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool DirectoryExists(const std::wstring& path) {
    if (path.empty()) return false;
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool EnsureDirectoryTree(const std::wstring& dir) {
    if (dir.empty()) return false;
    if (DirectoryExists(dir)) return true;
    std::wstring parent = GetDirectoryName(dir);
    if (!parent.empty() && parent != dir && !DirectoryExists(parent)) {
        if (!EnsureDirectoryTree(parent)) return false;
    }
    if (CreateDirectoryW(dir.c_str(), nullptr)) return true;
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

bool ReadFileUtf8(const std::wstring& path, std::string& out) {
    out.clear();
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size) || size.QuadPart < 0 || size.QuadPart > 64 * 1024 * 1024) {
        CloseHandle(h);
        return false;
    }
    out.resize(static_cast<size_t>(size.QuadPart));
    size_t total = 0;
    while (total < out.size()) {
        DWORD chunk = 0;
        DWORD toRead = static_cast<DWORD>(std::min<size_t>(out.size() - total, 1024 * 1024));
        if (!ReadFile(h, out.data() + total, toRead, &chunk, nullptr) || chunk == 0) {
            CloseHandle(h);
            out.clear();
            return false;
        }
        total += chunk;
    }
    CloseHandle(h);
    if (out.size() >= 3 &&
        static_cast<unsigned char>(out[0]) == 0xEF &&
        static_cast<unsigned char>(out[1]) == 0xBB &&
        static_cast<unsigned char>(out[2]) == 0xBF) {
        out.erase(0, 3);
    }
    return true;
}

bool WriteFileUtf8Atomic(const std::wstring& path, std::string_view content) {
    std::wstring dir = GetDirectoryName(path);
    if (!dir.empty()) EnsureDirectoryTree(dir);
    std::wstring tmp = path + L".tmp";
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    size_t offset = 0;
    bool ok = true;
    while (offset < content.size()) {
        DWORD written = 0;
        DWORD toWrite = static_cast<DWORD>(std::min<size_t>(content.size() - offset, 1024 * 1024));
        if (!WriteFile(h, content.data() + offset, toWrite, &written, nullptr) || written != toWrite) {
            ok = false;
            break;
        }
        offset += written;
    }
    if (ok) FlushFileBuffers(h);
    CloseHandle(h);
    if (!ok) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    return true;
}

uint64_t SumFilesSize(const std::wstring& dir, const std::wstring& extensionLower) {
    if (!DirectoryExists(dir)) return 0;
    WIN32_FIND_DATAW fd{};
    std::wstring pattern = JoinPath(dir, L"*");
    HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    uint64_t total = 0;
    do {
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
        std::wstring name = fd.cFileName;
        if (!extensionLower.empty()) {
            auto dot = name.rfind(L'.');
            if (dot == std::wstring::npos) continue;
            std::wstring ext = name.substr(dot);
            for (wchar_t& ch : ext) ch = static_cast<wchar_t>(std::towlower(ch));
            if (ext != extensionLower) continue;
        }
        total += (static_cast<uint64_t>(fd.nFileSizeHigh) << 32) | fd.nFileSizeLow;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return total;
}

namespace {

struct JsonParser {
    std::string_view s;
    size_t i = 0;
    std::string error;

    void SkipWs() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
    }

    bool Fail(std::string msg) {
        error = std::move(msg);
        return false;
    }

    static void AppendUtf8Codepoint(uint32_t cp, std::string& out) {
        if (cp <= 0x7F) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7FF) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp <= 0xFFFF) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool ParseHex4(uint32_t& val) {
        if (i + 4 > s.size()) return Fail("Truncated unicode escape");
        val = 0;
        for (int k = 0; k < 4; ++k) {
            char c = s[i++];
            val <<= 4;
            if (c >= '0' && c <= '9') val |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') val |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') val |= static_cast<uint32_t>(c - 'A' + 10);
            else return Fail("Invalid hex escape");
        }
        return true;
    }

    bool ParseString(std::string& out) {
        if (i >= s.size() || s[i] != '"') return Fail("Expected '\"'");
        ++i;
        out.clear();
        while (i < s.size()) {
            char c = s[i++];
            if (c == '"') return true;
            if (c == '\\') {
                if (i >= s.size()) return Fail("Unterminated escape");
                char e = s[i++];
                switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    uint32_t cp = 0;
                    if (!ParseHex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF && i + 2 <= s.size() && s[i] == '\\' && s[i + 1] == 'u') {
                        i += 2;
                        uint32_t low = 0;
                        if (!ParseHex4(low)) return false;
                        if (low >= 0xDC00 && low <= 0xDFFF) {
                            cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
                        }
                    }
                    AppendUtf8Codepoint(cp, out);
                    break;
                }
                default: return Fail("Invalid escape character");
                }
            } else {
                out.push_back(c);
            }
        }
        return Fail("Unterminated string");
    }

    bool ParseNumber(JsonValue& out) {
        size_t start = i;
        if (s[i] == '-') ++i;
        if (i >= s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return Fail("Invalid number");
        while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) ++i;
        bool isFloat = false;
        if (i < s.size() && s[i] == '.') {
            isFloat = true;
            ++i;
            if (i >= s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return Fail("Invalid fraction");
            while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) ++i;
        }
        if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
            isFloat = true;
            ++i;
            if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
            if (i >= s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return Fail("Invalid exponent");
            while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) ++i;
        }
        std::string numStr(s.substr(start, i - start));
        if (!isFloat) {
            char* endPtr = nullptr;
            errno = 0;
            long long iv = std::strtoll(numStr.c_str(), &endPtr, 10);
            if (errno == 0 && endPtr == numStr.c_str() + numStr.size()) {
                out.kind = JsonValue::Kind::Int;
                out.intVal = iv;
                out.doubleVal = static_cast<double>(iv);
                return true;
            }
        }
        char* endPtr = nullptr;
        double dv = std::strtod(numStr.c_str(), &endPtr);
        if (endPtr != numStr.c_str() + numStr.size()) return Fail("Failed to parse number");
        out.kind = JsonValue::Kind::Double;
        out.doubleVal = dv;
        out.intVal = static_cast<int64_t>(dv);
        return true;
    }

    bool ParseValue(JsonValue& out, int depth) {
        if (depth > 64) return Fail("JSON depth exceeded");
        SkipWs();
        if (i >= s.size()) return Fail("Unexpected end of JSON");
        char c = s[i];
        if (c == 'n' && s.substr(i, 4) == "null") {
            i += 4;
            out = JsonValue{};
            out.kind = JsonValue::Kind::Null;
            return true;
        }
        if (c == 't' && s.substr(i, 4) == "true") {
            i += 4;
            out = JsonValue{};
            out.kind = JsonValue::Kind::Bool;
            out.boolVal = true;
            return true;
        }
        if (c == 'f' && s.substr(i, 5) == "false") {
            i += 5;
            out = JsonValue{};
            out.kind = JsonValue::Kind::Bool;
            out.boolVal = false;
            return true;
        }
        if (c == '"') {
            out = JsonValue{};
            out.kind = JsonValue::Kind::String;
            return ParseString(out.strVal);
        }
        if (c == '-' || std::isdigit(static_cast<unsigned char>(c))) {
            out = JsonValue{};
            return ParseNumber(out);
        }
        if (c == '[') {
            ++i;
            out = JsonValue{};
            out.kind = JsonValue::Kind::Array;
            SkipWs();
            if (i < s.size() && s[i] == ']') { ++i; return true; }
            for (;;) {
                JsonValue elem;
                if (!ParseValue(elem, depth + 1)) return false;
                out.arrVal.push_back(std::move(elem));
                SkipWs();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == ']') { ++i; return true; }
                return Fail("Expected ',' or ']'");
            }
        }
        if (c == '{') {
            ++i;
            out = JsonValue{};
            out.kind = JsonValue::Kind::Object;
            SkipWs();
            if (i < s.size() && s[i] == '}') { ++i; return true; }
            for (;;) {
                SkipWs();
                std::string key;
                if (!ParseString(key)) return false;
                SkipWs();
                if (i >= s.size() || s[i] != ':') return Fail("Expected ':'");
                ++i;
                JsonValue val;
                if (!ParseValue(val, depth + 1)) return false;
                out.objVal.insert_or_assign(std::move(key), std::move(val));
                SkipWs();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == '}') { ++i; return true; }
                return Fail("Expected ',' or '}'");
            }
        }
        return Fail("Unexpected token");
    }
};

void EscapeJsonString(std::string_view text, std::string& out) {
    out.push_back('"');
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out.push_back(static_cast<char>(c));
            }
        }
    }
    out.push_back('"');
}

} // namespace

bool JsonValue::Parse(std::string_view input, JsonValue& out, std::string* err) {
    if (input.size() >= 3 &&
        static_cast<unsigned char>(input[0]) == 0xEF &&
        static_cast<unsigned char>(input[1]) == 0xBB &&
        static_cast<unsigned char>(input[2]) == 0xBF) {
        input.remove_prefix(3);
    }
    JsonParser parser{input};
    if (!parser.ParseValue(out, 0)) {
        if (err) *err = parser.error;
        return false;
    }
    parser.SkipWs();
    if (parser.i != parser.s.size()) {
        if (err) *err = "Trailing data after JSON";
        return false;
    }
    return true;
}

std::string JsonValue::Dump(bool pretty, int indent) const {
    std::string out;
    auto addIndent = [&](int level) {
        if (pretty) out.append(static_cast<size_t>(level) * 2, ' ');
    };
    switch (kind) {
    case Kind::Null: return "null";
    case Kind::Bool: return boolVal ? "true" : "false";
    case Kind::Int: return std::to_string(intVal);
    case Kind::Double: {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%.10g", doubleVal);
        return buf;
    }
    case Kind::String:
        EscapeJsonString(strVal, out);
        return out;
    case Kind::Array:
        if (arrVal.empty()) return "[]";
        out.push_back('[');
        if (pretty) out.push_back('\n');
        for (size_t k = 0; k < arrVal.size(); ++k) {
            if (k > 0) {
                out.push_back(',');
                if (pretty) out.push_back('\n');
            }
            addIndent(indent + 1);
            out += arrVal[k].Dump(pretty, indent + 1);
        }
        if (pretty) { out.push_back('\n'); addIndent(indent); }
        out.push_back(']');
        return out;
    case Kind::Object:
        if (objVal.empty()) return "{}";
        out.push_back('{');
        if (pretty) out.push_back('\n');
        bool first = true;
        for (const auto& [k, v] : objVal) {
            if (!first) {
                out.push_back(',');
                if (pretty) out.push_back('\n');
            }
            first = false;
            addIndent(indent + 1);
            EscapeJsonString(k, out);
            out += (pretty ? ": " : ":");
            out += v.Dump(pretty, indent + 1);
        }
        if (pretty) { out.push_back('\n'); addIndent(indent); }
        out.push_back('}');
        return out;
    }
    return "null";
}

const JsonValue* JsonValue::Get(std::string_view key) const {
    if (kind != Kind::Object) return nullptr;
    auto it = objVal.find(key);
    return it == objVal.end() ? nullptr : &it->second;
}

JsonValue* JsonValue::GetMut(std::string_view key) {
    if (kind != Kind::Object) return nullptr;
    auto it = objVal.find(key);
    return it == objVal.end() ? nullptr : &it->second;
}

std::string JsonValue::GetString(std::string_view key, std::string_view fallback) const {
    const auto* v = Get(key);
    return (v && v->kind == Kind::String) ? v->strVal : std::string(fallback);
}

std::wstring JsonValue::GetWide(std::string_view key, std::wstring_view fallback) const {
    const auto* v = Get(key);
    return (v && v->kind == Kind::String) ? Utf8ToWide(v->strVal) : std::wstring(fallback);
}

int64_t JsonValue::GetInt64(std::string_view key, int64_t fallback) const {
    const auto* v = Get(key);
    if (!v) return fallback;
    if (v->kind == Kind::Int) return v->intVal;
    if (v->kind == Kind::Double) return static_cast<int64_t>(v->doubleVal);
    return fallback;
}

double JsonValue::GetDouble(std::string_view key, double fallback) const {
    const auto* v = Get(key);
    if (!v) return fallback;
    if (v->kind == Kind::Double) return v->doubleVal;
    if (v->kind == Kind::Int) return static_cast<double>(v->intVal);
    return fallback;
}

bool JsonValue::GetBool(std::string_view key, bool fallback) const {
    const auto* v = Get(key);
    return (v && v->kind == Kind::Bool) ? v->boolVal : fallback;
}

namespace {

void DrainPipe(HANDLE hPipe, std::string& out) {
    char buf[4096];
    DWORD read = 0;
    while (ReadFile(hPipe, buf, sizeof(buf), &read, nullptr) && read > 0) {
        if (out.size() < 4 * 1024 * 1024) {
            out.append(buf, read);
        }
    }
}

} // namespace

CommandResult RunHiddenCommand(
    const std::wstring& exe,
    const std::wstring& args,
    const std::wstring& workDir,
    DWORD timeoutMs) {
    CommandResult res{};
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE outRead = nullptr, outWrite = nullptr;
    HANDLE errRead = nullptr, errWrite = nullptr;
    if (!CreatePipe(&outRead, &outWrite, &sa, 0)) return res;
    if (!CreatePipe(&errRead, &errWrite, &sa, 0)) {
        CloseHandle(outRead); CloseHandle(outWrite);
        return res;
    }
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = outWrite;
    si.hStdError = errWrite;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    std::wstring cmdLine = L"\"" + exe + L"\"";
    if (!args.empty()) cmdLine += L" " + args;

    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessW(
        exe.c_str(),
        cmdLine.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr,
        workDir.empty() ? nullptr : workDir.c_str(),
        &si,
        &pi);

    CloseHandle(outWrite);
    CloseHandle(errWrite);

    if (!ok) {
        CloseHandle(outRead);
        CloseHandle(errRead);
        return res;
    }

    res.started = true;
    std::thread tOut([&]() { DrainPipe(outRead, res.stdoutUtf8); });
    std::thread tErr([&]() { DrainPipe(errRead, res.stderrUtf8); });

    DWORD waitRes = WaitForSingleObject(pi.hProcess, timeoutMs);
    if (waitRes == WAIT_TIMEOUT) {
        res.timedOut = true;
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
    }
    GetExitCodeProcess(pi.hProcess, &res.exitCode);

    tOut.join();
    tErr.join();
    CloseHandle(outRead);
    CloseHandle(errRead);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return res;
}

bool LaunchDetached(
    const std::wstring& exe,
    const std::wstring& args,
    const std::wstring& workDir,
    bool hidden) {
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = hidden ? SW_HIDE : SW_SHOWNORMAL;

    std::wstring cmdLine = L"\"" + exe + L"\"";
    if (!args.empty()) cmdLine += L" " + args;

    PROCESS_INFORMATION pi{};
    DWORD flags = hidden ? (CREATE_NO_WINDOW | DETACHED_PROCESS) : 0;
    BOOL ok = CreateProcessW(
        exe.c_str(),
        cmdLine.data(),
        nullptr,
        nullptr,
        FALSE,
        flags,
        nullptr,
        workDir.empty() ? nullptr : workDir.c_str(),
        &si,
        &pi);
    if (!ok) return false;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}

bool IsProcessRunningByPath(const std::wstring& exePath) {
    if (exePath.empty()) return false;
    std::wstring fullTarget(MAX_PATH, L'\0');
    DWORD len = GetFullPathNameW(exePath.c_str(), MAX_PATH, fullTarget.data(), nullptr);
    if (len > 0 && len < MAX_PATH) fullTarget.resize(len);
    else fullTarget = exePath;

    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;

    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    bool found = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            if (proc) {
                wchar_t procPath[MAX_PATH * 2]{};
                DWORD pathLen = static_cast<DWORD>(std::size(procPath));
                if (QueryFullProcessImageNameW(proc, 0, procPath, &pathLen)) {
                    if (_wcsicmp(procPath, fullTarget.c_str()) == 0) {
                        found = true;
                    }
                }
                CloseHandle(proc);
                if (found) break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

namespace {
constexpr const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t* kRunValue = L"AntigravityCodexApproval";
} // namespace

std::wstring GetAutostartCommand() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) != ERROR_SUCCESS) return {};
    wchar_t buf[2048]{};
    DWORD bytes = sizeof(buf);
    DWORD type = 0;
    LONG rc = RegQueryValueExW(key, kRunValue, nullptr, &type, reinterpret_cast<LPBYTE>(buf), &bytes);
    RegCloseKey(key);
    if (rc != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) return {};
    return buf;
}

bool IsAutostartMatching(const std::wstring& exePath) {
    std::wstring cur = GetAutostartCommand();
    if (cur.empty() || exePath.empty()) return false;
    std::wstring expected = L"\"" + exePath + L"\" --minimized";
    return _wcsicmp(cur.c_str(), expected.c_str()) == 0;
}

bool SetAutostart(bool enabled, const std::wstring& exePath) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS)
        return false;
    LONG rc = ERROR_SUCCESS;
    if (enabled) {
        std::wstring cmd = L"\"" + exePath + L"\" --minimized";
        DWORD bytes = static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t));
        rc = RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()), bytes);
    } else {
        rc = RegDeleteValueW(key, kRunValue);
        if (rc == ERROR_FILE_NOT_FOUND) rc = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return rc == ERROR_SUCCESS;
}

std::wstring BrowseExecutableFile(HWND owner, const wchar_t* title, const wchar_t* defaultFile) {
    wchar_t fileBuf[MAX_PATH * 2]{};
    if (defaultFile && *defaultFile) {
        wcsncpy_s(fileBuf, defaultFile, _TRUNCATE);
    }
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = L"可执行文件 (*.exe;*.cmd)\0*.exe;*.cmd\0所有文件 (*.*)\0*.*\0";
    ofn.lpstrFile = fileBuf;
    ofn.nMaxFile = static_cast<DWORD>(std::size(fileBuf));
    ofn.lpstrTitle = title;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&ofn)) return fileBuf;
    return {};
}

void OpenPathWithShell(const std::wstring& path) {
    if (path.empty()) return;
    ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

std::wstring FormatBytes(uint64_t bytes) {
    wchar_t buf[64];
    if (bytes < 1024) {
        std::swprintf(buf, std::size(buf), L"%llu B", static_cast<unsigned long long>(bytes));
    } else if (bytes < 1024ULL * 1024ULL) {
        std::swprintf(buf, std::size(buf), L"%.1f KB", static_cast<double>(bytes) / 1024.0);
    } else if (bytes < 1024ULL * 1024ULL * 1024ULL) {
        std::swprintf(buf, std::size(buf), L"%.2f MB", static_cast<double>(bytes) / (1024.0 * 1024.0));
    } else {
        std::swprintf(buf, std::size(buf), L"%.2f GB", static_cast<double>(bytes) / (1024.0 * 1024.0 * 1024.0));
    }
    return buf;
}

std::wstring FormatIntWithCommas(int64_t value) {
    bool neg = value < 0;
    uint64_t absVal = neg ? static_cast<uint64_t>(-(value + 1)) + 1ULL : static_cast<uint64_t>(value);
    std::wstring raw = std::to_wstring(absVal);
    std::wstring out;
    int cnt = 0;
    for (auto it = raw.rbegin(); it != raw.rend(); ++it) {
        if (cnt > 0 && cnt % 3 == 0) out.push_back(L',');
        out.push_back(*it);
        ++cnt;
    }
    if (neg) out.push_back(L'-');
    std::reverse(out.begin(), out.end());
    return out;
}

std::wstring FormatUsd(double usd) {
    wchar_t buf[64];
    if (usd < 0.000001) return L"$0.0000";
    if (usd < 1.0) {
        std::swprintf(buf, std::size(buf), L"$%.4f", usd);
    } else {
        std::swprintf(buf, std::size(buf), L"$%.2f", usd);
    }
    return buf;
}

} // namespace panel
