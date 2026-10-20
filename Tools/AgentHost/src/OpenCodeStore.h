#pragma once
#include "Normalize.h"
#include <chrono>
#include <functional>
#include <string>
#include <vector>
#include <sqlite3.h>

namespace tessera {
// One bounded read transaction. Uses SQLite's actual WAL reader while the
// provider holds its store open, and reads the main file as an immutable
// snapshot once the provider has closed it (a closing writer checkpoints and
// removes its WAL, and this helper never creates files in a provider's home).
// No provider executable is started.
class OpenCodeStore {
public:
    struct Session { std::string id; uint64_t modified = 0; std::string title; };
    struct Key { int64_t created = 0; std::string id, message; };
    struct Row { Key key; NormalizedRecord value; };
    // promptReason is the store's code when only the opening prompt was
    // unreadable; the name read beside it still stands.
    struct CodexMetadata { std::string name, openingPrompt, promptReason; };
    OpenCodeStore(std::string path, std::function<bool()> cancelled = {});
    ~OpenCodeStore();
    OpenCodeStore(const OpenCodeStore&) = delete;
    OpenCodeStore& operator=(const OpenCodeStore&) = delete;
    std::vector<Session> inventory();
    Session metadata(const std::string& session);
    std::vector<Row> page(const std::string& session, const Key* boundary, bool forward, size_t limit);
    Row exact(const std::string& session, const Key& key);
    std::string predecessor(const std::string& session, const Key& key);
    std::string identity(const std::string& session);
    uint64_t bytesRead() const { return bytesRead_; }
    // Whether this read is an immutable snapshot of a closed WAL-mode store
    // (no -wal sidecar) rather than a locked read through the live WAL.
    bool snapshot() const { return immutable_; }
    // SQLite unix VFS syscall shim. Authorization stays active through close.
    static int secureOpen(const char* path, int flags, int mode);
    // Dirty hints only: prefer WAL commits, falling back to the main inode
    // until a writer creates its WAL. Every canonical read re-arms this.
    static int wakeupDescriptor(const std::string& authorizedDatabasePath);
    // Reuse this worker-confined bounded SQLite/VFS machinery, not OpenCode's
    // schema, for optional Codex metadata. Caller supplies a catalog-owned path.
    static std::string codexTitle(const std::string& path, const std::string& session,
                                 std::function<bool()> cancelled = {});
    static CodexMetadata codexMetadata(const std::string& path, const std::string& session,
                                       std::function<bool()> cancelled = {});
private:
    OpenCodeStore(std::string path, std::function<bool()> cancelled, bool metadataOnly);
    void check();
    void exec(const char* sql);
    sqlite3_stmt* prepare(const std::string& sql);
    int step(sqlite3_stmt* statement);
    std::string blob(const char* table, int64_t row, bool& clipped);
    // A snapshot is only as good as the file staying put: a provider that
    // reopened its store and checkpointed during the read could have torn
    // what was read. intact() re-checks the sidecar and the main file's
    // identity, size and mtime; settled() throws sourceChanged instead.
    bool intact();
    void settled();
    // Runs one public read under the snapshot contract: a torn snapshot is
    // reported as sourceChanged whatever SQLite or the decoder made of it.
    template <typename Body> auto guarded(Body&& body) -> decltype(body()) {
        try { auto value = body(); settled(); return value; }
        catch (const std::runtime_error& error) {
            if (immutable_ && std::string(error.what()) != "cancelled" && !intact()) throw std::runtime_error("sourceChanged");
            throw;
        }
    }
    struct CodexFields { std::string name, shortTitle, metadataName, firstUserMessage, title, promptReason; };
    static CodexFields codexFields(const std::string& path, const std::string& session,
                                   std::function<bool()> cancelled, bool includePrompt);
    static CodexFields codexFieldsOnce(const std::string& path, const std::string& session,
                                       std::function<bool()> cancelled, bool includePrompt);
    std::vector<Session> inventoryUnguarded();
    Session metadataUnguarded(const std::string& session);
    std::string predecessorUnguarded(const std::string& session, const Key& key);
    bool modern(const std::string& session);
    std::vector<Row> read(const std::string& session, const Key* boundary, bool forward, size_t limit, bool exact);
    std::vector<Row> legacy(const std::string& session, const Key* boundary, bool forward, size_t limit, bool exact);
    void validateSchema();
    static int progress(void* context);
    sqlite3* database_ = nullptr;
    std::string path_, identity_;
    std::function<bool()> cancelled_;
    std::chrono::steady_clock::time_point deadline_;
    uint64_t steps_ = 0, bytesRead_ = 0;
    bool modernTable_ = false, immutable_ = false;
    int64_t snapshotSize_ = -1, snapshotModified_ = 0;
    OpenCodeStore* previous_ = nullptr;
};
}
