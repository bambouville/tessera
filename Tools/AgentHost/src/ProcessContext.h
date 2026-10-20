#pragma once
#include "Catalog.h"
#include "Json.h"
#include "Scope.h"
#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <poll.h>
#include <set>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#endif

namespace tessera {
// Only allowlisted provider-root variables are retained, never arbitrary environment
// values, PATH, credentials or caller-supplied roots. The temporary kernel
// environment buffer is wiped on every exit, before a service can be forked.
// The SSH-authenticated
// account may select its own live process; kernel UID/start evidence brackets
// capture. Same-UID process impersonation remains outside the security boundary.
inline void captureProviderContext(int pid) {
    if (pid <= 1) throw std::runtime_error("invalidContextPID");
    std::map<std::string, std::string> roots;
    auto environment = [&](std::string_view entry) {
        const auto split = entry.find('=');
        if (split == std::string_view::npos) return;
        const auto key = entry.substr(0, split);
        if (key != "CODEX_HOME" && key != "CLAUDE_CONFIG_DIR" && key != "PI_CODING_AGENT_DIR" && key != "XDG_DATA_HOME" && key != "KIMI_CODE_HOME") return;
        const auto value = entry.substr(split + 1);
        if (value.size() > 2048 || !roots.emplace(std::string(key), std::string(value)).second)
            throw std::runtime_error("contextEnvironmentInvalid");
    };
    constexpr size_t maximumEnvironment = 1024 * 1024;
    std::string bytes(maximumEnvironment, '\0');
    struct Wipe {
        char* data; size_t size;
        ~Wipe() { volatile char* target = data; while (size--) *target++ = 0; }
    } wipe{bytes.data(), bytes.size()};
#ifdef __APPLE__
    auto identity = [&] {
        proc_bsdinfo info{};
        if (::proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.pbi_pid != static_cast<uint32_t>(pid) || info.pbi_uid != ::geteuid() ||
            info.pbi_ruid != ::geteuid() || !info.pbi_start_tvsec)
            throw std::runtime_error("contextProcessUnavailable");
        return std::make_pair(info.pbi_start_tvsec, info.pbi_start_tvusec);
    };
    const auto before = identity();
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t count = bytes.size();
    if (::sysctl(mib, 3, bytes.data(), &count, nullptr, 0) || count < sizeof(int))
        throw std::runtime_error("contextEnvironmentUnavailable");
    bytes.resize(count);
    int argc = 0; std::memcpy(&argc, bytes.data(), sizeof(argc));
    if (argc < 1 || argc > 65536) throw std::runtime_error("contextEnvironmentInvalid");
    size_t position = sizeof(argc);
    auto word = [&]() -> std::string_view {
        const auto end = bytes.find('\0', position);
        if (end == std::string::npos) throw std::runtime_error("contextEnvironmentInvalid");
        auto value = std::string_view(bytes).substr(position, end - position);
        position = end + 1; return value;
    };
    word(); // Kernel executable pathname, then padding, then argc arguments.
    while (position < bytes.size() && bytes[position] == '\0') ++position;
    for (int index = 0; index < argc; ++index) word();
    while (position < bytes.size() && bytes[position]) environment(word());
    if (identity() != before) throw std::runtime_error("contextProcessChanged");
#elif defined(__linux__)
    const auto path = "/proc/" + std::to_string(pid);
    const int directory = ::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) throw std::runtime_error("contextProcessUnavailable");
    struct Guard { int fd; ~Guard() { ::close(fd); } } guard{directory};
    auto identity = [&] {
        struct stat info{};
        if (::fstat(directory, &info) || info.st_uid != ::geteuid())
            throw std::runtime_error("contextProcessUnavailable");
        // Absolute provider roots only mean the same thing within the same
        // filesystem/user namespace and chroot. Never translate foreign roots.
        for (const auto* name : {"ns/mnt", "ns/pid", "ns/user", "root"}) {
            struct stat target{}, own{};
            const auto self = std::string("/proc/self/") + name;
            if (::fstatat(directory, name, &target, 0) || ::stat(self.c_str(), &own) ||
                target.st_dev != own.st_dev || target.st_ino != own.st_ino)
                throw std::runtime_error("contextNamespaceMismatch");
        }
        const int descriptor = ::openat(directory, "stat", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (descriptor < 0) throw std::runtime_error("contextProcessUnavailable");
        Guard file{descriptor}; std::array<char, 8192> raw{};
        const auto count = ::read(descriptor, raw.data(), raw.size());
        if (count <= 0 || static_cast<size_t>(count) == raw.size()) throw std::runtime_error("contextProcessUnavailable");
        std::string_view value(raw.data(), static_cast<size_t>(count));
        const auto close = value.rfind(')');
        if (close == std::string_view::npos || close + 2 >= value.size()) throw std::runtime_error("contextProcessUnavailable");
        value.remove_prefix(close + 2);
        for (int field = 3; field <= 22; ++field) {
            const auto end = value.find(' ');
            if (end == std::string_view::npos || !end) throw std::runtime_error("contextProcessUnavailable");
            if (field == 22) {
                uint64_t start = 0;
                const auto parsed = std::from_chars(value.data(), value.data() + end, start);
                if (parsed.ec != std::errc() || parsed.ptr != value.data() + end || !start)
                    throw std::runtime_error("contextProcessUnavailable");
                return start;
            }
            value.remove_prefix(end + 1);
        }
        throw std::runtime_error("contextProcessUnavailable");
    };
    const auto before = identity();
    const int descriptor = ::openat(directory, "environ", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) throw std::runtime_error("contextEnvironmentUnavailable");
    Guard file{descriptor}; size_t count = 0;
    for (;;) {
        const auto read = ::read(descriptor, bytes.data() + count, bytes.size() - count);
        if (read < 0 && errno == EINTR) continue;
        if (read < 0) throw std::runtime_error("contextEnvironmentUnavailable");
        if (!read) break;
        count += static_cast<size_t>(read);
        if (count == bytes.size()) throw std::runtime_error("contextEnvironmentCapacity");
    }
    bytes.resize(count);
    size_t position = 0;
    while (position < bytes.size()) {
        const auto end = bytes.find('\0', position);
        if (end == std::string::npos) throw std::runtime_error("contextEnvironmentInvalid");
        environment(std::string_view(bytes).substr(position, end - position)); position = end + 1;
    }
    if (identity() != before) throw std::runtime_error("contextProcessChanged");
#else
    throw std::runtime_error("contextUnsupported");
#endif
    for (const auto* key : {"CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "XDG_DATA_HOME", "KIMI_CODE_HOME"}) {
        const auto found = roots.find(key);
        if (found == roots.end() || found->second.empty()) {
            if (::unsetenv(key)) throw std::runtime_error("contextEnvironmentUnavailable");
        } else if (::setenv(key, found->second.c_str(), 1)) throw std::runtime_error("contextEnvironmentUnavailable");
    }
    Catalog::freezeProviderEnvironment();
}

inline std::string contextHello(const std::string& runtimeBase = {}) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    auto exact = [&](char* bytes, size_t size) {
        size_t offset = 0;
        while (offset < size) {
            if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("contextHelloTimeout");
            pollfd descriptor{STDIN_FILENO, POLLIN, 0};
            const auto ready = ::poll(&descriptor, 1, 100);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) throw std::runtime_error("contextHelloUnavailable");
            if (!ready) continue;
            const auto count = ::read(STDIN_FILENO, bytes + offset, size - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) throw std::runtime_error("contextHelloUnavailable");
            offset += static_cast<size_t>(count);
        }
    };
    std::string frame(4, '\0'); exact(frame.data(), 4);
    uint32_t length = 0;
    for (unsigned char byte : frame) length = (length << 8) | byte;
    if (!length || length > 8192) throw std::runtime_error("contextHelloCapacity");
    frame.resize(length + 4); exact(frame.data() + 4, length);
    simdjson::dom::parser parser; simdjson::dom::element value;
    if (parser.parse(frame.data() + 4, length).get(value) || !value.is_object())
        throw std::runtime_error("contextHelloInvalid");
    std::set<std::string_view> fields;
    for (const auto field : simdjson::dom::object(value.get_object().value())) if (!fields.insert(field.key).second)
        throw std::runtime_error("contextHelloInvalid");
    int64_t version = 0;
    if (json::text(value, "kind") != "hello" || json::get(value, "v").get_int64().get(version) || version != 3)
        throw std::runtime_error("contextHelloInvalid");
    const auto id = json::text(value, "id");
    if (id.empty() || id.size() > 128 || id.find_first_not_of(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos)
        throw std::runtime_error("contextHelloInvalid");
    if (fields.count("contextScope")) {
        if (fields.count("contextPID")) throw std::runtime_error("contextHelloInvalid");
        restoreProviderScope(runtimeBase, json::text(value, "contextScope"));
    } else if (fields.count("contextPID")) {
        int64_t pid = 0;
        if (json::get(value, "contextPID").get_int64().get(pid) || pid <= 1 || pid > INT32_MAX)
            throw std::runtime_error("invalidContextPID");
        captureProviderContext(static_cast<int>(pid));
    } else Catalog::freezeProviderEnvironment();
    return frame;
}
}
