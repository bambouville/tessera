#pragma once
#include "WindowPageReader.h"

namespace tessera {
struct WindowReply {
    std::string transaction, lane, source, from, liveCursor, fallback;
    uint64_t version = 0, sourceEnd = 0, bytesRead = 0;
    bool native = false, canonicalCodex = false, hasNewer = false, unchanged = false;
    PageWindow::Segment segment;
    std::vector<PositionedRecord> records;
    std::vector<WindowPartition> partitions;
};

// Confined to the worker. The outer map keys this object by authenticated
// client token AND thread handle. No client can guess another client's range.
class WindowSession {
public:
    // `serviceBytes`: footprint() summed over every window of the service.
    WindowReply read(WindowPageReader& reader, CodexServer& codex, const Source& source,
                     const std::string& transaction, const std::string& operation,
                     const std::string& cursor, uint64_t version, size_t limit, bool automatic,
                     size_t serviceBytes);
    void acknowledge(const std::string& transaction, uint64_t version,
                     const std::vector<std::string>& viewport, const std::string& head);
    void cancel(const std::string& transaction);
    const std::string& liveCursor() const { return live_; }
    uint64_t version() const { return window_.version(); }
    bool pending() const { return window_.pending(); }
    size_t footprint() const { return window_.footprint(); }
    // Drops a staged transaction whose ACK deadline passed; true if it did.
    bool expire();
    const std::string& sourcePath() const { return sourcePath_; }
private:
    PageWindow window_;
    std::map<std::string, WindowAnchor> anchors_, proposedAnchors_;
    std::string generation_, live_, pendingTransaction_, proposedGeneration_, proposedLive_;
    uint64_t revision_ = 0;
    uint64_t proposedRevision_ = 0;
    // Revision coverage advances only with the corresponding retention ACK.
    // An empty value starts a new sweep; navigation resets the sweep because
    // its retained coverage may have changed.
    std::string revisionAfter_, proposedRevisionAfter_;
    std::string sourcePath_;
};
}
