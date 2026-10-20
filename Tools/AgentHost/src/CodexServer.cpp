#include "CodexServer.h"
#include "BoundedJson.h"
#include "Json.h"
#include "ProcStat.h"
#include <simdjson.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <cstdlib>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <array>
#include <chrono>
#include <cerrno>
#include <stdexcept>
#include <vector>
#include <cstring>
#ifndef __APPLE__
#include <dirent.h>
#endif
#ifdef __APPLE__
#include <libproc.h>
#include <crt_externs.h>
#else
extern char** environ;
#endif

namespace tessera {
namespace {
using Clock = std::chrono::steady_clock;
bool safeExecutablePath(const std::string& path) {
    if (path.empty() || path.front() != '/') return false;
    auto current = path;
    bool leaf = true;
    while (!current.empty()) {
        struct stat info{};
        if (::lstat(current.c_str(), &info) || (info.st_uid != 0 && info.st_uid != ::geteuid())) return false;
        if (S_ISLNK(info.st_mode)) {
            // Validate the resolved chain separately, including the target.
        } else {
            // Ownership by root or this user along the whole chain is the
            // criterion; mode bits are not, since npm-style installs on a
            // umask 0002 host leave the executable and its directories
            // group-writable by the owner's own choice.
            if (leaf ? !S_ISREG(info.st_mode) : !S_ISDIR(info.st_mode)) return false;
        }
        leaf = false;
        if (current == "/") break;
        const auto slash = current.rfind('/');
        current = slash == 0 ? "/" : current.substr(0, slash);
    }
    return true;
}
bool nativeExecutable(const std::string& path) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return false;
    unsigned char bytes[4]{};
    const auto count = ::read(fd, bytes, sizeof(bytes)); ::close(fd);
    return count == 4 && ((bytes[0] == 0x7f && bytes[1] == 'E' && bytes[2] == 'L' && bytes[3] == 'F') ||
        (bytes[0] == 0xcf && bytes[1] == 0xfa && bytes[2] == 0xed && bytes[3] == 0xfe) ||
        (bytes[0] == 0xca && bytes[1] == 0xfe && bytes[2] == 0xba && (bytes[3] == 0xbe || bytes[3] == 0xbf)));
}
std::string resolveCodex() {
    const char* raw = ::getenv("PATH");
    const std::string path = raw ? raw : "";
    size_t start = 0;
    while (start <= path.size()) {
        const auto end = path.find(':', start);
        const auto directory = path.substr(start, end == std::string::npos ? end : end - start);
        if (!directory.empty() && directory.front() == '/') {
            const auto candidate = directory + "/codex";
            struct stat info{};
            if (!::stat(candidate.c_str(), &info) && S_ISREG(info.st_mode) && !::access(candidate.c_str(), X_OK)) {
                char resolved[PATH_MAX];
                if (!safeExecutablePath(candidate) || !::realpath(candidate.c_str(), resolved) || !safeExecutablePath(resolved))
                    throw std::runtime_error("codexUnsafeExecutable");
                // Scripts can perform another unvalidated PATH lookup (the
                // Tessera shim and npm/env-node launcher both do). Automatic
                // reads only spawn native providers; otherwise use JSONL.
                if (!nativeExecutable(resolved)) throw std::runtime_error("codexUnsafeExecutable");
                return resolved;
            }
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    throw std::runtime_error("codexUnavailable");
}
bool readMethod(const std::string& method) {
    return method == "initialize" || method == "thread/list" || method == "thread/read" ||
        method == "thread/items/list" || method == "thread/turns/list";
}
}
CodexServer::CodexServer(std::function<bool()> cancelled) : cancelled_(std::move(cancelled)) {}
CodexServer::~CodexServer() { stop(); }
void CodexServer::supervise() {
    if (process_ < 0) return;
    try { checkResources(true); } catch (...) { stop(); }
}
void CodexServer::start(Clock::time_point operationDeadline, bool verifiedVersion) {
    if (!verifiedVersion) executable_ = resolveCodex();
    if (!safeExecutablePath(executable_)) throw std::runtime_error("codexUnsafeExecutable");
    int input[2]{-1, -1}, output[2]{-1, -1};
    if (::pipe(input) || ::pipe(output)) {
        for (int fd : {input[0], input[1], output[0], output[1]}) if (fd >= 0) ::close(fd);
        throw std::runtime_error("codexUnavailable");
    }
    for (int fd : {input[0], input[1], output[0], output[1]}) ::fcntl(fd, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions; ::posix_spawn_file_actions_init(&actions);
    ::posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    ::posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    ::posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    for (int fd : {input[0], input[1], output[0], output[1]}) ::posix_spawn_file_actions_addclose(&actions, fd);
    char program[] = "codex", subcommand[] = "app-server", listen[] = "--listen", stdio[] = "stdio://";
    char* arguments[] = {program, subcommand, listen, stdio, nullptr};
    char versionArgument[] = "--version";
    char* versionArguments[] = {program, versionArgument, nullptr};
#ifdef __APPLE__
    auto environment = *_NSGetEnviron();
#else
    auto environment = environ;
#endif
    // Versioned upstream 0.154.0 daemon marker: process-local only, does not
    // change persisted remote-control preferences/enrollment. Never call the
    // mutating remoteControl/disable RPC against the user's state database.
    std::vector<std::string> environmentValues;
    constexpr const char* disabled = "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=";
    for (auto entry = environment; *entry; ++entry) {
        if (std::strncmp(*entry, disabled, std::strlen(disabled))) environmentValues.emplace_back(*entry);
    }
    environmentValues.emplace_back(std::string(disabled) + "1");
    std::vector<char*> childEnvironment;
    for (auto& value : environmentValues) childEnvironment.push_back(value.data());
    childEnvironment.push_back(nullptr);
    posix_spawnattr_t attributes; ::posix_spawnattr_init(&attributes);
    ::posix_spawnattr_setpgroup(&attributes, 0);
    ::posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    const int result = ::posix_spawn(&process_, executable_.c_str(), &actions, &attributes,
        verifiedVersion ? arguments : versionArguments, childEnvironment.data());
    ::posix_spawnattr_destroy(&attributes);
    ::posix_spawn_file_actions_destroy(&actions);
    ::close(input[0]); ::close(output[1]);
    if (result) { ::close(input[1]); ::close(output[0]); process_ = -1; throw std::runtime_error("codexUnavailable"); }
    input_ = input[1]; output_ = output[0];
    ::fcntl(input_, F_SETFL, ::fcntl(input_, F_GETFL) | O_NONBLOCK);
    ::fcntl(output_, F_SETFL, ::fcntl(output_, F_GETFL) | O_NONBLOCK);
    if (!verifiedVersion) {
        std::string version;
        const auto deadline = std::min(operationDeadline, Clock::now() + std::chrono::seconds(1));
        while (Clock::now() < deadline && version.find('\n') == std::string::npos) {
            checkResources();
            pollfd item{output_, POLLIN, 0}; ::poll(&item, 1, 20);
            std::array<char, 128> bytes{};
            const auto count = ::read(output_, bytes.data(), bytes.size());
            if (!count) break;
            if (count > 0) version.append(bytes.data(), count);
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) break;
            if (version.size() > 128) break;
        }
        stop();
        // The process-local remote-control override is internal upstream API.
        // Never assume an untested version honors it: JSONL remains available.
        if (version != "codex-cli 0.154.0\n") throw std::runtime_error("codexVersionUnsupported");
        start(operationDeadline, true); return;
    }
    // Startup and capability negotiation do not resume or own any thread.
    (void)call("initialize", "{\"clientInfo\":{\"name\":\"tessera-agent-host\",\"version\":\"0.2.0\"},\"capabilities\":{\"experimentalApi\":true}}", operationDeadline);
    const std::string initialized = "{\"method\":\"initialized\"}\n";
    size_t sent = 0;
    const auto deadline = std::min(operationDeadline, Clock::now() + std::chrono::seconds(1));
    while (sent < initialized.size()) {
        checkResources();
        if (Clock::now() >= deadline) throw std::runtime_error("codexReadDeadlineExceeded");
        const auto count = ::write(input_, initialized.data() + sent, initialized.size() - sent);
        if (count > 0) sent += static_cast<size_t>(count);
        else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) throw std::runtime_error("codexDisconnected");
        else { pollfd item{input_, POLLOUT, 0}; ::poll(&item, 1, 20); }
    }
}
void CodexServer::stop() {
    invalidateCachedReads();
    if (input_ >= 0) ::close(input_);
    if (output_ >= 0) ::close(output_);
    input_ = output_ = -1; pending_.clear();
    if (process_ <= 0) return;
    const auto owned = process_; process_ = -1;
    int status{};
    // Keep the leader unreaped until its group has been killed: its PID
    // cannot be recycled into an unrelated process group during cleanup.
    ::kill(-owned, SIGTERM);
    const auto deadline = Clock::now() + std::chrono::milliseconds(250);
    while (Clock::now() < deadline && ::kill(-owned, 0) == 0) {
        siginfo_t exited{};
        if (!::waitid(P_PID, owned, &exited, WEXITED | WNOHANG | WNOWAIT) && exited.si_pid == owned) break;
        ::poll(nullptr, 0, 5);
    }
    ::kill(-owned, SIGKILL);
    while (::waitpid(owned, &status, 0) < 0 && errno == EINTR) {}
}
void CodexServer::checkResources(bool idle) {
    if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
    const auto now = Clock::now();
    // Linux process-group enumeration reads the host's /proc table. Doing
    // that on every idle worker wakeup makes idle cost depend on unrelated
    // host process cardinality. Keep the 50 ms active-read guard, but sample
    // an idle owned child at 1 Hz. This is sampled supervision, not an OS
    // allocation limit; a new read immediately restores the active cadence.
    if (now - lastResourceCheck_ < std::chrono::milliseconds(idle ? 1000 : 50)) return;
    lastResourceCheck_ = now;
    uint64_t resident = 0;
    std::vector<pid_t> members;
#ifdef __APPLE__
    std::array<pid_t, 65> processes{};
    const int bytes = ::proc_listpids(PROC_PGRP_ONLY, process_, processes.data(), sizeof(processes));
    if (bytes < 0 || bytes >= static_cast<int>(sizeof(processes))) throw std::runtime_error("codexProcessBudgetExceeded");
    for (int index = 0; index < bytes / static_cast<int>(sizeof(pid_t)); ++index) if (processes[index] > 0) members.push_back(processes[index]);
    for (const auto member : members) {
        rusage_info_v2 usage{};
        if (!::proc_pid_rusage(member, RUSAGE_INFO_V2, reinterpret_cast<rusage_info_t*>(&usage))) resident += usage.ri_resident_size;
        else if (::kill(member, 0) == 0 || errno != ESRCH) throw std::runtime_error("codexResourceMonitorUnavailable");
    }
#elif defined(__linux__)
    DIR* directory = ::opendir("/proc");
    if (!directory) throw std::runtime_error("codexResourceMonitorUnavailable");
    size_t entries = 0;
    const auto pageSize = ::sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) { ::closedir(directory); throw std::runtime_error("codexResourceMonitorUnavailable"); }
    while (const auto* entry = ::readdir(directory)) {
        if (++entries > 32768) { ::closedir(directory); throw std::runtime_error("codexProcessBudgetExceeded"); }
        const std::string name(entry->d_name);
        if (name.empty() || name.find_first_not_of("0123456789") != std::string::npos) continue;
        const int descriptor = ::open(("/proc/" + name + "/stat").c_str(), O_RDONLY | O_CLOEXEC);
        if (descriptor < 0) continue; // exited or outside this UID's visible proc view
        std::array<char, 4096> buffer{};
        ssize_t count;
        do { count = ::read(descriptor, buffer.data(), buffer.size()); } while (count < 0 && errno == EINTR);
        ::close(descriptor);
        if (count <= 0) continue; // process exited between enumeration and read
        const auto status = count < static_cast<ssize_t>(buffer.size()) ?
            parseProcStat(std::string_view(buffer.data(), static_cast<size_t>(count))) : std::nullopt;
        if (!status) { ::closedir(directory); throw std::runtime_error("codexResourceMonitorUnavailable"); }
        if (status->group != process_) continue;
        if (members.size() >= 64) { ::closedir(directory); throw std::runtime_error("codexProcessBudgetExceeded"); }
        members.push_back(status->pid);
        if (status->residentPages > (UINT64_MAX - resident) / static_cast<uint64_t>(pageSize)) {
            ::closedir(directory); throw std::runtime_error("codexMemoryBudgetExceeded");
        }
        resident += status->residentPages * static_cast<uint64_t>(pageSize);
    }
    ::closedir(directory);
#endif
    peakResident_ = std::max(peakResident_, resident);
    if (resident > 192 * 1024 * 1024) throw std::runtime_error("codexMemoryBudgetExceeded");
}
std::string CodexServer::call(const std::string& method, const std::string& params, Clock::time_point operationDeadline, size_t maximumBytes, bool allowCached) {
    if (!readMethod(method) || params.size() > 32768) throw std::runtime_error("invalidRequest");
    try {
        if (Clock::now() >= operationDeadline) throw std::runtime_error("codexReadDeadlineExceeded");
        if (process_ < 0) start(operationDeadline);
        checkResources();
        // Share only read-only item responses, never client transactions or
        // ACK state. The age starts BEFORE the provider read. Manual reads
        // bypass this cache; their caller invalidates it before a fresh sweep.
        const auto readStarted = Clock::now();
        const auto cacheKey = method == "thread/items/list" ? params : "";
        for (auto it = cache_.begin(); it != cache_.end();) {
            if (readStarted - it->second.observed >= std::chrono::milliseconds(200)) {
                cacheBytes_ -= it->second.bytes; it = cache_.erase(it);
            } else ++it;
        }
        const auto cached = cache_.find(cacheKey);
        if (allowCached && cached != cache_.end() && cached->second.value.size() <= maximumBytes) {
            responseTruncated_ = cached->second.truncated;
            return cached->second.value;
        }
        const auto id = ++nextID_;
        const auto request = "{\"id\":" + std::to_string(id) + ",\"method\":" + json::quote(method) + ",\"params\":" + params + "}\n";
        const auto deadline = std::min(operationDeadline, Clock::now() + std::chrono::seconds(method == "initialize" ? 8 : 5));
        size_t sent = 0, consumed = 0, ignored = 0;
        std::string line;
        BoundedJson bounded;
        bool oversized = false;
        simdjson::dom::parser parser;
        while (Clock::now() < deadline) {
            checkResources();
            if (sent < request.size()) {
                const auto count = ::write(input_, request.data() + sent, request.size() - sent);
                if (count > 0) sent += static_cast<size_t>(count);
                else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) throw std::runtime_error("codexDisconnected");
            }
            if (pending_.empty()) {
                pollfd descriptors[] = {{output_, POLLIN, 0}, {input_, static_cast<short>(sent < request.size() ? POLLOUT : 0), 0}};
                if (::poll(descriptors, 2, 20) < 0 && errno != EINTR) throw std::runtime_error("codexDisconnected");
                std::array<char, 16384> bytes;
                const auto count = ::read(output_, bytes.data(), bytes.size());
                if (!count) throw std::runtime_error("codexDisconnected");
                if (count < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
                    throw std::runtime_error("codexDisconnected");
                }
                pending_.assign(bytes.data(), static_cast<size_t>(count));
            }
            const auto newline = pending_.find('\n');
            const auto length = newline == std::string::npos ? pending_.size() : newline;
            const auto observed = length + (newline == std::string::npos ? 0 : 1);
            consumed += observed; bytesRead_ += observed;
            if (consumed > maximumBytes) throw std::runtime_error("codexResponseBudgetExceeded");
            if (!oversized && line.size() + length > BoundedJson::maximumDocument) { bounded.feed(line); line.clear(); oversized = true; }
            if (oversized) bounded.feed(std::string_view(pending_).substr(0, length));
            else line.append(pending_.data(), length);
            pending_.erase(0, length + (newline == std::string::npos ? 0 : 1));
            if (newline == std::string::npos) continue;
            simdjson::dom::element response;
            if ((oversized && (bounded.malformed() || bounded.unsupported())) ||
                parser.parse(oversized ? bounded.json() : line).get(response)) throw std::runtime_error("codexMalformedResponse");
            if (!json::get(response, "method").is_null()) {
                if (!json::get(response, "id").is_null()) throw std::runtime_error("codexUnexpectedServerRequest");
                if (++ignored > 1024) throw std::runtime_error("codexResponseBudgetExceeded");
            } else if (json::integer(response, "id") == static_cast<int64_t>(id)) {
                const auto error = json::get(response, "error");
                if (!error.is_null()) {
                    const auto code = json::integer(error, "code");
                    if (code == -32601 || code == -32600 || code == -32602) throw std::runtime_error("codexPaginationUnavailable");
                    throw std::runtime_error("codexReadFailed");
                }
                const auto value = json::get(response, "result");
                if (!value.is_object()) throw std::runtime_error("codexMalformedResponse");
                responseTruncated_ = oversized && bounded.truncated();
                auto normalized = simdjson::minify(value);
                if (!cacheKey.empty() && normalized.size() <= 128 * 1024) {
                    auto previous = cache_.find(cacheKey);
                    if (previous != cache_.end()) { cacheBytes_ -= previous->second.bytes; cache_.erase(previous); }
                    const auto cost = cacheKey.size() + normalized.size() + 256;
                    while (!cache_.empty() && (cache_.size() >= 1024 || cacheBytes_ + cost > 8 * 1024 * 1024)) {
                        cacheBytes_ -= cache_.begin()->second.bytes; cache_.erase(cache_.begin());
                    }
                    cache_.emplace(cacheKey, CachedRead{normalized, readStarted, responseTruncated_, cost});
                    cacheBytes_ += cost;
                }
                return normalized;
            } else throw std::runtime_error("codexUnexpectedResponse");
            line.clear(); bounded = BoundedJson(); oversized = false;
        }
        throw std::runtime_error("codexReadDeadlineExceeded");
    } catch (const std::runtime_error& error) {
        // A supported RPC returning a capability/read error does not corrupt
        // its transport. Keep the child for other paginated threads.
        const auto reason = std::string(error.what());
        if (reason != "codexPaginationUnavailable" && reason != "codexReadFailed") stop();
        throw;
    } catch (...) { stop(); throw; }
}
}
