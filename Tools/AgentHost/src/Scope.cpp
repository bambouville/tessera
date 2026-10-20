#include "Scope.h"
#include "Catalog.h"
#include "LocalTransport.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <array>
#include <cerrno>
#include <chrono>
#include <poll.h>
#include <stdexcept>

namespace tessera {
void restoreProviderScope(const std::string& base, const std::string& token) {
    if (token.size() != 16 || token.find_first_not_of("0123456789abcdef") != std::string::npos ||
        !ownedDirectory(base, false)) throw std::runtime_error("contextScopeUnavailable");
    const auto runtime = base + "/" + token;
    if (!ownedDirectory(runtime, false)) throw std::runtime_error("contextScopeUnavailable");
    const auto path = runtime + "/scope";
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (descriptor < 0) throw std::runtime_error("contextScopeUnavailable");
    struct Guard { int fd; ~Guard() { ::close(fd); } } guard{descriptor};
    struct stat info{};
    if (::fstat(descriptor, &info) || !S_ISREG(info.st_mode) || info.st_uid != ::geteuid() ||
        info.st_nlink != 1 || info.st_size <= 0 || info.st_size > 8192)
        throw std::runtime_error("contextScopeUnavailable");
    std::array<char, 8193> bytes{};
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    if (count != info.st_size) throw std::runtime_error("contextScopeUnavailable");
    const std::string witness(bytes.data(), static_cast<size_t>(count));
    size_t position = 0;
    auto line = [&] {
        const auto end = witness.find('\n', position);
        if (end == std::string::npos) throw std::runtime_error("contextScopeUnavailable");
        auto value = witness.substr(position, end - position); position = end + 1; return value;
    };
    if (line() != "tessera-agent-scope-1" || line() != "uid=" + std::to_string(::geteuid()))
        throw std::runtime_error("contextScopeUnavailable");
    auto root = [&](const std::string& prefix, const std::string& suffix) {
        const auto value = line();
        if (value.size() <= prefix.size() + suffix.size() || value.compare(0, prefix.size(), prefix) ||
            value.compare(value.size() - suffix.size(), suffix.size(), suffix))
            throw std::runtime_error("contextScopeUnavailable");
        return value.substr(prefix.size(), value.size() - prefix.size() - suffix.size());
    };
    const auto codex = root("codex:", "/sessions");
    if (root("codex:", "/archived_sessions") != codex) throw std::runtime_error("contextScopeUnavailable");
    const auto claude = root("claude:", "/projects");
    const auto pi = root("pi:", "/sessions");
    const auto data = root("opencode:", "/opencode");
    const auto kimi = root("kimi:", "/sessions");
    if (::setenv("CODEX_HOME", codex.c_str(), 1) || ::setenv("CLAUDE_CONFIG_DIR", claude.c_str(), 1) ||
        ::setenv("PI_CODING_AGENT_DIR", pi.c_str(), 1) || ::setenv("XDG_DATA_HOME", data.c_str(), 1) ||
        ::setenv("KIMI_CODE_HOME", kimi.c_str(), 1))
        throw std::runtime_error("contextScopeUnavailable");
    Catalog::freezeProviderEnvironment();
    // Includes all namespace fields and re-canonicalized roots. A replaced
    // symlink, namespace, malformed witness or hash collision fails closed.
    if (Catalog().scopeIdentity() != witness || scopedRuntime(base, false, 1000) != runtime)
        throw std::runtime_error("contextScopeUnavailable");
}

std::string providerScopeToken(const std::string& runtime) {
    const auto slash = runtime.rfind('/');
    if (slash == std::string::npos) return {};
    const auto token = runtime.substr(slash + 1);
    if (token.size() != 16 || token.find_first_not_of("0123456789abcdef") != std::string::npos) return {};
    // A scoped service must never permanently downgrade its reconnect support
    // merely because a concurrent attach briefly owns the scope witness lock.
    if (scopedRuntime(runtime.substr(0, slash), false, 1000) != runtime)
        throw std::runtime_error("contextScopeUnavailable");
    return token;
}

std::string scopedRuntime(const std::string& base, bool create, int lockWaitMs) {
    const auto identity = Catalog().scopeIdentity();
    if (identity.size() > 8192 || !ownedDirectory(base, create)) throw std::runtime_error("scopeUnavailable");
    // Compact lookup key, not a credential or a security hash. The owned
    // witness's content check below fails closed even on a forced collision.
    uint64_t hash = 14695981039346656037ULL;
    for (unsigned char byte : identity) { hash ^= byte; hash *= 1099511628211ULL; }
    std::string name(16, '0');
    for (int index = 15; index >= 0; --index) { name[index] = "0123456789abcdef"[hash & 15]; hash >>= 4; }
    const auto runtime = base + "/" + name;
    if (!ownedDirectory(runtime, create)) throw std::runtime_error("scopeUnavailable");
    const auto path = runtime + "/scope";
    const int fd = ::open(path.c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0), 0600);
    if (fd < 0) throw std::runtime_error("scopeUnavailable");
    struct Guard { int fd; ~Guard() { ::close(fd); } } guard{fd};
    struct stat info{};
    if (::fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != ::geteuid() ||
        info.st_nlink != 1) throw std::runtime_error("scopeUnavailable");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(lockWaitMs < 0 ? (create ? 1000 : 0) : lockWaitMs);
    while (::flock(fd, LOCK_EX | LOCK_NB)) {
        if ((errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR) ||
            std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("scopeUnavailable");
        ::poll(nullptr, 0, 5);
    }
    // A concurrent first client may have written the witness while we waited.
    if (::fstat(fd, &info)) throw std::runtime_error("scopeUnavailable");
    if (!info.st_size && create) {
        const auto size = static_cast<ssize_t>(identity.size());
        if (::write(fd, identity.data(), identity.size()) != size || ::fsync(fd)) throw std::runtime_error("scopeUnavailable");
    } else {
        std::array<char, 8193> bytes{};
        const auto count = ::read(fd, bytes.data(), bytes.size());
        if (count < 0 || std::string(bytes.data(), static_cast<size_t>(count)) != identity) throw std::runtime_error("scopeMismatch");
    }
    return runtime;
}
}
