#include "Catalog.h"
#include "TranscriptLayout.h"
#include "JsonlReader.h"
#include "Json.h"
#include "OpenCodeStore.h"
#include "KimiHistoryIndex.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pwd.h>
#include <dirent.h>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <limits.h>
#include <memory>
#include <random>
#include <stdexcept>
#include <simdjson.h>

namespace tessera {
namespace {
// Walk from / using directory descriptors. No ancestor symlink or '..' can
// redirect an authorized source open, even during a concurrent rename.
int openComponents(const std::string& path, bool directory = false) {
    if (path.empty() || path[0] != '/' || path.size() > 2048 || path.back() == '/' ||
        path.find('\0') != std::string::npos) { errno = EINVAL; return -1; }
    int current = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (size_t start = 1; current >= 0 && start < path.size();) {
        auto end = path.find('/', start);
        auto part = path.substr(start, end == std::string::npos ? path.size() - start : end - start);
        if (part.empty() || part == "." || part == "..") { ::close(current); return -1; }
        const bool parent = end != std::string::npos;
        int next = ::openat(current, part.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK |
            ((parent || directory) ? O_DIRECTORY : 0));
        const int openError = errno;
        ::close(current); current = next;
        if (next < 0) errno = openError;
        if (!parent) break;
        start = end + 1;
    }
    return current;
}
std::string environmentPath(const char* name, const std::string& fallback) {
    const auto value = ::getenv(name);
    std::string path = value && *value ? value : fallback;
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    if (path.empty() || path.front() != '/' || path.size() > 2048 ||
        path.find('\0') != std::string::npos || path.find('\n') != std::string::npos ||
        path.find('\r') != std::string::npos || !simdjson::validate_utf8(path))
        throw std::runtime_error("invalidProviderRoot");
    // Configured roots, not transcript content, define authority. Canonicalize
    // existing ancestors even when a provider has not created its home yet,
    // so /tmp aliases and equivalent SSH routes share the same scope witness.
    std::error_code error;
    auto canonical = std::filesystem::weakly_canonical(path, error).string();
    if (error || canonical.empty() || canonical.size() > 2048) throw std::runtime_error("invalidProviderRoot");
    return canonical;
}
}
std::string randomID() {
    std::random_device random;
    std::string value;
    for (int n = 0; n < 4; ++n) {
        auto word = random();
        for (int k = 0; k < 8; ++k) { value += "0123456789abcdef"[word & 15]; word >>= 4; }
    }
    return value;
}
Catalog::Catalog() {
    const auto user = ::getpwuid(::geteuid());
    if (!user || !user->pw_dir) throw std::runtime_error("homeUnavailable");
    const auto home = std::string(user->pw_dir);
    const auto codex = environmentPath("CODEX_HOME", home + "/.codex");
    codexHome_ = codex;
    const auto claude = environmentPath("CLAUDE_CONFIG_DIR", home + "/.claude");
    const auto pi = environmentPath("PI_CODING_AGENT_DIR", home + "/.pi/agent");
    const auto data = environmentPath("XDG_DATA_HOME", home + "/.local/share");
    const auto kimi = environmentPath("KIMI_CODE_HOME", home + "/.kimi-code");
    roots_ = {{"codex", codex + "/sessions"}, {"codex", codex + "/archived_sessions"},
              {"claude", claude + "/projects"}, {"pi", pi + "/sessions"}, {"opencode", data + "/opencode"}, {"kimi", kimi + "/sessions"}};
}
std::string Catalog::codexMetadataPath(const Source& source) const {
    if (source.provider != "codex" || sources_.find(source.handle) == sources_.end())
        throw std::runtime_error("sourceNotAuthorized");
    const int descriptor = openComponents(codexHome_, true);
    if (descriptor < 0) {
        if (errno == ENOENT) return {};
        throw std::runtime_error("sourceNotAuthorized");
    }
    DIR* directory = ::fdopendir(descriptor);
    if (!directory) { ::close(descriptor); throw std::runtime_error("sourceUnavailable"); }
    std::unique_ptr<DIR, decltype(&::closedir)> owned(directory, ::closedir);
    std::string selected; int version = -1; size_t count = 0;
    while (auto* entry = ::readdir(directory)) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        if (++count > 16384) throw std::runtime_error("codexMetadataCapacity");
        const std::string name(entry->d_name);
        if (name.size() < 14 || name.size() > 17 || name.substr(0, 6) != "state_" ||
            name.substr(name.size() - 7) != ".sqlite") continue;
        const auto digits = name.substr(6, name.size() - 13);
        if (digits.empty() || digits.find_first_not_of("0123456789") != std::string::npos) continue;
        const int candidate = std::stoi(digits);
        if (candidate > version) { version = candidate; selected = name; }
    }
    if (selected.empty()) return {};
    return codexHome_ + "/" + selected;
}
std::string Catalog::codexTitle(const Source& source) const {
    const auto path = codexMetadataPath(source);
    return path.empty() ? std::string() : OpenCodeStore::codexTitle(path, source.sessionID, cancelled);
}
OpenCodeStore::CodexMetadata Catalog::codexMetadata(const Source& source) const {
    const auto path = codexMetadataPath(source);
    return path.empty() ? OpenCodeStore::CodexMetadata{} : OpenCodeStore::codexMetadata(path, source.sessionID, cancelled);
}
void Catalog::freezeProviderEnvironment() {
    const auto user = ::getpwuid(::geteuid());
    if (!user || !user->pw_dir) throw std::runtime_error("homeUnavailable");
    const std::string home(user->pw_dir);
    const auto codex = environmentPath("CODEX_HOME", home + "/.codex");
    const auto claude = environmentPath("CLAUDE_CONFIG_DIR", home + "/.claude");
    const auto pi = environmentPath("PI_CODING_AGENT_DIR", home + "/.pi/agent");
    const auto data = environmentPath("XDG_DATA_HOME", home + "/.local/share");
    const auto kimi = environmentPath("KIMI_CODE_HOME", home + "/.kimi-code");
    if (::setenv("CODEX_HOME", codex.c_str(), 1) || ::setenv("CLAUDE_CONFIG_DIR", claude.c_str(), 1) ||
        ::setenv("PI_CODING_AGENT_DIR", pi.c_str(), 1) || ::setenv("XDG_DATA_HOME", data.c_str(), 1) ||
        ::setenv("KIMI_CODE_HOME", kimi.c_str(), 1))
        throw std::runtime_error("providerEnvironmentUnavailable");
}
std::string Catalog::scopeIdentity() const {
    std::string value = "tessera-agent-scope-1\nuid=" + std::to_string(::geteuid()) + "\n";
    for (const auto& root : roots_) {
        if (root.path.empty() || root.path.front() != '/' || root.path.size() > 2048 ||
            root.path.find('\n') != std::string::npos || root.path.find('\r') != std::string::npos) throw std::runtime_error("invalidProviderRoot");
        value += root.provider + ":" + root.path + "\n";
    }
#ifdef __linux__
    for (const auto* name : {"mnt", "pid", "user"}) {
        struct stat info{};
        const auto path = std::string("/proc/self/ns/") + name;
        if (::stat(path.c_str(), &info)) throw std::runtime_error("namespaceUnavailable");
        value += std::string(name) + ":" + std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + "\n";
    }
#endif
    return value;
}
int Catalog::open(const Source& source) const {
    if (source.path.find('\0') != std::string::npos || !simdjson::validate_utf8(source.path))
        throw std::runtime_error("sourceNotAuthorized");
    const bool allowed = std::any_of(roots_.begin(), roots_.end(), [&](const Root& root) {
        return root.provider == source.provider && source.path.compare(0, root.path.size() + 1, root.path + "/") == 0;
    });
    if (!allowed || (source.provider == "opencode" ? source.path != openCodePath() :
        source.path.size() < 6 || source.path.substr(source.path.size() - 6) != ".jsonl"))
        throw std::runtime_error("sourceNotAuthorized");
    if (source.provider == "kimi") {
        const auto identity = kimiIdentity(source.path);
        if (!source.sessionID.empty() && identity != source.sessionID) throw std::runtime_error("kimiIdentityConflict");
    }
    int descriptor = openComponents(source.path);
    struct stat info{};
    if (descriptor < 0 || ::fstat(descriptor, &info) || !S_ISREG(info.st_mode)) {
        if (descriptor >= 0) ::close(descriptor);
        throw std::runtime_error("sourceMissing");
    }
    return descriptor;
}
Source Catalog::remember(const std::string& provider, const std::string& requestedPath) {
    if (requestedPath.empty() || requestedPath.front() != '/' || requestedPath.size() > 2048 ||
        requestedPath.find('\0') != std::string::npos || !simdjson::validate_utf8(requestedPath) ||
        requestedPath.find("/../") != std::string::npos || requestedPath.find("/./") != std::string::npos)
        throw std::runtime_error("sourceNotAuthorized");
    // Resolve route/root aliases, but never grant authority through them:
    // open() rechecks the canonical target against the fixed provider roots
    // and walks its actual components with O_NOFOLLOW. Leaf symlinks remain
    // rejected, including links into an otherwise authorized directory.
    struct stat named{};
    if (::lstat(requestedPath.c_str(), &named) || !S_ISREG(named.st_mode)) throw std::runtime_error("sourceMissing");
    const auto leafAt = requestedPath.rfind('/');
    const auto leaf = requestedPath.substr(leafAt + 1);
    if (leaf.empty() || leaf == "." || leaf == "..") throw std::runtime_error("sourceNotAuthorized");
    char resolved[PATH_MAX];
    if (!::realpath(requestedPath.substr(0, leafAt).c_str(), resolved)) throw std::runtime_error("sourceMissing");
    const std::string path = std::string(resolved) + "/" + leaf;
    Source source; source.provider = provider; source.path = path;
    int descriptor = open(source);
    struct DescriptorGuard { int fd; ~DescriptorGuard() { if (fd >= 0) ::close(fd); } } guard{descriptor};
    struct stat info{};
    const auto valid = ::fstat(descriptor, &info) == 0 && info.st_dev == named.st_dev && info.st_ino == named.st_ino;
    if (!valid) throw std::runtime_error("sourceChanged");
    source.bytes = static_cast<uint64_t>(info.st_size);
    source.modified = static_cast<uint64_t>(std::max<time_t>(0, info.st_mtime));
    source.sessionID = path.substr(path.find_last_of('/') + 1);
    source.sessionID.resize(source.sessionID.size() - 6);
    if (provider == "codex" && source.sessionID.size() >= 36)
        source.sessionID = source.sessionID.substr(source.sessionID.size() - 36);
    if (provider == "kimi") source.sessionID = kimiIdentity(path);
    const auto key = provider + ":" + path;
    const auto found = handles_.find(key);
    const Source* existing = found == handles_.end() ? nullptr : &sources_.at(found->second);
    if (provider == "pi" || provider == "kimi") {
#ifdef __APPLE__
        const auto modified = info.st_mtimespec; const auto changed = info.st_ctimespec;
#else
        const auto modified = info.st_mtim; const auto changed = info.st_ctim;
#endif
        source.fileWitness = std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + ":" +
            std::to_string(info.st_size) + ":" + std::to_string(modified.tv_sec) + ":" + std::to_string(modified.tv_nsec) + ":" +
            std::to_string(changed.tv_sec) + ":" + std::to_string(changed.tv_nsec);
        if (existing && source.fileWitness == existing->fileWitness) source.sessionID = existing->sessionID;
        else {
            // Reuse the exact authorized descriptor we just stat'ed. The
            // reader also checks the named snapshot before and after decoding.
            guard.fd = -1;
            JsonlReader reader(path, provider, descriptor, cancelled,
                provider == "kimi" ? JsonlReader::Normalizer(KimiHistoryIndex::metadata) : JsonlReader::Normalizer());
            const auto header = reader.firstRecord();
            simdjson::dom::parser parser;
            if (provider == "kimi") {
                if (!header || header->value.sourceType != "metadata" || header->value.chainUnproven) throw std::runtime_error("kimiHeaderMissing");
                const auto version = json::text(parser.parse(header->value.json).value(), "version");
                if (version != "1.4" && version != "1.5") throw std::runtime_error("kimiFormatUnsupported");
            } else {
                if (!header || header->value.sourceType != "session" || header->value.providerID.empty() ||
                    header->value.providerID.size() > 256 || header->value.chainUnproven) throw std::runtime_error("piHeaderMissing");
                const auto version = json::integer(parser.parse(header->value.json).value(), "sessionVersion");
                if (version < 1 || version > 3) throw std::runtime_error("piFormatUnsupported");
                source.sessionID = header->value.providerID;
            }
            reader.validateSnapshot();
        }
        if (existing && source.sessionID != existing->sessionID) throw std::runtime_error(provider + "IdentityConflict");
    }
    if (found == handles_.end()) {
        // Reserve a fixed bound for each optional Pi stat witness, so the
        // continuation-friendly header cache remains inside catalog limits.
        const auto cost = key.size() + (provider == "pi" || provider == "kimi" ? 256 : 0);
        if (sources_.size() >= 16384 || pathBytes_ + cost > 2 * 1024 * 1024)
            throw std::runtime_error("catalogBudgetExceeded");
        source.handle = randomID(); handles_[key] = source.handle; pathBytes_ += cost;
    } else {
        source.handle = found->second;
        const auto existing = sources_.find(source.handle);
        // A file name is only a discovery hint. Refreshing file size/mtime
        // must not replace an identity previously confirmed by App Server.
        if (provider == "codex" && existing != sources_.end() &&
            handles_.count("codex-native:" + existing->second.sessionID))
            source.sessionID = existing->second.sessionID;
    }
    sources_[source.handle] = source;
    return source;
}
Source Catalog::resolve(const std::string& provider, const std::string& path) { return remember(provider, path); }
Source Catalog::identifyCodex(const std::string& sessionID, const std::string& path, uint64_t modified) {
    if (sessionID.size() != 36 || sessionID.find_first_not_of("0123456789abcdef-") != std::string::npos)
        throw std::runtime_error("invalidCodexThreadID");
    const auto key = "codex-native:" + sessionID;
    const auto found = handles_.find(key);
    Source value;
    if (!path.empty()) {
        try { value = remember("codex", path); }
        catch (const std::runtime_error& error) {
            const auto reason = std::string(error.what());
            if (reason != "sourceMissing" && reason != "sourceNotAuthorized") throw;
            // A native-store ID remains readable after its old rollout path
            // disappears. Never turn an untrusted native path into file access.
        }
    }
    if (!value.handle.empty() && value.sessionID != sessionID && handles_.count("codex-native:" + value.sessionID))
        throw std::runtime_error("codexIdentityConflict");
    const auto pathHandle = value.handle;
    if (found != handles_.end()) value.handle = found->second;
    else {
        if (sources_.size() >= 16384 || pathBytes_ + key.size() > 2 * 1024 * 1024) throw std::runtime_error("catalogBudgetExceeded");
        if (value.handle.empty()) value.handle = randomID();
        handles_[key] = value.handle; pathBytes_ += key.size();
    }
    value.provider = "codex";
    value.sessionID = sessionID; value.modified = modified;
    sources_[value.handle] = value;
    if (!pathHandle.empty() && pathHandle != value.handle) {
        auto alias = value; alias.handle = pathHandle; sources_[pathHandle] = std::move(alias);
    }
    return value;
}
Source Catalog::resolveCodex(const std::string& sessionID) const {
    const auto found = handles_.find("codex-native:" + sessionID);
    if (found == handles_.end()) throw std::runtime_error("sourceNotAuthorized");
    const auto& value = source(found->second);
    if (value.provider != "codex" || value.sessionID != sessionID) throw std::runtime_error("codexIdentityConflict");
    return value;
}
Source Catalog::resolveCodexFile(const std::string& sessionID, bool allowMissing) {
    if (sessionID.size() != 36 || sessionID.find_first_not_of("0123456789abcdef-") != std::string::npos)
        throw std::runtime_error("invalidCodexThreadID");
    // Only a genuinely missing component invalidates a cached discovery hint.
    // Symlinks, non-directories and permission failures remain fail-closed;
    // do not let a second same-ID file bypass a substituted cached path.
    const auto available = [](const Source& candidate) {
        int descriptor = openComponents(candidate.path);
        if (descriptor < 0) {
            if (errno == ENOENT) return false;
            throw std::runtime_error("sourceMissing");
        }
        struct stat info{};
        const bool regular = ::fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode);
        ::close(descriptor);
        if (!regular) throw std::runtime_error("sourceMissing");
        return true;
    };
    const auto native = handles_.find("codex-native:" + sessionID);
    if (native != handles_.end() && !source(native->second).path.empty() && available(source(native->second)))
        return source(native->second);
    Source known;
    for (const auto& entry : sources_) {
        const auto& candidate = entry.second;
        if (candidate.provider != "codex" || candidate.sessionID != sessionID || candidate.path.empty()) continue;
        if (!available(candidate)) continue;
        if (!known.path.empty() && known.path != candidate.path) throw std::runtime_error("codexIdentityConflict");
        known = candidate;
    }
    // Known paths remain hints: prepareHistory reopens under the fixed root
    // policy and revalidates header identity plus the indexed snapshot. Do not
    // enumerate every unrelated provider home on each fast lineage update.
    if (!known.path.empty()) return known;
    // Inventory walks only configured roots using the same descriptor policy
    // as normal discovery. Transcript-supplied paths never enter this lookup.
    Source found;
    for (const auto& candidate : inventory("codex")) if (candidate.sessionID == sessionID) {
        if (!found.path.empty() && found.path != candidate.path) throw std::runtime_error("codexIdentityConflict");
        found = candidate;
    }
    if (found.path.empty() && !allowMissing) throw std::runtime_error("sourceMissing");
    return found;
}
const Source& Catalog::source(const std::string& handle) const {
    const auto found = sources_.find(handle);
    if (found == sources_.end()) throw std::runtime_error("sourceHandleExpired");
    return found->second;
}
std::string Catalog::openCodePath() const {
    for (const auto& root : roots_) if (root.provider == "opencode") return root.path + "/opencode.db";
    throw std::runtime_error("sourceNotAuthorized");
}
Source Catalog::rememberOpenCode(const std::string& sessionID, uint64_t modified) {
    const auto key = "opencode-native:" + sessionID;
    auto found = handles_.find(key);
    if (found == handles_.end()) {
        if (sources_.size() >= 16384 || pathBytes_ + key.size() > 2 * 1024 * 1024) throw std::runtime_error("catalogBudgetExceeded");
        found = handles_.emplace(key, randomID()).first; pathBytes_ += key.size();
    }
    Source source; source.handle = found->second; source.provider = "opencode";
    source.sessionID = sessionID; source.path = openCodePath(); source.modified = modified;
    sources_[source.handle] = source; return source;
}
Source Catalog::resolveOpenCode(const std::string& sessionID) {
    OpenCodeStore database(openCodePath(), cancelled);
    database.identity(sessionID); // Exact database membership, never caller authority.
    return rememberOpenCode(sessionID, 0);
}
const std::map<std::string, std::string>& Catalog::kimiSessions() const {
    std::string root;
    for (const auto& entry : roots_) if (entry.provider == "kimi") root = entry.path;
    if (root.empty()) throw std::runtime_error("sourceNotAuthorized");
    const auto path = root.substr(0, root.size() - 9) + "/session_index.jsonl";
    const int descriptor = openComponents(path);
    if (descriptor < 0) {
        if (errno == ENOENT) { kimiSessions_.clear(); kimiIndexWitness_.clear(); return kimiSessions_; }
        throw std::runtime_error("kimiIndexUnavailable");
    }
    struct stat info{};
    // Owner-only file checks, never mode bits: a umask 0002 host writes the
    // index group-writable and its owner's sessions must still list.
    if (::fstat(descriptor, &info) || !S_ISREG(info.st_mode) || info.st_uid != ::geteuid() ||
        info.st_nlink != 1 || info.st_size < 0 || info.st_size > 1024 * 1024) {
        ::close(descriptor); throw std::runtime_error("kimiIndexUnavailable");
    }
#ifdef __APPLE__
    const auto modified = info.st_mtimespec; const auto changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim; const auto changed = info.st_ctim;
#endif
    const auto witness = std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + ":" + std::to_string(info.st_size) + ":" +
        std::to_string(modified.tv_sec) + ":" + std::to_string(modified.tv_nsec) + ":" +
        std::to_string(changed.tv_sec) + ":" + std::to_string(changed.tv_nsec);
    if (witness == kimiIndexWitness_) { ::close(descriptor); return kimiSessions_; }
    // The parse keeps no partial state and the index is bounded, so a read
    // slice would only restart it (see ReadWorker::inventory).
    JsonlContinuation::Suspend unsliced;
    JsonlReader reader(path, "kimi", descriptor, cancelled, [](simdjson::dom::element value, bool cut) {
        NormalizedRecord record; record.json = simdjson::minify(value); record.chainUnproven = cut; return record;
    });
    std::map<std::string, std::string> sessions; uint64_t position = 0; size_t count = 0;
    simdjson::dom::parser parser;
    for (;;) {
        auto page = reader.page(position, true);
        for (const auto& row : page.records) {
            if (++count > 4096 || row.value.chainUnproven || row.value.disposition == "malformed" || row.value.disposition == "unsupported")
                throw std::runtime_error("kimiIndexUnproven");
            const auto value = parser.parse(row.value.json).value();
            std::set<std::string_view> fields;
            for (const auto field : simdjson::dom::object(value.get_object().value())) if (!fields.insert(field.key).second) throw std::runtime_error("kimiIndexUnproven");
            if (!json::get(value, "deleted").is_null() && !json::get(value, "deleted").is_bool()) throw std::runtime_error("kimiIndexUnproven");
            const auto id = json::text(value, "sessionId");
            if (id.empty() || id.size() > 128 || id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos)
                throw std::runtime_error("kimiIndexUnproven");
            if (json::boolean(value, "deleted")) { sessions.erase(id); continue; }
            const auto directory = json::text(value, "sessionDir");
            // No arbitrary path from the index becomes authority. It must
            // satisfy the fixed sessions/<workdir>/<session-id> grammar.
            if (directory.rfind(root + "/", 0) != 0 || directory.size() > 2048) throw std::runtime_error("kimiIndexUnproven");
            const auto relative = directory.substr(root.size() + 1); const auto slash = relative.find('/');
            if (slash == std::string::npos || slash == 0 || relative.substr(0, slash) == "." || relative.substr(0, slash) == ".." ||
                relative.substr(slash + 1) != id) throw std::runtime_error("kimiIndexUnproven");
            sessions[id] = directory;
        }
        if (!page.hasNewer) break;
        if (page.live <= position) throw std::runtime_error("kimiIndexUnproven");
        position = page.live;
    }
    reader.validateSnapshot(); kimiSessions_ = std::move(sessions); kimiIndexWitness_ = witness; return kimiSessions_;
}
std::string Catalog::kimiIdentity(const std::string& path) const {
    const auto marker = path.rfind("/agents/");
    if (marker == std::string::npos || path.size() < marker + 19 || path.substr(path.size() - 11) != "/wire.jsonl")
        throw std::runtime_error("sourceNotAuthorized");
    const auto directory = path.substr(0, marker);
    const auto id = directory.substr(directory.rfind('/') + 1);
    const auto agent = path.substr(marker + 8, path.size() - marker - 19);
    if (agent.empty() || agent.size() > 96 || agent.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos || agent == "." || agent == "..")
        throw std::runtime_error("sourceNotAuthorized");
    const auto& sessions = kimiSessions(); const auto found = sessions.find(id);
    if (found == sessions.end() || found->second != directory) throw std::runtime_error("sourceNotAuthorized");
    // Separate child transcripts rather than accidentally merging their
    // identical session IDs into a single inventory row.
    return agent == "main" ? id : id + "@" + agent;
}
std::vector<Source> Catalog::inventory(const std::string& provider) {
    std::vector<Source> result;
    size_t visited = 0;
    for (const auto& root : roots_) {
        if (!provider.empty() && root.provider != provider) continue;
        if (root.provider == "opencode") {
            try {
                OpenCodeStore database(openCodePath(), cancelled);
                for (const auto& row : database.inventory()) result.push_back(rememberOpenCode(row.id, row.modified));
            } catch (const std::runtime_error& error) {
                if (std::string(error.what()) != "sourceMissing") throw;
            }
            continue;
        }
        std::map<std::string, std::string> kimi;
        if (root.provider == "kimi") kimi = kimiSessions();
        std::vector<std::pair<std::string, size_t>> pending{{root.path, 0}};
        while (!pending.empty()) {
            if (cancelled && cancelled()) throw std::runtime_error("cancelled");
            auto [path, depth] = std::move(pending.back()); pending.pop_back();
            if (++visited > 32768 || depth > 32) throw std::runtime_error("catalogBudgetExceeded");
            const int descriptor = openComponents(path, true);
            if (descriptor < 0) {
                if (!depth && errno == ENOENT) continue;
                throw std::runtime_error("catalogSourceUnavailable");
            }
            DIR* directory = ::fdopendir(descriptor);
            if (!directory) { ::close(descriptor); throw std::runtime_error("catalogSourceUnavailable"); }
            std::unique_ptr<DIR, int(*)(DIR*)> owned(directory, ::closedir);
            while (auto entry = ::readdir(directory)) {
                if (cancelled && cancelled()) throw std::runtime_error("cancelled");
                const std::string name = entry->d_name;
                if (name == "." || name == "..") continue;
                if (++visited > 32768) throw std::runtime_error("catalogBudgetExceeded");
                struct stat info{};
                if (::fstatat(descriptor, name.c_str(), &info, AT_SYMLINK_NOFOLLOW))
                    throw std::runtime_error("catalogSourceChanged");
                const auto child = path + "/" + name;
                if (S_ISLNK(info.st_mode)) continue; // Never follow private-root escape links.
                if (S_ISDIR(info.st_mode)) {
                    if (pending.size() >= 1024) throw std::runtime_error("catalogBudgetExceeded");
                    pending.push_back({child, depth + 1});
                } else if (S_ISREG(info.st_mode) && name.size() > 6 && name.substr(name.size() - 6) == ".jsonl" &&
                           (root.provider != "claude" || claudeTranscriptLayout(child.substr(root.path.size() + 1)))) {
                    if (root.provider == "kimi") {
                        if (name != "wire.jsonl") continue;
                        const auto marker = child.rfind("/agents/");
                        if (marker == std::string::npos) continue;
                        const auto directory = child.substr(0, marker); const auto id = directory.substr(directory.rfind('/') + 1);
                        const auto found = kimi.find(id);
                        if (found == kimi.end() || found->second != directory) continue;
                    }
                    result.push_back(remember(root.provider, child));
                }
            }
        }
    }
    std::sort(result.begin(), result.end(), [](const Source& a, const Source& b) {
        return a.modified == b.modified ? a.handle < b.handle : a.modified > b.modified;
    });
    return result;
}
}
