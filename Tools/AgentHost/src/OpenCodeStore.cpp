#include "OpenCodeStore.h"
#include "BoundedJson.h"
#include "Json.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <thread>
#include <fcntl.h>
#include <set>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace tessera {
namespace {
thread_local OpenCodeStore* active = nullptr;
int denyPathMutation(const char*) { errno = EACCES; return -1; }
int denyDirectoryCreation(const char*, mode_t) { errno = EACCES; return -1; }
int denyModeChange(int, mode_t) { errno = EACCES; return -1; }
int denyOwnerChange(int, uid_t, gid_t) { errno = EACCES; return -1; }
struct Statement { sqlite3_stmt* value; ~Statement() { sqlite3_finalize(value); } };
bool identifier(const std::string& value) {
    return !value.empty() && value.size() <= 128 &&
        value.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") == std::string::npos;
}
std::string column(sqlite3_stmt* value, int index, size_t limit = 256) {
    if (sqlite3_column_type(value, index) != SQLITE_TEXT || sqlite3_column_bytes(value, index) < 0 ||
        static_cast<size_t>(sqlite3_column_bytes(value, index)) > limit) throw std::runtime_error("opencodeInvalidSchema");
    auto text = reinterpret_cast<const char*>(sqlite3_column_text(value, index));
    if (!text) throw std::runtime_error("opencodeResourceLimit");
    std::string result(text, static_cast<size_t>(sqlite3_column_bytes(value, index)));
    if (result.find('\0') != std::string::npos || !simdjson::validate_utf8(result)) throw std::runtime_error("opencodeInvalidSchema");
    return result;
}
void bind(sqlite3_stmt* statement, int position, const std::string& value) {
    if (sqlite3_bind_text(statement, position, value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT) != SQLITE_OK)
        throw std::runtime_error("opencodeResourceLimit");
}
int secureFile(const std::string& path, int flags, int mode) {
    if (path.empty() || path.front() != '/' || path.size() > 2048 || path.find('\0') != std::string::npos) { errno = EACCES; return -1; }
    int current = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (size_t position = 1; current >= 0;) {
        const auto end = path.find('/', position);
        const auto part = path.substr(position, end == std::string::npos ? end : end - position);
        if (part.empty() || part == "." || part == "..") { ::close(current); errno = EACCES; return -1; }
        const auto next = ::openat(current, part.c_str(), end == std::string::npos ?
            (flags & ~O_CREAT) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, mode);
        const auto error = errno; ::close(current); current = next; errno = error;
        if (end == std::string::npos) break;
        position = end + 1;
    }
    // The owner decides the mode of their own provider store: Ubuntu-style
    // hosts create every file group-writable under umask 0002, and refusing
    // such a store silently dropped Codex thread names. Ownership, a regular
    // file, a single link and the O_NOFOLLOW walk still keep another user
    // from substituting a file.
    struct stat info{};
    if (current >= 0 && (::fstat(current, &info) || !S_ISREG(info.st_mode) || info.st_uid != ::geteuid() ||
                         info.st_nlink != 1)) {
        ::close(current); errno = EACCES; return -1;
    }
    return current;
}
int64_t modifiedNanoseconds(const struct stat& info) {
#ifdef __APPLE__
    return int64_t(info.st_mtimespec.tv_sec) * 1000000000 + info.st_mtimespec.tv_nsec;
#else
    return int64_t(info.st_mtim.tv_sec) * 1000000000 + info.st_mtim.tv_nsec;
#endif
}
int64_t recentlyWrittenThresholdMs(const struct stat& info) {
#ifdef __APPLE__
    const bool coarse = info.st_mtimespec.tv_nsec == 0;
#else
    const bool coarse = info.st_mtim.tv_nsec == 0;
#endif
    return coarse ? 2000 : 100;
}
bool recentlyWritten(const struct stat& info) {
    const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    return now - modifiedNanoseconds(info) < recentlyWrittenThresholdMs(info) * 1000000;
}
// SQLite decodes %HH in a file: URI path; '?' and '#' would end it early.
std::string uriPath(const std::string& path) {
    static const char digits[] = "0123456789ABCDEF";
    std::string encoded;
    for (const unsigned char byte : path) {
        if (std::isalnum(byte) || byte == '/' || byte == '-' || byte == '_' || byte == '.' || byte == '~') encoded += char(byte);
        else { encoded += '%'; encoded += digits[byte >> 4]; encoded += digits[byte & 15]; }
    }
    return encoded;
}
}

bool OpenCodeStore::intact() {
    if (!immutable_) return true;
    // A writer that reopened the store owns its -wal again; a checkpoint it
    // ran could have rewritten pages under this snapshot.
    const int wal = secureFile(path_ + "-wal", O_RDONLY, 0);
    const bool walAbsent = wal < 0 && errno == ENOENT;
    if (wal >= 0) ::close(wal);
    if (!walAbsent) return false;
    const int descriptor = secureFile(path_, O_RDONLY, 0);
    struct stat info{};
    const bool same = descriptor >= 0 && !::fstat(descriptor, &info) &&
        std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) == identity_ &&
        info.st_size == snapshotSize_ && modifiedNanoseconds(info) == snapshotModified_;
    if (descriptor >= 0) ::close(descriptor);
    return same;
}
void OpenCodeStore::settled() { if (!intact()) throw std::runtime_error("sourceChanged"); }

int OpenCodeStore::wakeupDescriptor(const std::string& path) {
    int descriptor = secureFile(path + "-wal", O_RDONLY, 0);
    if (descriptor < 0 && errno == ENOENT) descriptor = secureFile(path, O_RDONLY, 0);
    if (descriptor < 0) throw std::runtime_error("sourceNotAuthorized");
    return descriptor;
}

int OpenCodeStore::secureOpen(const char* filename, int flags, int mode) {
    if (!active || !filename) { errno = EACCES; return -1; }
    const std::string path(filename);
    const bool sharedMemory = path == active->path_ + "-shm";
    if (path != active->path_ && path != active->path_ + "-wal" && path != active->path_ + "-journal" && !sharedMemory) {
        errno = EACCES; return -1;
    }
    // Read-only SQLite may coordinate through an EXISTING same-UID shm file.
    // Never create a sidecar or permit data/journal writes or truncation.
    if ((!sharedMemory && (flags & O_ACCMODE) != O_RDONLY) || (flags & O_TRUNC)) { errno = EACCES; return -1; }
    const int descriptor = secureFile(path, flags, mode);
    if (descriptor >= 0 && path == active->path_) {
        struct stat info{};
        if (::fstat(descriptor, &info) || std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) != active->identity_) {
            ::close(descriptor); errno = EACCES; return -1;
        }
    }
    return descriptor;
}

OpenCodeStore::OpenCodeStore(std::string path, std::function<bool()> cancelled)
    : OpenCodeStore(std::move(path), std::move(cancelled), false) {}

OpenCodeStore::OpenCodeStore(std::string path, std::function<bool()> cancelled, bool metadataOnly)
    : path_(std::move(path)), cancelled_(std::move(cancelled)), deadline_(std::chrono::steady_clock::now() + std::chrono::milliseconds(1500)) {
    if (active) throw std::runtime_error("opencodeNestedRead");
    // A WAL-mode store whose writer has closed has no -wal or -shm sidecars.
    // Read-only SQLite cannot open it unless it may create them, and this
    // helper never creates files in a provider's home; on a real host that
    // dropped every Codex thread name whenever Codex had closed its store.
    // The main file is complete once the writer has checkpointed and left,
    // so read it as an immutable snapshot. Only a WAL-header database takes
    // this path: a rollback-journal store keeps SQLite's own locking and
    // hot-journal recovery, which the unlocked snapshot path would skip.
    // Sidecar first, then the main file, so a closing checkpoint between the
    // two does not read as a changed main file.
    const int wal = secureFile(path_ + "-wal", O_RDONLY, 0);
    const bool walAbsent = wal < 0 && errno == ENOENT;
    if (wal >= 0) ::close(wal);
    struct stat info{};
    for (int attempt = 0;; ++attempt) {
        const int descriptor = secureFile(path_, O_RDONLY, 0);
        if (descriptor < 0) throw std::runtime_error(errno == ENOENT ? "sourceMissing" : "sourceNotAuthorized");
        const bool valid = !::fstat(descriptor, &info);
        std::array<unsigned char, 100> header{};
        const bool walHeader = valid && ::pread(descriptor, header.data(), header.size(), 0) == static_cast<ssize_t>(header.size()) &&
            header[18] == 2 && header[19] == 2;
        ::close(descriptor);
        if (!valid) throw std::runtime_error("sourceChanged");
        immutable_ = walAbsent && walHeader;
        // Racy-snapshot rule: a torn snapshot is caught by the main file's
        // mtime, so the snapshot must be old enough that any later rewrite
        // lands on a later timestamp even on a coarse clock (Linux kernels
        // before 6.13 stamp at 1-10 ms; a filesystem without sub-second
        // timestamps shows a zero nanosecond field and needs seconds).
        if (!immutable_ || !recentlyWritten(info)) break;
        const auto limit = std::chrono::steady_clock::now() + std::chrono::milliseconds(recentlyWrittenThresholdMs(info));
        while (recentlyWritten(info) && std::chrono::steady_clock::now() < limit) {
            if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        struct stat again{};
        const int recheck = secureFile(path_, O_RDONLY, 0);
        const bool same = recheck >= 0 && !::fstat(recheck, &again) && again.st_dev == info.st_dev && again.st_ino == info.st_ino &&
            again.st_size == info.st_size && modifiedNanoseconds(again) == modifiedNanoseconds(info);
        if (recheck >= 0) ::close(recheck);
        if (same) break;
        if (attempt == 2) throw std::runtime_error("sourceChanged");
    }
    identity_ = std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino);
    snapshotSize_ = info.st_size; snapshotModified_ = modifiedNanoseconds(info);
    deadline_ = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    previous_ = active; active = this;
    try {
        // A pinned private SQLite build is used by this helper only. The Unix
        // VFS open shim also protects WAL/shm and ancestor components against
        // symlink substitution; SQLITE_OPEN_NOFOLLOW alone covers too little.
        sqlite3_initialize();
        auto* vfs = sqlite3_vfs_find("unix");
        if (!vfs || vfs->iVersion < 3 || !vfs->xSetSystemCall ||
            vfs->xSetSystemCall(vfs, "open", reinterpret_cast<sqlite3_syscall_ptr>(secureOpen)) != SQLITE_OK)
            throw std::runtime_error("opencodeSecureVFSUnavailable");
        // SQLite may attempt WAL cleanup even after SQLITE_OPEN_READONLY.
        // Prevent deletion and metadata mutation on every error/close path.
        for (const auto& entry : std::initializer_list<std::pair<const char*, sqlite3_syscall_ptr>>{
            {"unlink", reinterpret_cast<sqlite3_syscall_ptr>(denyPathMutation)},
            {"rmdir", reinterpret_cast<sqlite3_syscall_ptr>(denyPathMutation)},
            {"mkdir", reinterpret_cast<sqlite3_syscall_ptr>(denyDirectoryCreation)},
            {"fchmod", reinterpret_cast<sqlite3_syscall_ptr>(denyModeChange)},
            {"fchown", reinterpret_cast<sqlite3_syscall_ptr>(denyOwnerChange)}})
            if (vfs->xSetSystemCall(vfs, entry.first, entry.second) != SQLITE_OK)
                throw std::runtime_error("opencodeSecureVFSUnavailable");
        sqlite3_hard_heap_limit64(16 * 1024 * 1024);
        const std::string location = immutable_ ? "file:" + uriPath(path_) + "?immutable=1" : path_;
        const int code = sqlite3_open_v2(location.c_str(), &database_, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX |
            SQLITE_OPEN_NOFOLLOW | (immutable_ ? SQLITE_OPEN_URI : 0), "unix");
        if (code != SQLITE_OK) throw std::runtime_error("opencodeDatabaseUnavailable");
        sqlite3_busy_timeout(database_, 100);
        sqlite3_limit(database_, SQLITE_LIMIT_SQL_LENGTH, 8192);
        sqlite3_limit(database_, SQLITE_LIMIT_COLUMN, 64);
        sqlite3_limit(database_, SQLITE_LIMIT_ATTACHED, 0);
        sqlite3_limit(database_, SQLITE_LIMIT_EXPR_DEPTH, 32);
        sqlite3_db_config(database_, SQLITE_DBCONFIG_DEFENSIVE, 1, nullptr);
        sqlite3_db_config(database_, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, nullptr);
        sqlite3_progress_handler(database_, 1000, progress, this);
        exec("PRAGMA query_only=ON; PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY; BEGIN");
        if (!metadataOnly) validateSchema();
        const int reopened = secureFile(path_, O_RDONLY, 0);
        struct stat current{};
        const bool same = reopened >= 0 && !::fstat(reopened, &current) && current.st_dev == info.st_dev && current.st_ino == info.st_ino;
        if (reopened >= 0) ::close(reopened);
        if (!same) throw std::runtime_error("sourceChanged");
    } catch (...) {
        const bool torn = immutable_ && !intact();
        if (database_) sqlite3_close(database_);
        database_ = nullptr; active = previous_;
        if (torn) throw std::runtime_error("sourceChanged");
        throw;
    }
}
OpenCodeStore::~OpenCodeStore() { if (database_) sqlite3_close(database_); active = previous_; }

OpenCodeStore::CodexFields OpenCodeStore::codexFields(const std::string& path, const std::string& session,
                                                     std::function<bool()> cancelled, bool includePrompt) {
    if (!identifier(session)) throw std::runtime_error("codexInvalidSessionID");
    // A snapshot read loses to a provider that reopened its store meanwhile;
    // the one retry then follows the new WAL instead.
    for (int attempt = 0;; ++attempt) {
        try { return codexFieldsOnce(path, session, cancelled, includePrompt); }
        catch (const std::runtime_error& error) {
            if (attempt > 0 || std::string(error.what()) != "sourceChanged") throw;
        }
    }
}
OpenCodeStore::CodexFields OpenCodeStore::codexFieldsOnce(const std::string& path, const std::string& session,
                                                         std::function<bool()> cancelled, bool includePrompt) {
    OpenCodeStore store(path, std::move(cancelled), true);
    return store.guarded([&]() -> CodexFields {
    Statement kind{store.prepare("SELECT type FROM sqlite_schema WHERE name='threads'")};
    if (store.step(kind.value) != SQLITE_ROW || column(kind.value, 0) != "table")
        throw std::runtime_error("codexMetadataSchemaUnsupported");
    bool name = false, title = false, firstUserMessage = false, keyed = false;
    Statement columns{store.prepare("PRAGMA table_info(threads)")};
    while (store.step(columns.value) == SQLITE_ROW) {
        const auto field = column(columns.value, 1);
        name |= field == "name"; title |= field == "title"; firstUserMessage |= field == "first_user_message";
        keyed |= field == "id" && sqlite3_column_int(columns.value, 5) == 1;
    }
    if (!keyed || (!name && !title)) throw std::runtime_error("codexMetadataSchemaUnsupported");
    CodexFields fields;
    if (!includePrompt) {
        // A provider-generated name wins, read on its own: SQLite materializes
        // a whole column value, so a multi-megabyte title must not cost it.
        // The old title column is the first user prompt: only use a short
        // value, never a long pasted log as a card title.
        if (name) {
            Statement row{store.prepare("SELECT substr(name,1,512) FROM threads WHERE id=? LIMIT 1")};
            bind(row.value, 1, session);
            if (store.step(row.value) != SQLITE_ROW) return fields;
            if (sqlite3_column_type(row.value, 0) != SQLITE_NULL) fields.name = column(row.value, 0, 2048);
            if (fields.name.find_first_not_of(" \t\r\n") != std::string::npos || !title) return fields;
        }
        Statement row{store.prepare("SELECT CASE WHEN length(title)<=200 THEN title ELSE NULL END FROM threads WHERE id=? LIMIT 1")};
        bind(row.value, 1, session);
        if (store.step(row.value) != SQLITE_ROW) return fields;
        if (sqlite3_column_type(row.value, 0) != SQLITE_NULL) fields.shortTitle = column(row.value, 0, 2048);
        return fields;
    }
    // Page metadata reads the name on its own. SQLite materializes a whole
    // column value, so a pasted multi-megabyte opening prompt can exceed the
    // helper's heap limit; that must cost only the prompt, never the name.
    Statement row{store.prepare(std::string("SELECT ") + (name ? "substr(name,1,512)" : "NULL") +
        " FROM threads WHERE id=? LIMIT 1")};
    bind(row.value, 1, session);
    if (store.step(row.value) != SQLITE_ROW) return fields;
    if (sqlite3_column_type(row.value, 0) != SQLITE_NULL) fields.metadataName = column(row.value, 0, 2048);
    const auto prompt = [&](const char* field) {
        try {
            // Clip before any other text function copies the value.
            Statement text{store.prepare(std::string("SELECT substr(") + field + ",1,4096) FROM threads WHERE id=? LIMIT 1")};
            bind(text.value, 1, session);
            if (store.step(text.value) != SQLITE_ROW || sqlite3_column_type(text.value, 0) == SQLITE_NULL) return std::string();
            return column(text.value, 0, 16384);
        } catch (const std::runtime_error& error) {
            if (std::string(error.what()) == "cancelled") throw;
            if (fields.promptReason.empty()) fields.promptReason = error.what();
            return std::string();
        }
    };
    if (firstUserMessage) fields.firstUserMessage = prompt("first_user_message");
    if (title && fields.firstUserMessage.find_first_not_of(" \t\r\n\f\v") == std::string::npos) fields.title = prompt("title");
    return fields;
    });
}
namespace {
std::string trimCodexText(const std::string& value) {
    const auto first = value.find_first_not_of(" \t\r\n\f\v");
    return first == std::string::npos ? std::string() :
        value.substr(first, value.find_last_not_of(" \t\r\n\f\v") - first + 1);
}
std::string clipUtf8(std::string value, size_t limit) {
    if (value.size() <= limit) return value;
    size_t end = limit;
    while (end && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) --end;
    value.resize(end);
    return value;
}
}
std::string OpenCodeStore::codexTitle(const std::string& path, const std::string& session,
                                     std::function<bool()> cancelled) {
    const auto fields = codexFields(path, session, std::move(cancelled), false);
    const auto trimLegacy = [](const std::string& value) {
        const auto first = value.find_first_not_of(" \t\r\n");
        return first == std::string::npos ? std::string() :
            value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
    };
    auto name = trimLegacy(fields.name);
    return name.empty() ? trimLegacy(fields.shortTitle) : name;
}
OpenCodeStore::CodexMetadata OpenCodeStore::codexMetadata(const std::string& path, const std::string& session,
                                                         std::function<bool()> cancelled) {
    const auto fields = codexFields(path, session, std::move(cancelled), true);
    CodexMetadata metadata;
    metadata.name = clipUtf8(trimCodexText(fields.metadataName), 512);
    metadata.openingPrompt = clipUtf8(trimCodexText(fields.firstUserMessage), 4096);
    if (metadata.openingPrompt.empty()) metadata.openingPrompt = clipUtf8(trimCodexText(fields.title), 4096);
    if (metadata.openingPrompt.empty()) metadata.promptReason = fields.promptReason;
    return metadata;
}
void OpenCodeStore::check() {
    if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
    if (steps_ > 1000000 || bytesRead_ > 64 * 1024 * 1024 || std::chrono::steady_clock::now() >= deadline_)
        throw std::runtime_error("opencodeReadBudgetExceeded");
}
int OpenCodeStore::progress(void* pointer) {
    auto& self = *static_cast<OpenCodeStore*>(pointer); self.steps_ += 1000;
    try { self.check(); return 0; } catch (...) { return 1; }
}
void OpenCodeStore::exec(const char* sql) {
    check(); if (sqlite3_exec(database_, sql, nullptr, nullptr, nullptr) != SQLITE_OK) {
        check(); throw std::runtime_error("opencodeDatabaseUnavailable");
    }
}
sqlite3_stmt* OpenCodeStore::prepare(const std::string& sql) {
    check(); sqlite3_stmt* value = nullptr;
    if (sqlite3_prepare_v2(database_, sql.c_str(), -1, &value, nullptr) != SQLITE_OK) {
        if (value) sqlite3_finalize(value);
        check(); throw std::runtime_error("opencodeInvalidSchema");
    }
    return value;
}
int OpenCodeStore::step(sqlite3_stmt* statement) {
    check(); const int code = sqlite3_step(statement);
    if (code != SQLITE_ROW && code != SQLITE_DONE) { check(); throw std::runtime_error("opencodeDatabaseUnavailable"); }
    return code;
}
void OpenCodeStore::validateSchema() {
    for (const auto* table : {"session", "message", "part", "session_message"}) {
        Statement kind{prepare("SELECT type FROM sqlite_schema WHERE name=?")}; bind(kind.value, 1, table);
        if (step(kind.value) == SQLITE_DONE) {
            if (std::string(table) == "session_message") continue;
            throw std::runtime_error("opencodeInvalidSchema");
        }
        if (column(kind.value, 0) != "table") throw std::runtime_error("opencodeInvalidSchema");
        std::set<std::string> required = std::string(table) == "session" ?
            std::set<std::string>{"id", "title", "time_updated", "time_archived"} :
            std::set<std::string>{"id", "session_id", "time_created", "time_updated", "data"};
        if (std::string(table) == "part") required.insert("message_id");
        if (std::string(table) == "session_message") { required.insert("seq"); required.insert("type"); modernTable_ = true; }
        Statement columns{prepare("PRAGMA table_info(" + std::string(table) + ")")};
        while (step(columns.value) == SQLITE_ROW) {
            const auto name = column(columns.value, 1); auto folded = name;
            for (auto& character : folded) if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
            // Incremental blob handles take the HIDDEN rowid, not a declared
            // shadow column. No provider row may redirect another row's blob.
            if (folded == "rowid" || folded == "_rowid_" || folded == "oid") throw std::runtime_error("opencodeInvalidSchema");
            required.erase(name);
        }
        if (!required.empty()) throw std::runtime_error("opencodeInvalidSchema");
    }
}
std::vector<OpenCodeStore::Session> OpenCodeStore::inventory() { return guarded([&] { return inventoryUnguarded(); }); }
std::vector<OpenCodeStore::Session> OpenCodeStore::inventoryUnguarded() {
    Statement rows{prepare("SELECT id,time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC,id DESC LIMIT 16385")};
    std::vector<Session> result;
    while (step(rows.value) == SQLITE_ROW) {
        auto id = column(rows.value, 0); const auto updated = sqlite3_column_int64(rows.value, 1);
        if (!identifier(id) || updated < 0 || sqlite3_column_type(rows.value, 1) != SQLITE_INTEGER) throw std::runtime_error("opencodeInvalidSchema");
        if (result.size() == 16384) throw std::runtime_error("catalogBudgetExceeded");
        result.push_back({std::move(id), static_cast<uint64_t>(updated / 1000), ""});
    }
    return result;
}
OpenCodeStore::Session OpenCodeStore::metadata(const std::string& session) { return guarded([&] { return metadataUnguarded(session); }); }
OpenCodeStore::Session OpenCodeStore::metadataUnguarded(const std::string& session) {
    if (!identifier(session)) throw std::runtime_error("sourceNotAuthorized");
    // Bound text in SQL before SQLite materializes the result value.
    Statement row{prepare("SELECT substr(title,1,512),time_updated FROM session WHERE id=?")}; bind(row.value, 1, session);
    if (step(row.value) != SQLITE_ROW) throw std::runtime_error("sourceMissing");
    const auto modified = sqlite3_column_int64(row.value, 1);
    if (modified < 0 || sqlite3_column_type(row.value, 1) != SQLITE_INTEGER) throw std::runtime_error("opencodeInvalidSchema");
    return {session, static_cast<uint64_t>(modified / 1000), column(row.value, 0, 2048)};
}
bool OpenCodeStore::modern(const std::string& session) {
    if (!identifier(session)) throw std::runtime_error("sourceNotAuthorized");
    Statement exists{prepare("SELECT id FROM session WHERE id=?")}; bind(exists.value, 1, session);
    if (step(exists.value) != SQLITE_ROW) throw std::runtime_error("sourceMissing");
    if (!modernTable_) return false;
    Statement rows{prepare("SELECT 1 FROM session_message WHERE session_id=? LIMIT 1")}; bind(rows.value, 1, session);
    return step(rows.value) == SQLITE_ROW;
}
std::string OpenCodeStore::identity(const std::string& session) {
    return guarded([&] { return "opencode-sqlite:" + identity_ + ":" + session + (modern(session) ? ":messages" : ":parts"); });
}
std::string OpenCodeStore::blob(const char* table, int64_t row, bool& clipped) {
    sqlite3_blob* value = nullptr;
    if (sqlite3_blob_open(database_, "main", table, "data", row, 0, &value) != SQLITE_OK)
        throw std::runtime_error("opencodeInvalidRecord");
    struct Guard { sqlite3_blob* value; ~Guard() { sqlite3_blob_close(value); } } guard{value};
    const auto size = sqlite3_blob_bytes(value); BoundedJson decoder; std::array<char, 65536> chunk{};
    for (int offset = 0; offset < size;) {
        check(); const auto count = std::min<int>(chunk.size(), size - offset);
        if (sqlite3_blob_read(value, chunk.data(), count, offset) != SQLITE_OK) throw std::runtime_error("sourceChanged");
        bytesRead_ += static_cast<uint64_t>(count); decoder.feed({chunk.data(), static_cast<size_t>(count)}); offset += count;
    }
    if (decoder.malformed() || decoder.unsupported()) throw std::runtime_error("opencodeInvalidRecord");
    clipped |= decoder.truncated(); return decoder.json();
}
std::vector<OpenCodeStore::Row> OpenCodeStore::page(const std::string& session, const Key* boundary, bool forward, size_t limit) {
    return guarded([&] { return read(session, boundary, forward, limit, false); });
}
std::vector<OpenCodeStore::Row> OpenCodeStore::legacy(const std::string& session, const Key* boundary,
        bool forward, size_t limit, bool exact) {
    // Match OpenCode's real indexes: message(session_id,time_created,id),
    // then part(message_id,id). Never sort a session-wide collection of parts.
    if (boundary && !identifier(boundary->message)) throw std::runtime_error("invalidCursor");
    std::vector<Row> result;
    auto message = [&](int64_t rowid, int64_t created, const std::string& id, bool anchored) {
        bool clipped = false;
        const auto data = blob("message", rowid, clipped);
        auto emit = [&](const std::string& partID, int64_t partRow, bool header) {
            if (result.size() >= limit) return;
            bool shortened = clipped;
            json::Object source; source.string("type", header ? "native-header" : "native-part");
            source.string("id", partID); source.string("sessionID", session); source.raw("message", data);
            if (!header) source.raw("part", blob("part", partRow, shortened));
            simdjson::dom::parser parser;
            result.push_back({{created, partID, id}, normalize("opencode", parser.parse(source.finish()).value(), shortened)});
        };
        const bool headerBoundary = anchored && boundary->id == id;
        if (exact && headerBoundary) { emit(id, 0, true); return; }
        if (forward && !anchored) emit(id, 0, true);
        if (!(anchored && headerBoundary && !forward)) {
            std::string sql = "SELECT id,rowid FROM part WHERE message_id=? AND session_id=?";
            if (anchored && !headerBoundary) sql += exact ? " AND id=?" : forward ? " AND id>?" : " AND id<?";
            sql += forward ? " ORDER BY id ASC LIMIT ?" : " ORDER BY id DESC LIMIT ?";
            Statement parts{prepare(sql)}; bind(parts.value, 1, id); bind(parts.value, 2, session);
            int parameter = 3;
            if (anchored && !headerBoundary) bind(parts.value, parameter++, boundary->id);
            sqlite3_bind_int(parts.value, parameter, static_cast<int>(limit - result.size()));
            while (result.size() < limit && step(parts.value) == SQLITE_ROW) {
                const auto partID = column(parts.value, 0);
                if (!identifier(partID) || partID == id) throw std::runtime_error("opencodeInvalidRecord");
                emit(partID, sqlite3_column_int64(parts.value, 1), false);
            }
        }
        if (!forward && !exact && (!anchored || !headerBoundary)) emit(id, 0, true);
    };
    if (boundary) {
        Statement current{prepare("SELECT rowid,time_created FROM message WHERE session_id=? AND id=? AND time_created=?")};
        bind(current.value, 1, session); bind(current.value, 2, boundary->message); sqlite3_bind_int64(current.value, 3, boundary->created);
        if (step(current.value) != SQLITE_ROW) throw std::runtime_error("sourceChanged");
        message(sqlite3_column_int64(current.value, 0), boundary->created, boundary->message, true);
        if (exact || result.size() == limit) return result;
    }
    std::string sql = "SELECT rowid,time_created,id FROM message WHERE session_id=?";
    if (boundary) sql += forward ? " AND (time_created,id)>(?,?)" : " AND (time_created,id)<(?,?)";
    sql += forward ? " ORDER BY time_created ASC,id ASC LIMIT ?" : " ORDER BY time_created DESC,id DESC LIMIT ?";
    Statement messages{prepare(sql)}; bind(messages.value, 1, session); int parameter = 2;
    if (boundary) { sqlite3_bind_int64(messages.value, parameter++, boundary->created); bind(messages.value, parameter++, boundary->message); }
    sqlite3_bind_int(messages.value, parameter, static_cast<int>(limit));
    while (result.size() < limit && step(messages.value) == SQLITE_ROW) {
        const auto id = column(messages.value, 2); const auto created = sqlite3_column_int64(messages.value, 1);
        if (!identifier(id) || created < 0 || sqlite3_column_type(messages.value, 1) != SQLITE_INTEGER) throw std::runtime_error("opencodeInvalidRecord");
        message(sqlite3_column_int64(messages.value, 0), created, id, false);
    }
    return result;
}
std::vector<OpenCodeStore::Row> OpenCodeStore::read(const std::string& session, const Key* boundary, bool forward, size_t limit, bool exact) {
    if (!limit || limit > 101 || (boundary && !identifier(boundary->id))) throw std::runtime_error("invalidRequest");
    const bool current = modern(session);
    if (!current) return legacy(session, boundary, forward, limit, exact);
    const std::string ordering = current ? "p.seq" : "p.time_created";
    const auto comparison = forward ? ">" : "<";
    std::string sql = "SELECT p.id," + ordering + ",p.rowid," + (current ? "p.type" : "m.rowid") +
        " FROM " + (current ? "session_message p" : "part p JOIN message m ON m.id=p.message_id AND m.session_id=p.session_id") + " WHERE p.session_id=?";
    if (boundary) sql += exact ? " AND " + ordering + "=? AND p.id=?" :
        " AND (" + ordering + comparison + "? OR (" + ordering + "=? AND p.id" + comparison + "?))";
    sql += " ORDER BY " + ordering + (forward ? " ASC,p.id ASC" : " DESC,p.id DESC") + " LIMIT ?";
    Statement rows{prepare(sql)}; bind(rows.value, 1, session); int parameter = 2;
    if (boundary) {
        sqlite3_bind_int64(rows.value, parameter++, boundary->created);
        if (!exact) sqlite3_bind_int64(rows.value, parameter++, boundary->created);
        bind(rows.value, parameter++, boundary->id);
    }
    sqlite3_bind_int(rows.value, parameter, static_cast<int>(limit));
    std::vector<Row> result;
    while (step(rows.value) == SQLITE_ROW) {
        Row row; row.key = {sqlite3_column_int64(rows.value, 1), column(rows.value, 0), ""};
        if (!identifier(row.key.id) || row.key.created < 0 || sqlite3_column_type(rows.value, 1) != SQLITE_INTEGER)
            throw std::runtime_error("opencodeInvalidRecord");
        bool clipped = false;
        const auto data = blob(current ? "session_message" : "part", sqlite3_column_int64(rows.value, 2), clipped);
        json::Object source; source.string("type", current ? "native-message" : "native-part"); source.string("id", row.key.id);
        source.string("sessionID", session);
        if (current) { source.string("messageType", column(rows.value, 3)); source.raw("message", data); }
        else { source.raw("part", data); source.raw("message", blob("message", sqlite3_column_int64(rows.value, 3), clipped)); }
        simdjson::dom::parser parser; row.value = normalize("opencode", parser.parse(source.finish()).value(), clipped);
        result.push_back(std::move(row));
    }
    return result;
}
OpenCodeStore::Row OpenCodeStore::exact(const std::string& session, const Key& key) {
    return guarded([&] {
        auto values = read(session, &key, true, 1, true);
        if (values.empty() || values.front().key.id != key.id) throw std::runtime_error("sourceChanged");
        return std::move(values.front());
    });
}
std::string OpenCodeStore::predecessor(const std::string& session, const Key& key) {
    return guarded([&] { return predecessorUnguarded(session, key); });
}
std::string OpenCodeStore::predecessorUnguarded(const std::string& session, const Key& key) {
    if (!identifier(key.id)) throw std::runtime_error("invalidCursor");
    if (modern(session)) {
        Statement row{prepare("SELECT id FROM session_message WHERE session_id=? AND (seq,id)<(?,?) ORDER BY seq DESC,id DESC LIMIT 1")};
        bind(row.value, 1, session); sqlite3_bind_int64(row.value, 2, key.created); bind(row.value, 3, key.id);
        return step(row.value) == SQLITE_ROW ? column(row.value, 0) : "";
    }
    if (!identifier(key.message)) throw std::runtime_error("invalidCursor");
    if (key.id != key.message) {
        Statement row{prepare("SELECT id FROM part WHERE message_id=? AND session_id=? AND id<? ORDER BY id DESC LIMIT 1")};
        bind(row.value, 1, key.message); bind(row.value, 2, session); bind(row.value, 3, key.id);
        return step(row.value) == SQLITE_ROW ? column(row.value, 0) : key.message;
    }
    Statement message{prepare("SELECT id FROM message WHERE session_id=? AND (time_created,id)<(?,?) ORDER BY time_created DESC,id DESC LIMIT 1")};
    bind(message.value, 1, session); sqlite3_bind_int64(message.value, 2, key.created); bind(message.value, 3, key.message);
    if (step(message.value) != SQLITE_ROW) return "";
    const auto previous = column(message.value, 0);
    Statement part{prepare("SELECT id FROM part WHERE message_id=? AND session_id=? ORDER BY id DESC LIMIT 1")};
    bind(part.value, 1, previous); bind(part.value, 2, session);
    return step(part.value) == SQLITE_ROW ? column(part.value, 0) : previous;
}
}
