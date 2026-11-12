#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include <functional>
#include <sys/stat.h>
#include "OpenCodeStore.h"

namespace tessera {
std::string randomID();
struct Source {
    std::string handle, provider, sessionID, path;
    uint64_t bytes = 0, modified = 0;
    // Private validation cache, never part of an inventory/wire record.
    std::string fileWitness;
};
// Worker-thread confined. Client paths are hints, never file authority.
class Catalog {
public:
    Catalog();
    // Call once on the process main thread before creating readers/workers.
    // Relays pass these same frozen values through exec to the service/CLI.
    static void freezeProviderEnvironment();
    std::vector<Source> inventory(const std::string& provider = "");
    // Rows the last inventory left out (an unusable file or provider store),
    // and the first one's reason.
    size_t skippedSources() const { return skippedSources_; }
    const std::string& skipReason() const { return skipReason_; }
    bool inventoryIncomplete() const { return inventoryIncomplete_; }
    /** Absolute, at most 2048 bytes of UTF-8, no NUL and no dot segments. */
    static bool plainAbsolutePath(const std::string& path);
    Source resolve(const std::string& provider, const std::string& path);
    // `listedPath`: the latest inventory walk's spelling of `path`, if it listed it.
    Source identifyCodex(const std::string& sessionID, const std::string& path, uint64_t modified,
                         const std::string& listedPath = {});
    Source resolveCodex(const std::string& sessionID) const;
    Source resolveOpenCode(const std::string& sessionID);
    // Finds a catalog-authorized file hint; the reader MUST verify its header
    // identity before treating it as an inherited source.
    Source resolveCodexFile(const std::string& sessionID, bool allowMissing = false);
    const Source& source(const std::string& handle) const;
    int open(const Source& source) const;
    std::string scopeIdentity() const;
    std::string codexTitle(const Source& source) const;
    OpenCodeStore::CodexMetadata codexMetadata(const Source& source) const;
    std::function<bool()> cancelled;
private:
    struct Root { std::string provider, path; };
    std::vector<Root> roots_;
    std::string codexHome_;
    std::map<std::string, Source> sources_;
    std::map<std::string, std::string> handles_;
    size_t pathBytes_ = 0;
    size_t skippedSources_ = 0;
    std::string skipReason_;
    bool inventoryIncomplete_ = false;
    // Pi/Kimi headers this host refused, by key, with the file witness they
    // were read at: an unchanged file is refused again without a read.
    std::map<std::string, std::pair<std::string, std::string>> rejectedHeaders_;
    Source remember(const std::string& provider, const std::string& path);
    // A leaf the inventory walk found in its open, authorized `directory`.
    Source rememberListed(const std::string& provider, const std::string& path, int directory,
                          const std::string& name, const struct stat& listed,
                          const std::map<std::string, std::string>& kimiIndex);
    // `openLeaf` is called only when a Pi/Kimi header must be read.
    Source record(Source source, const struct stat& info, const std::function<int()>& openLeaf);
    Source rememberOpenCode(const std::string& sessionID, uint64_t modified);
    std::string openCodePath() const;
    std::string codexMetadataPath(const Source& source) const;
    const std::map<std::string, std::string>& kimiSessions() const;
    std::string kimiIdentity(const std::string& path) const;
    mutable std::map<std::string, std::string> kimiSessions_;
    mutable std::string kimiIndexWitness_;
};
}
