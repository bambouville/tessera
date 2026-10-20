#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include <functional>
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
    Source resolve(const std::string& provider, const std::string& path);
    Source identifyCodex(const std::string& sessionID, const std::string& path, uint64_t modified);
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
    Source remember(const std::string& provider, const std::string& path);
    Source rememberOpenCode(const std::string& sessionID, uint64_t modified);
    std::string openCodePath() const;
    std::string codexMetadataPath(const Source& source) const;
    const std::map<std::string, std::string>& kimiSessions() const;
    std::string kimiIdentity(const std::string& path) const;
    mutable std::map<std::string, std::string> kimiSessions_;
    mutable std::string kimiIndexWitness_;
};
}
