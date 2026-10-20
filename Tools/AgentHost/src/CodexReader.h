#pragma once
#include "CodexServer.h"
#include "JsonlReader.h"
#include <map>

namespace tessera {
struct CodexPage {
    JsonlPage page;
    std::string before, after;
};
// Client-local ordering/cursors, backed by the host's single App Server.
// Provider cursors remain opaque. No private SQLite schema is used here.
class CodexReader {
public:
    CodexPage read(CodexServer& server, const std::string& thread, const std::string& operation,
                   const std::string& cursor, uint64_t order, size_t limit);
    size_t bytes() const { return bytes_; }
private:
    struct Item { uint64_t order, revision; std::string json; };
    std::map<std::string, Item> items_;
    size_t bytes_ = 0;
    uint64_t revisionClock_ = 0;
    PositionedRecord retain(NormalizedRecord value, uint64_t order);
    CodexPage readStaged(CodexServer& server, const std::string& thread, const std::string& operation,
                        const std::string& cursor, uint64_t order, size_t limit);
};
}
