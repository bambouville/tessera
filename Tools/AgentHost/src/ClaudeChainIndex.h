#pragma once
#include "JsonlReader.h"
#include "HistoryMetadataBudget.h"
#include "SourceValidation.h"
#include <array>
#include <map>
#include <set>
#include <optional>

namespace tessera {
// Worker-confined, metadata only. Content is decoded only for an admitted page.
// The official SDK sessions.py is the differential reference for leaf choice.
class ClaudeChainIndex {
public:
    struct Entry {
        uint64_t start = 0, end = 0;
        std::string id, parent;
        bool node = false, message = false, main = false;
        // Claude compaction: a root compact_boundary node continues display
        // ancestry at its effective parent (see effectiveParent). Leaf and
        // terminal selection still use only parentUuid, as in the SDK.
        std::string logicalParent;
        bool boundary = false, sidechain = false;
        Entry() = default;
        Entry(uint64_t start, uint64_t end, std::string id, std::string parent, bool node, bool message, bool main,
              std::string logicalParent = {}, bool boundary = false, bool sidechain = false)
            : start(start), end(end), id(std::move(id)), parent(std::move(parent)), node(node), message(message), main(main),
              logicalParent(std::move(logicalParent)), boundary(boundary), sidechain(sidechain) {}
    };
    // Pi uses the same bounded metadata/cache machinery but selects the last
    // persisted entry, not Claude's newest authored main-thread leaf.
    void refresh(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget = 128 * 1024 * 1024,
                 bool pi = false, const std::string& expectedSessionID = {});
    size_t size() const { return static_cast<size_t>(selectedCount_); }
    Entry entry(JsonlReader& reader, size_t ordinal, const std::function<bool()>& cancelled = {});
    const std::string& generation() const { return generation_; }
    bool branched() const { return parentFields_; }
    bool lazy() const { return lazy_; }
    bool linear() const { return linear_; }
    size_t bytes() const;
    // Entries must be in physical order. A root compaction boundary's
    // effective parent is its logical parent when that UUID's current
    // revision starts before the boundary, else the nearest earlier current
    // non-sidechain node, else none; it always starts before the boundary.
    // Once ancestry crosses a boundary, every later step (the crossing
    // included) must reach a node earlier than all nodes already on the
    // path; otherwise the path stops at the node taking that step. A forward
    // parentUuid link therefore cannot turn a boundary into a cycle. Before
    // the first crossing, parentUuid ancestry and its cycle proof are as
    // before.
    static std::vector<size_t> chain(const std::vector<Entry>& entries, const std::function<bool()>& cancelled = {},
        bool includeTrailingContext = false);
private:
    SourceValidation validation_;
    uint64_t validatedRevision_ = 0;
    struct Compact {
        uint64_t start = 0, end = 0, parent = UINT64_MAX, hash = 0;
        uint16_t flags = 0;
        // Scan-time hint for a node's parentUuid (a boundary's logical
        // parent): an earlier node with that exact UUID, UINT64_MAX when
        // the name is empty, or unresolvedLink (phase 2 rereads the record).
        uint64_t link = UINT64_MAX;
    };
    struct Identity { uint64_t hash = 0, index = 0; };
    struct CachedEntry { uint64_t ordinal = 0, start = 0, end = 0; };
    struct LazyCursor {
        uint64_t remaining = 0, metadataEnd = 0;
        std::optional<Entry> node;
        bool emitNode = false;
        // ancestryMaximum(node), kept across metadata emissions and yields.
        bool thresholdKnown = false;
        uint64_t threshold = 0;
    };
    // Sorted node identities of entries_; kept after a compact build so an
    // append resolves new links without rereading the published prefix.
    std::vector<Identity> identities_;
    unsigned compactPhase_ = 0;
    size_t compactCursor_ = 0;
    // Nearest current non-sidechain node before compactCursor_ (phase 2).
    uint64_t compactMainNode_ = UINT64_MAX;
    // Entries before builtCount_ hold a complete compact build's flags and
    // links. compactFrom_ is where the running build started (0 = full).
    // dangling_ holds hashes of current parentUuid names that resolved to no
    // node: an append supplying one changes an old link, so it rebuilds.
    uint64_t builtCount_ = 0, builtMainNode_ = UINT64_MAX, compactFrom_ = 0;
    size_t builtDangling_ = 0;
    std::vector<uint64_t> dangling_;
    // Exact UUIDs of the latest scanned nodes, which supply link hints and
    // spare exact checks a reread. Parents are usually a few records back,
    // often behind uuid-less metadata; entries_ never changes a scanned
    // index's record within a validated revision.
    // Only UUIDs up to recentIdLimit bytes are kept (Claude's are 36), so the
    // ring's strings stay within the fixed cost compactCapacity() reserves.
    static constexpr size_t recentSlots = 64, recentIdLimit = 64;
    struct Recent { uint64_t index = UINT64_MAX, hash = 0; std::string id; };
    std::array<Recent, recentSlots> recent_{};
    size_t recentNext_ = 0;
    // Entries a compact index may hold within budget, after fixed costs.
    static size_t compactCapacity(size_t budget);
    std::vector<Compact> entries_;
    std::vector<uint64_t> selected_;
    std::vector<CachedEntry> window_;
    std::string identity_, generation_;
        uint64_t position_ = 0, witness_ = 0, headerWitness_ = 0;
    uint64_t physicalCount_ = 0, metadataCount_ = 0, selectedCount_ = 0, publishedEnd_ = 0;
    size_t budget_ = 128 * 1024 * 1024;
    bool parentFields_ = false, dirty_ = false, lazy_ = false, pi_ = false;
    bool monotonePath_ = true;
    unsigned piVersion_ = 0;
    std::optional<Entry> tail_;
    uint64_t pathMaximum_ = 0;
    LazyCursor cursor_;
    struct LinearBuild {
        unsigned phase = 0;
        uint64_t position = 0, physical = 0, selected = 0, stride = 1;
        bool authored = false;
        // Compaction: linked = the boundary at position already proved its
        // effective parent is the previous node. segmentMain = the latest
        // message since the last boundary is main. inserted/reordered detect
        // a previously published selection that deferred a boundary tail.
        // root = the first node, where the linear path ends.
        bool boundaries = false, segmentMain = false, linked = false, inserted = false, reordered = false;
        uint64_t root = UINT64_MAX;
        std::optional<Entry> previous, candidate;
        std::vector<uint64_t> bloom;
    } linearBuild_;
    std::vector<CachedEntry> checkpoints_;
    bool linear_ = false, linearAuthored_ = false;
    uint64_t linearPagePosition_ = 0, linearPageOrdinal_ = 0;
    bool proveLinear(JsonlReader& reader, const std::function<bool()>& cancelled);
    bool selectedLinear(const Entry& entry) const;
    Entry linearEntry(JsonlReader& reader, size_t ordinal, const std::function<bool()>& cancelled);
    void demote();
    struct Lookup {
        std::string id;
        uint64_t position = 0;
        bool active = false;
    } lookup_;
    // Resumable lazy effective-parent resolution for one boundary: phase 1
    // resolves the logical parent, 4 looks for its revision before the
    // boundary (publication check only), 2 scans backward from position, 3
    // proves the positional candidate is its UUID's current revision.
    struct BoundaryLookup {
        uint64_t boundary = UINT64_MAX, position = 0;
        unsigned phase = 0;
        std::optional<Entry> candidate;
    } boundaryLookup_;
    struct LazyBuild {
        unsigned phase = 0;
        uint64_t scan = 0, childScan = 0, steps = 0, count = 0, maximum = 0;
        bool authored = false, monotone = true, prefix = true, oldTailFound = false;
        std::optional<Entry> candidate, leaf, child, bestLeaf, bestTerminal, current, oldTail;
        uint64_t oldCount = 0;
        // Compaction walk (Claude): lowest start on the path; whether a
        // boundary was crossed; the stop node (chain()'s rule) and the last
        // node reached; the earliest newly selected node that precedes
        // publishedEnd_ (a deferred boundary tail) and the scan proving no
        // published metadata follows it; revised = an append may have
        // changed a published boundary's effective parent.
        uint64_t minimum = UINT64_MAX, cut = UINT64_MAX, deferred = UINT64_MAX, metadataScan = 0, last = UINT64_MAX;
        bool crossed = false, revised = false;
    } build_;
    // Start of the published path's stop node (see chain()), UINT64_MAX if the
    // path ends at a root; and of its first node (root or stop node).
    uint64_t cutStart_ = UINT64_MAX, pathEnd_ = UINT64_MAX;
    bool buildingWindow_ = false;
    uint64_t windowBegin_ = 0, windowEnd_ = 0;
    std::optional<Entry> maximumCurrent_;
    bool maximumActive_ = false;
    uint64_t maximumValue_ = 0, maximumSteps_ = 0;
    Entry decode(const PositionedRecord& record, uint64_t previousStart = UINT64_MAX) const;
    Entry readEntry(JsonlReader& reader, uint64_t start, uint64_t end) const;
    std::optional<Entry> latest(JsonlReader& reader, const std::string& id, const std::function<bool()>& cancelled);
    std::optional<Entry> parent(JsonlReader& reader, const Entry& node, const std::function<bool()>& cancelled);
    // Display ancestry: parent() except across a Claude compaction boundary.
    // revised: set when an append since publishedEnd_ may have changed a
    // published boundary's resolution without adding a node to the path.
    std::optional<Entry> effectiveParent(JsonlReader& reader, const Entry& node, const std::function<bool()>& cancelled,
        bool* revised = nullptr);
    // effectiveParent() on the published path, which stops at cutStart_.
    std::optional<Entry> displayParent(JsonlReader& reader, const Entry& node, const std::function<bool()>& cancelled);
    void rebuildCompact(JsonlReader& reader, const std::function<bool()>& cancelled);
    void rebuildLazy(JsonlReader& reader, const std::function<bool()>& cancelled);
    uint64_t ancestryMaximum(JsonlReader& reader, const std::optional<Entry>& node, const std::function<bool()>& cancelled);
    void resetCursor();
    std::optional<CachedEntry> nextLazy(JsonlReader& reader, const std::function<bool()>& cancelled);

};
class ClaudeChainCache {
public:
    explicit ClaudeChainCache(HistoryMetadataBudget* budget = nullptr);
    ~ClaudeChainCache();
    ClaudeChainCache(const ClaudeChainCache&) = delete;
    ClaudeChainCache& operator=(const ClaudeChainCache&) = delete;
    size_t usedBytes() const;
    ClaudeChainIndex& get(const std::string& key);
    void pin(std::set<std::string> paths) { pinned_ = std::move(paths); }
    void beginRead() { transientPins_.clear(); }
    const std::set<std::string>& readPaths() const { return transientPins_; }
    void pending(std::set<std::string> paths) { pendingPins_ = std::move(paths); }
    void enforce(const std::string& key);
    size_t budgetFor(const std::string& key);
private:
    struct Cached { ClaudeChainIndex index; uint64_t touched = 0; };
    HistoryMetadataBudget* budget_ = nullptr;
    std::map<std::string, Cached> indexes_;
    uint64_t clock_ = 0;
    std::set<std::string> pinned_;
    std::set<std::string> transientPins_, pendingPins_;
    bool retained(const std::string& key) const {
        return pinned_.count(key) || transientPins_.count(key) || pendingPins_.count(key);
    }
};
}
