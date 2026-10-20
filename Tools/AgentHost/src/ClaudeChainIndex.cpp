#include "ClaudeChainIndex.h"
#include "PageWindow.h"
#include "Catalog.h"
#include "Json.h"
#include <optional>
#include <algorithm>
#include <set>
#include <stdexcept>

namespace tessera {
std::vector<size_t> ClaudeChainIndex::chain(const std::vector<Entry>& entries, const std::function<bool()>& cancelled,
        bool includeTrailingContext) {
    std::map<std::string, size_t> latest;
    std::set<std::string> parents;
    for (size_t i = 0; i < entries.size(); ++i) if (entries[i].node) latest[entries[i].id] = i;
    // Revisions replace both body and parent. Retaining an obsolete parent
    // edge can falsely hide the newest authored leaf as a nonterminal node.
    for (const auto& entry : latest) {
        const auto& parent = entries[entry.second].parent;
        if (!parent.empty()) parents.insert(parent);
    }
    std::optional<size_t> mainLeaf, anyLeaf;
    std::optional<size_t> mainTerminal, anyTerminal;
    std::vector<bool> resolved(entries.size(), false);
    std::vector<std::optional<size_t>> nearest(entries.size());
    size_t work = 0;
    for (size_t terminal = 0; terminal < entries.size(); ++terminal) {
        const auto& entry = entries[terminal];
        // Intentional correction to SDK's first-terminal tie: a rewritten
        // terminal UUID must expose its newest body, not stale live output.
        if (!entry.node || parents.count(entry.id) || latest.at(entry.id) != terminal) continue;
        std::optional<size_t> current = terminal;
        std::set<size_t> visited;
        std::vector<size_t> trail;
        std::optional<size_t> leaf;
        while (current && visited.insert(*current).second) {
            if ((++work % 64) == 0 && cancelled && cancelled()) throw std::runtime_error("cancelled");
            const auto index = *current; const auto& node = entries[index];
            if (resolved[index]) { leaf = nearest[index]; break; }
            trail.push_back(index);
            if (node.message) { leaf = index; break; }
            const auto parent = latest.find(node.parent);
            current = node.parent.empty() || parent == latest.end() ? std::nullopt : std::optional<size_t>(parent->second);
        }
        for (const auto index : trail) { resolved[index] = true; nearest[index] = leaf; }
        if (!leaf) continue;
        auto newer = [&](const std::optional<size_t>& selected, const std::optional<size_t>& tail) {
            return !selected || latest.at(entries[*leaf].id) > latest.at(entries[*selected].id) ||
                (*leaf == *selected && (!tail || terminal > *tail));
        };
        if (newer(anyLeaf, anyTerminal)) { anyLeaf = leaf; anyTerminal = terminal; }
        if (entries[*leaf].main && newer(mainLeaf, mainTerminal)) { mainLeaf = leaf; mainTerminal = terminal; }
    }
    // Message selection remains SDK-equivalent. For stable window ordinals,
    // also admit its current trailing context chain now, not only when a
    // later user message parents to it. Otherwise an ordinary new turn inserts
    // old attachments before already-admitted bookkeeping and resets history.
    // Competing context-only branches choose the latest terminal, without
    // selecting a different authored-message leaf.
    const auto leaf = includeTrailingContext ? (mainLeaf ? mainTerminal : anyTerminal) : (mainLeaf ? mainLeaf : anyLeaf);
    std::vector<size_t> result;
    if (!leaf) {
        // Authored nodes with no reachable terminal form a cycle. Publishing
        // an empty transcript would conceal a structural failure as EOF.
        for (const auto& entry : latest) if (entries[entry.second].message)
            throw std::runtime_error("claudeIndexUnproven");
        return result;
    }
    // Only the selected ancestry continues through a compaction boundary; it
    // never chooses another leaf. The effective parent starts before the
    // boundary, but a forward parentUuid below it could lead back onto the
    // path, so once a boundary is crossed each step must reach a node earlier
    // than the whole path so far, or the path stops there (see header).
    auto effectiveParent = [&](size_t index) -> std::optional<size_t> {
        const auto& node = entries[index];
        if (!node.boundary || !node.parent.empty()) {
            const auto parent = latest.find(node.parent);
            return node.parent.empty() || parent == latest.end() ? std::nullopt : std::optional<size_t>(parent->second);
        }
        const auto logical = node.logicalParent.empty() ? latest.end() : latest.find(node.logicalParent);
        if (logical != latest.end() && entries[logical->second].start < node.start) return logical->second;
        for (size_t candidate = index; candidate-- > 0;) {
            if ((++work % 64) == 0 && cancelled && cancelled()) throw std::runtime_error("cancelled");
            const auto& value = entries[candidate];
            if (value.node && !value.sidechain && value.start < node.start && latest.at(value.id) == candidate) return candidate;
        }
        return std::nullopt;
    };
    std::optional<size_t> current = leaf;
    std::set<std::string> visited;
    uint64_t minimum = UINT64_MAX;
    bool crossed = false;
    while (current) {
        if ((++work % 64) == 0 && cancelled && cancelled()) throw std::runtime_error("cancelled");
        if (!visited.insert(entries[*current].id).second) throw std::runtime_error("claudeIndexUnproven");
        result.push_back(*current);
        const auto& node = entries[*current];
        minimum = std::min(minimum, node.start);
        crossed = crossed || (node.boundary && node.parent.empty());
        const auto next = effectiveParent(*current);
        if (crossed && next && entries[*next].start >= minimum) break;
        current = next;
    }
    std::reverse(result.begin(), result.end());
    return result;
}

namespace {
constexpr uint16_t nodeFlag = 1, messageFlag = 2, mainFlag = 4, latestFlag = 8,
    parentedFlag = 16, resolvedFlag = 32, visitingFlag = 64,
    // Persistent record facts for Claude compaction. logicalFlag is derived:
    // the boundary's stored parent came from its logicalParentUuid.
    sidechainFlag = 128, boundaryFlag = 256, logicalFlag = 512,
    persistentFlags = nodeFlag | messageFlag | mainFlag | sidechainFlag | boundaryFlag;
constexpr uint64_t absent = UINT64_MAX, unresolvedLink = UINT64_MAX - 1;
uint16_t recordFlags(const ClaudeChainIndex::Entry& entry) {
    return static_cast<uint16_t>((entry.node ? nodeFlag : 0) | (entry.message ? messageFlag : 0) | (entry.main ? mainFlag : 0) |
        (entry.sidechain ? sidechainFlag : 0) | (entry.boundary ? boundaryFlag : 0));
}
// Includes retained metadata and link hints, both old/new selections, the
// retained identity and dangling-parent tables, ancestry/nearest scratch, and
// vector-capacity rounding. Payloads stay in the reader's separately bounded
// 100-record page, never in this index.
constexpr size_t recordCost = 160;
uint64_t identityHash(const std::string& value) {
    uint64_t result = 1469598103934665603ULL;
    for (const unsigned char byte : value) { result ^= byte; result *= 1099511628211ULL; }
    return result;
}
void checkCancelled(const std::function<bool()>& cancelled) {
    if (cancelled && cancelled()) throw std::runtime_error("cancelled");
}
}

size_t ClaudeChainIndex::compactCapacity(size_t budget) {
    // The object and its recent-UUID ring (each string at most recentIdLimit
    // bytes plus allocator rounding) are fixed costs outside recordCost.
    const size_t fixed = sizeof(ClaudeChainIndex) + recentSlots * (recentIdLimit + 32);
    return budget > fixed ? (budget - fixed) / recordCost : 0;
}

size_t ClaudeChainIndex::bytes() const {
    size_t result = entries_.capacity() * sizeof(Compact) + selected_.capacity() * sizeof(uint64_t) +
        window_.capacity() * sizeof(CachedEntry) + identities_.capacity() * sizeof(Identity) + identity_.capacity() +
        generation_.capacity() + lookup_.id.capacity() + sizeof(*this) + dangling_.capacity() * sizeof(uint64_t) +
        linearBuild_.bloom.capacity() * sizeof(uint64_t) + checkpoints_.capacity() * sizeof(CachedEntry);
    for (const auto& value : recent_) result += value.id.capacity();
    for (const auto* value : {&tail_, &cursor_.node, &build_.candidate, &build_.leaf, &build_.child,
            &build_.bestLeaf, &build_.bestTerminal, &build_.current, &build_.oldTail, &maximumCurrent_, &linearBuild_.previous,
            &linearBuild_.candidate, &boundaryLookup_.candidate})
        if (*value) result += (*value)->id.capacity() + (*value)->parent.capacity() + (*value)->logicalParent.capacity();
    return result;
}

ClaudeChainIndex::Entry ClaudeChainIndex::decode(const PositionedRecord& record, uint64_t previousStart) const {
    const auto& value = record.value;
    if (value.disposition == "malformed" || value.disposition == "unsupported" || value.chainUnproven)
        throw std::runtime_error("claudeIndexUnproven");
    // Compaction fields are Claude-only; Pi records never carry them.
    const bool boundary = !pi_ && value.chainCompactBoundary && value.chainParentID.empty();
    Entry result{record.start, record.end, value.chainID, value.chainParentID,
        value.chainEntry, value.chainMessage, value.chainMain,
        boundary ? value.chainLogicalParentID : std::string(), boundary, !pi_ && value.chainSidechain};
    if (pi_ && value.sourceType != "session") {
        if (piVersion_ == 1) {
            result.id = "v1:" + std::to_string(record.start);
            result.parent = previousStart == absent ? "" : "v1:" + std::to_string(previousStart);
        } else if (!value.parentField || result.id.empty()) throw std::runtime_error("piChainUnproven");
        result.node = true;
    }
    return result;
}

ClaudeChainIndex::Entry ClaudeChainIndex::readEntry(JsonlReader& reader, uint64_t start, uint64_t end) const {
    uint64_t previous = absent;
    if (pi_ && piVersion_ == 1 && start) {
        const auto before = reader.page(start, false, 1);
        if (!before.records.empty() && before.records.front().value.sourceType != "session") previous = before.records.front().start;
    }
    return decode(reader.readRecord(start, end), previous);
}

std::optional<ClaudeChainIndex::Entry> ClaudeChainIndex::latest(JsonlReader& reader, const std::string& id,
        const std::function<bool()>& cancelled) {
    if (id.empty()) return std::nullopt;
    if (pi_ && piVersion_ == 1 && id.compare(0, 3, "v1:") == 0) {
        const auto start = std::stoull(id.substr(3));
        const auto page = reader.page(start, true, 1);
        if (page.records.empty() || page.records.front().start != start) throw std::runtime_error("piChainUnproven");
        return readEntry(reader, page.records.front().start, page.records.front().end);
    }
    if (!lookup_.active || lookup_.id != id) lookup_ = {id, position_, true};
    while (lookup_.position) {
        checkCancelled(cancelled);
        const auto page = reader.page(lookup_.position, false, 100);
        if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
        for (auto it = page.records.rbegin(); it != page.records.rend(); ++it) {
            const auto candidate = decode(*it);
            if (candidate.node && candidate.id == id) { lookup_.active = false; return candidate; }
        }
        lookup_.position = page.records.front().start;
    }
    lookup_.active = false; return std::nullopt;
}

std::optional<ClaudeChainIndex::Entry> ClaudeChainIndex::parent(JsonlReader& reader, const Entry& node,
        const std::function<bool()>& cancelled) {
    auto result = latest(reader, node.parent, cancelled);
    if (pi_ && !node.parent.empty() && (!result || result->start >= node.start)) throw std::runtime_error("piChainUnproven");
    return result;
}

std::optional<ClaudeChainIndex::Entry> ClaudeChainIndex::effectiveParent(JsonlReader& reader, const Entry& node,
        const std::function<bool()>& cancelled, bool* revised) {
    if (pi_ || !node.boundary || !node.parent.empty()) return parent(reader, node, cancelled);
    // Same rule as chain(): the logical parent's current revision if it
    // starts before the boundary, else the nearest earlier current
    // non-sidechain node. Every stage keeps its cursor in boundaryLookup_
    // (and lookup_), so a yielded worker slice resumes instead of restarting.
    auto& state = boundaryLookup_;
    if (!state.phase || state.boundary != node.start) state = {node.start, node.start, 1, std::nullopt};
    // Only a revision appended since publication can change a published
    // boundary's choice, and unlike a parentUuid revision it adds no node to
    // the path. A rejected current revision appended since then reports it.
    auto appended = [&](const std::optional<Entry>& current) {
        return revised && current && node.start < publishedEnd_ && current->start >= publishedEnd_;
    };
    if (state.phase == 1) {
        std::optional<Entry> logical;
        if (!node.logicalParent.empty()) logical = latest(reader, node.logicalParent, cancelled);
        if (logical && logical->start < node.start) { state = {}; return logical; }
        state.phase = appended(logical) ? 4 : 2;
    }
    if (state.phase == 4) {
        // It can have changed the choice only if a revision before the
        // boundary exists, which the published choice could have accepted.
        if (!lookup_.active || lookup_.id != node.logicalParent) lookup_ = {node.logicalParent, node.start, true};
        if (latest(reader, node.logicalParent, cancelled)) *revised = true;
        state.phase = 2;
    }
    for (;;) {
        checkCancelled(cancelled);
        if (state.phase == 3) {
            const auto current = latest(reader, state.candidate->id, cancelled);
            if (current && current->start == state.candidate->start) { auto result = std::move(state.candidate); state = {}; return result; }
            if (appended(current)) *revised = true;
            state.position = state.candidate->start; state.candidate.reset(); state.phase = 2;
        }
        if (!state.position) { state = {}; return std::nullopt; }
        const auto page = reader.page(state.position, false, 100);
        if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
        for (auto it = page.records.rbegin(); it != page.records.rend(); ++it) {
            auto candidate = decode(*it);
            state.position = it->start;
            if (candidate.node && !candidate.sidechain) { state.candidate = std::move(candidate); state.phase = 3; break; }
        }
    }
}

std::optional<ClaudeChainIndex::Entry> ClaudeChainIndex::displayParent(JsonlReader& reader, const Entry& node,
        const std::function<bool()>& cancelled) {
    if (!pi_ && node.start == cutStart_) return std::nullopt;
    return effectiveParent(reader, node, cancelled);
}

void ClaudeChainIndex::refresh(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget, bool pi,
        const std::string& expectedSessionID) {
    if (budget < budget_) {
        if (!lazy_ && entries_.capacity() > compactCapacity(budget)) { demote(); dirty_ = true; }
        if (linearBuild_.bloom.capacity() * sizeof(uint64_t) > std::max<size_t>(64, budget / 2) ||
            checkpoints_.capacity() * sizeof(CachedEntry) > budget / 4) {
            linearBuild_ = {}; lookup_ = {}; boundaryLookup_ = {}; std::vector<CachedEntry>().swap(checkpoints_);
            linear_ = false; dirty_ = true;
        }
        std::vector<CachedEntry>().swap(window_); buildingWindow_ = false;
    }
    budget_ = budget;
    const auto validation = reader.validatePrefix(validation_, SourceValidation::defaultSlice, SourceValidation::Clock::now(), position_);
    if (!validation.ready) throw std::runtime_error("readPending");
    uint64_t headerWitness = 0;
    unsigned headerVersion = 0;
    if (pi) {
        const auto header = reader.firstRecord();
        if (!header || header->value.sourceType != "session" || header->value.chainUnproven) throw std::runtime_error("piHeaderMissing");
        if (!expectedSessionID.empty() && header->value.providerID != expectedSessionID) throw std::runtime_error("piIdentityConflict");
        simdjson::dom::parser parser;
        const auto version = json::integer(parser.parse(header->value.json).value(), "sessionVersion");
        if (version < 1 || version > 3) throw std::runtime_error("piFormatUnsupported");
        headerVersion = static_cast<unsigned>(version); headerWitness = reader.anchor(header->end);
    }
    if (validatedRevision_ != validation.revision || identity_ != reader.identity() || position_ > reader.size() ||
        (pi && headerWitness_ != headerWitness) || (pi && piVersion_ && piVersion_ != headerVersion) ||
        (position_ && reader.anchor(position_) != witness_)) {
        auto savedValidation = std::move(validation_);
        *this = ClaudeChainIndex(); validation_ = std::move(savedValidation);
        validatedRevision_ = validation.revision; identity_ = reader.identity();
        generation_ = std::string(pi ? "pi-chain:" : "claude-chain:") + randomID();
    }
    pi_ = pi; piVersion_ = headerVersion; budget_ = budget;
    headerWitness_ = headerWitness;
    const auto boundary = reader.completeEnd();
    if (!lazy_ && entries_.capacity() > compactCapacity(budget)) {
        demote(); dirty_ = true;
    }
    if (position_ == boundary && !dirty_) return;
    dirty_ = true;
    if (position_ < boundary) {
        // A running build restarts to include the append. A complete compact
        // build keeps its prefix: rebuildCompact resumes after builtCount_.
        compactPhase_ = 0; compactCursor_ = 0;
        build_ = {}; lookup_ = {}; boundaryLookup_ = {}; linearBuild_ = {};
    }
    while (position_ < boundary) {
        checkCancelled(cancelled);
        const auto page = reader.page(position_, true, 100);
        if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
        const auto count = entries_.size();
        const auto committedPosition = position_, committedPhysical = physicalCount_, committedMetadata = metadataCount_;
        const auto committedParentFields = parentFields_;
        try {
            uint64_t previous = absent;
            if (pi && piVersion_ == 1 && position_) {
                const auto before = reader.page(position_, false, 1);
                if (!before.records.empty() && before.records.front().value.sourceType != "session") previous = before.records.front().start;
            }
            for (const auto& record : page.records) {
                const auto entry = decode(record, previous);
                if (pi && record.value.sourceType == "session" && physicalCount_) throw std::runtime_error("piHeaderChanged");
                if (!lazy_ && entries_.size() >= compactCapacity(budget)) {
                    demote();
                }
                if (!lazy_) {
                    if (entries_.size() == entries_.capacity()) entries_.reserve(std::min(compactCapacity(budget), std::max<size_t>(256, entries_.capacity() + entries_.capacity() / 2)));
                    const auto hash = identityHash(entry.id);
                    const auto& name = entry.boundary ? entry.logicalParent : entry.parent;
                    uint64_t link = name.empty() ? absent : unresolvedLink;
                    if (entry.node && !name.empty()) {
                        const auto wanted = identityHash(name);
                        for (const auto& value : recent_)
                            if (value.index != absent && value.hash == wanted && value.id == name && (link == unresolvedLink || value.index > link)) link = value.index;
                    }
                    entries_.push_back({entry.start, entry.end, absent, hash, recordFlags(entry), link});
                    if (entry.node && entry.id.size() <= recentIdLimit) { recent_[recentNext_] = {entries_.size() - 1, hash, entry.id}; recentNext_ = (recentNext_ + 1) % recent_.size(); }
                }
                if (!entry.node && !entry.message) ++metadataCount_;
                parentFields_ = parentFields_ || record.value.parentField;
                ++physicalCount_; position_ = record.end;
                if (record.value.sourceType != "session") previous = record.start;
            }
            witness_ = reader.anchor(position_);
        } catch (...) {
            if (!lazy_) entries_.resize(count);
            for (auto& value : recent_) if (value.index != absent && value.index >= count) value = {};
            position_ = committedPosition; physicalCount_ = committedPhysical; metadataCount_ = committedMetadata;
            parentFields_ = committedParentFields; throw;
        }
    }
    if (lazy_) {
        if (!build_.phase && proveLinear(reader, cancelled)) { dirty_ = false; publishedEnd_ = position_; return; }
        rebuildLazy(reader, cancelled);
    } else rebuildCompact(reader, cancelled);
    dirty_ = false; publishedEnd_ = position_;
}

void ClaudeChainIndex::rebuildCompact(JsonlReader& reader, const std::function<bool()>& cancelled) {
    auto& identities = identities_;
    // Phases 1-2 cover entries from compactFrom_. After a complete build an
    // append changes no earlier flag or link, unless it revises an existing
    // UUID or supplies a dangling parent (checked in phase 1): only the
    // appended entries need them. Phase 3 always selects over all entries.
    auto begin = [&](uint64_t from) {
        if (!from) { identities.clear(); dangling_.clear(); builtCount_ = 0; }
        else {
            identities.erase(std::remove_if(identities.begin(), identities.end(), [&](const Identity& value) { return value.index >= from; }), identities.end());
            dangling_.resize(builtDangling_);
        }
        const auto previous = identities.size();
        identities.reserve(entries_.size());
        for (auto i = from; i < entries_.size(); ++i) {
            entries_[i].flags &= persistentFlags;
            entries_[i].parent = absent;
            if (entries_[i].flags & nodeFlag) identities.push_back({entries_[i].hash, i});
        }
        auto order = [](const auto& a, const auto& b) { return a.hash < b.hash || (a.hash == b.hash && a.index < b.index); };
        std::sort(identities.begin() + static_cast<std::ptrdiff_t>(previous), identities.end(), order);
        std::inplace_merge(identities.begin(), identities.begin() + static_cast<std::ptrdiff_t>(previous), identities.end(), order);
        compactFrom_ = from; compactPhase_ = 1; compactCursor_ = from;
    };
    if (!compactPhase_) begin(builtCount_ <= entries_.size() ? builtCount_ : 0);
    auto range = [&](uint64_t hash) {
        const auto first = std::lower_bound(identities.begin(), identities.end(), hash, [](const auto& a, uint64_t b) { return a.hash < b; });
        const auto last = std::upper_bound(first, identities.end(), hash, [](uint64_t a, const auto& b) { return a < b.hash; });
        return std::make_pair(first, last);
    };
    auto exact = [&](uint64_t index, const std::string& id) {
        // Hashes only locate candidates. Exact identities always decide.
        for (const auto& value : recent_) if (value.index == index) return value.id == id;
        return readEntry(reader, entries_[index].start, entries_[index].end).id == id;
    };
    auto lookup = [&](const std::string& id) -> uint64_t {
        if (id.empty()) return absent;
        const auto found = range(identityHash(id));
        for (auto it = found.second; it != found.first;) {
            --it;
            if (exact(it->index, id)) return it->index;
        }
        return absent;
    };
    if (compactPhase_ == 1) {
    while (compactCursor_ < entries_.size()) {
        const auto i = compactCursor_;
        if (!(entries_[i].flags & nodeFlag)) { ++compactCursor_; continue; }
        if ((i % 64) == 0) checkCancelled(cancelled);
        const auto found = range(entries_[i].hash);
        if (compactFrom_) {
            // Hash matches only widen this check; any doubt rebuilds fully.
            bool revises = std::binary_search(dangling_.begin(), dangling_.end(), entries_[i].hash);
            if (!revises && std::distance(found.first, found.second) > 1) {
                const auto id = readEntry(reader, entries_[i].start, entries_[i].end).id;
                for (auto it = found.first; !revises && it != found.second; ++it) revises = it->index != i && exact(it->index, id);
            }
            if (revises) { begin(0); continue; }
            entries_[i].flags |= latestFlag; ++compactCursor_; continue;
        }
        uint64_t newest = i;
        if (std::distance(found.first, found.second) > 1) {
            const auto value = readEntry(reader, entries_[i].start, entries_[i].end);
            newest = lookup(value.id);
            if (pi_ && newest != i) throw std::runtime_error("piDuplicateEntryID");
        }
        if (newest == i) entries_[i].flags |= latestFlag;
        ++compactCursor_;
    }
    compactPhase_ = 2; compactCursor_ = compactFrom_; compactMainNode_ = compactFrom_ ? builtMainNode_ : absent;
    }
    if (compactPhase_ == 2) {
        // A scan-time link is exact when no other node shares its hash: it
        // is then the only, hence newest, revision of that UUID. Any other
        // current node rereads its record for the exact lookup.
        auto unique = [&](uint64_t index) {
            const auto found = range(entries_[index].hash);
            return std::distance(found.first, found.second) == 1;
        };
        while (compactCursor_ < entries_.size()) {
            const auto i = compactCursor_;
            if ((i % 64) == 0) checkCancelled(cancelled);
            auto& current = entries_[i];
            if (!(current.flags & latestFlag)) { ++compactCursor_; continue; }
            const bool boundary = current.flags & boundaryFlag;
            if (current.link == absent || (current.link != unresolvedLink && current.link < i && unique(current.link))) {
                if (boundary) {
                    if (current.link != absent) { current.parent = current.link; current.flags |= logicalFlag; }
                    else current.parent = compactMainNode_;
                } else {
                    current.parent = current.link;
                    if (current.link != absent) entries_[current.link].flags |= parentedFlag;
                }
            } else {
                const auto value = readEntry(reader, current.start, current.end);
                if (boundary) {
                    // Effective display parent (chain()'s rule). It starts
                    // before i, and is not a parentUuid edge: it never makes
                    // the prior tail nonterminal or changes leaf selection.
                    // An append cannot change it: a later logical parent
                    // is never chosen, and a revision rebuilds.
                    const auto logical = lookup(value.logicalParent);
                    if (logical != absent && logical < i) { current.parent = logical; current.flags |= logicalFlag; }
                    else current.parent = compactMainNode_;
                } else {
                    const auto parentIndex = lookup(value.parent);
                    if (pi_ && !value.parent.empty() && (parentIndex == absent || parentIndex >= i)) throw std::runtime_error("piChainUnproven");
                    current.parent = parentIndex;
                    if (parentIndex != absent) entries_[parentIndex].flags |= parentedFlag;
                    else if (!value.parent.empty()) dangling_.push_back(identityHash(value.parent));
                }
            }
            if ((current.flags & (nodeFlag | sidechainFlag)) == nodeFlag) compactMainNode_ = i;
            ++compactCursor_;
        }
        compactPhase_ = 3;
    }
    for (auto& value : entries_) value.flags &= ~(resolvedFlag | visitingFlag);
    uint64_t terminal = absent;
    if (pi_) terminal = entries_.size() > 1 ? entries_.size() - 1 : absent;
    else {
        std::vector<uint64_t> nearest(entries_.size(), absent), trail;
        trail.reserve(entries_.size());
        uint64_t mainLeaf = absent, anyLeaf = absent, mainTerminal = absent, anyTerminal = absent;
        bool authored = false;
        for (size_t i = 0; i < entries_.size(); ++i) {
            const auto flags = entries_[i].flags;
            if ((flags & latestFlag) && (flags & messageFlag)) authored = true;
            if (!(flags & latestFlag) || (flags & parentedFlag)) continue;
            trail.clear(); uint64_t current = i, leaf = absent;
            while (current != absent) {
                if ((trail.size() % 64) == 0) checkCancelled(cancelled);
                auto& value = entries_[current];
                if (value.flags & resolvedFlag) { leaf = nearest[current]; break; }
                if (value.flags & visitingFlag) break;
                value.flags |= visitingFlag; trail.push_back(current);
                if (value.flags & messageFlag) { leaf = current; break; }
                // SDK-equivalent selection follows parentUuid only.
                current = (value.flags & boundaryFlag) ? absent : value.parent;
            }
            for (const auto index : trail) { entries_[index].flags = (entries_[index].flags & ~visitingFlag) | resolvedFlag; nearest[index] = leaf; }
            if (leaf == absent) continue;
            if (anyLeaf == absent || leaf > anyLeaf || (leaf == anyLeaf && i > anyTerminal)) { anyLeaf = leaf; anyTerminal = i; }
            if ((entries_[leaf].flags & mainFlag) && (mainLeaf == absent || leaf > mainLeaf || (leaf == mainLeaf && i > mainTerminal))) { mainLeaf = leaf; mainTerminal = i; }
        }
        terminal = mainLeaf != absent ? mainTerminal : anyTerminal;
        if (terminal == absent && authored) throw std::runtime_error("claudeIndexUnproven");
    }
    std::vector<uint64_t> path;
    path.reserve(entries_.size());
    // chain()'s stop rule; indices are in physical order.
    uint64_t minimum = absent, cut = absent;
    bool crossed = false;
    for (auto current = terminal; current != absent;) {
        if ((path.size() % 64) == 0) checkCancelled(cancelled);
        if (entries_[current].flags & visitingFlag) throw std::runtime_error("claudeIndexUnproven");
        entries_[current].flags |= visitingFlag; path.push_back(current);
        minimum = std::min<uint64_t>(minimum, current);
        crossed = crossed || (entries_[current].flags & boundaryFlag);
        const auto next = entries_[current].parent;
        if (crossed && next != absent && next >= minimum) { cut = current; break; }
        current = next;
    }
    cutStart_ = cut == absent ? absent : entries_[cut].start;
    pathEnd_ = path.empty() ? absent : entries_[path.back()].start;
    std::reverse(path.begin(), path.end());
    std::vector<uint64_t> selected; selected.reserve(entries_.size());
    if (pi_) { if (!entries_.empty()) selected.push_back(0); selected.insert(selected.end(), path.begin(), path.end()); }
    else {
        size_t metadata = 0;
        auto addMetadata = [&](size_t end) {
            while (metadata < end) { if (!(entries_[metadata].flags & (nodeFlag | messageFlag))) selected.push_back(metadata); ++metadata; }
        };
        for (const auto index : path) { addMetadata(index); if (!(entries_[index].flags & messageFlag) || (entries_[index].flags & mainFlag)) selected.push_back(index); }
        addMetadata(entries_.size());
    }
    bool prefix = selected.size() >= selected_.size();
    for (size_t i = 0; prefix && i < selected_.size(); ++i) prefix = selected[i] == selected_[i];
    if (!prefix) generation_ = std::string(pi_ ? "pi-chain:" : "claude-chain:") + randomID();
    selected_ = std::move(selected); selectedCount_ = selected_.size();
    tail_ = terminal == absent ? std::optional<Entry>() : readEntry(reader, entries_[terminal].start, entries_[terminal].end);
    std::sort(dangling_.begin(), dangling_.end()); dangling_.erase(std::unique(dangling_.begin(), dangling_.end()), dangling_.end());
    builtCount_ = entries_.size(); builtMainNode_ = compactMainNode_; builtDangling_ = dangling_.size();
    compactPhase_ = 0; compactCursor_ = 0;
}

void ClaudeChainIndex::demote() {
    lazy_ = true; compactPhase_ = 0; compactCursor_ = 0;
    std::vector<Compact>().swap(entries_); std::vector<uint64_t>().swap(selected_);
    std::vector<Identity>().swap(identities_); std::vector<uint64_t>().swap(dangling_);
    builtCount_ = 0; builtMainNode_ = absent; builtDangling_ = 0; compactFrom_ = 0; recent_ = {}; recentNext_ = 0;
    linearBuild_ = {}; build_ = {}; lookup_ = {}; boundaryLookup_ = {};
}

bool ClaudeChainIndex::selectedLinear(const Entry& entry) const {
    return pi_ || (!entry.node && !entry.message) || (linearAuthored_ && (!entry.message || entry.main));
}

bool ClaudeChainIndex::proveLinear(JsonlReader& reader, const std::function<bool()>& cancelled) {
    auto& state = linearBuild_;
    if (!state.phase) {
        state = {}; state.phase = 1;
        // A Bloom filter supplies only exact negative evidence. A positive
        // result always searches the already-observed prefix for equality.
        // Saturation can increase work but cannot hide a UUID revision.
        const auto wordLimit = std::max<size_t>(8, budget_ / (2 * sizeof(uint64_t)));
        size_t words = 8; while (words <= wordLimit / 2) words *= 2;
        if (!pi_ || piVersion_ != 1) state.bloom.assign(words, 0);
        std::vector<CachedEntry>().swap(checkpoints_);
    }
    auto bits = [&](const std::string& id, bool insert) {
        if (state.bloom.empty()) return false;
        const auto mask = state.bloom.size() * 64 - 1;
        uint64_t hash = identityHash(id); bool present = true;
        for (unsigned i = 0; i < 7; ++i) {
            // Independent mixed positions keep sequential synthetic IDs from
            // concentrating in adjacent bits. Collisions never imply equality.
            hash += 0x9e3779b97f4a7c15ULL;
            auto mixed = hash; mixed = (mixed ^ (mixed >> 30)) * 0xbf58476d1ce4e5b9ULL;
            mixed = (mixed ^ (mixed >> 27)) * 0x94d049bb133111ebULL; mixed ^= mixed >> 31;
            const auto bit = mixed & mask, value = uint64_t(1) << (bit & 63);
            present = present && (state.bloom[bit / 64] & value);
            if (insert) state.bloom[bit / 64] |= value;
        }
        return present;
    };
    auto accept = [&] {
        const auto& value = *state.candidate;
        bits(value.id, true);
        state.authored = state.authored || value.message;
        if (value.boundary) { state.boundaries = true; state.segmentMain = false; }
        if (value.message) state.segmentMain = value.main;
        // A publication that stopped before a compaction tail excluded this
        // older node; including it now is an append only if no previously
        // published metadata follows it (checked by the metadata branch).
        if (!pi_ && tail_ && value.start > tail_->start && value.start < publishedEnd_ && (!value.message || value.main)) state.inserted = true;
        if (!state.previous) state.root = value.start;
        state.previous = state.candidate; state.position = value.end; state.linked = false;
    };
    // Phases: 1 order/link proof, 2 duplicate UUID, 6 earlier logical
    // parent, 3 ordinal checkpoints; 4 proven, 5 not linear.
    while (state.phase != 4 && state.phase != 5) {
        checkCancelled(cancelled);
        if (state.phase == 1) {
            if (state.position >= position_) {
                // Parent-only leaf selection ends each compaction segment at
                // its own terminal. The last node is the selected terminal
                // only if the final segment's latest message is main;
                // otherwise the exact lazy evaluator must choose.
                if (state.boundaries && state.authored && !state.segmentMain) { state.phase = 5; break; }
                linearAuthored_ = state.authored;
                state.phase = 3; state.position = 0; state.physical = 0; state.selected = 0;
                const auto capacity = std::max<size_t>(1, std::min<size_t>(4096, budget_ / (4 * sizeof(CachedEntry))));
                state.stride = std::max<uint64_t>(1, (physicalCount_ + capacity - 1) / capacity);
                std::vector<uint64_t>().swap(state.bloom); checkpoints_.reserve(capacity); continue;
            }
            const auto page = reader.page(state.position, true, 1);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            const auto& record = page.records.front();
            state.candidate = decode(record, pi_ && piVersion_ == 1 && state.previous ? state.previous->start : absent);
            if (!state.candidate->node) {
                if (!state.candidate->message && state.inserted && record.start < publishedEnd_) state.reordered = true;
                state.position = record.end; continue;
            }
            if (state.candidate->boundary && !state.linked) {
                // Still linear only if the effective parent is the previous
                // node: named by logicalParentUuid, or the positional
                // fallback because the logical parent is not earlier.
                const auto& logical = state.candidate->logicalParent;
                const bool named = state.previous && logical == state.previous->id;
                if (!named && !logical.empty() && state.previous && bits(logical, false)) {
                    lookup_ = {logical, state.candidate->start, true}; state.phase = 6; continue;
                }
                if (!named && state.previous && state.previous->sidechain) { state.phase = 5; break; }
                state.linked = true;
            } else if (!state.candidate->boundary && state.candidate->parent != (state.previous ? state.previous->id : "")) {
                state.phase = 5; break;
            }
            if (bits(state.candidate->id, false)) {
                lookup_ = {state.candidate->id, state.candidate->start, true}; state.phase = 2; continue;
            }
            accept();
        } else if (state.phase == 2) {
            if (latest(reader, state.candidate->id, cancelled)) { state.phase = 5; break; }
            accept(); state.phase = 1;
        } else if (state.phase == 6) {
            // An earlier logical parent other than the previous node is the
            // effective parent: this compaction is not a linear append.
            if (latest(reader, state.candidate->logicalParent, cancelled) || state.previous->sidechain) { state.phase = 5; break; }
            state.linked = true; state.phase = 1;
        } else if (state.phase == 3) {
            if (state.position >= position_) { state.phase = 4; break; }
            const auto page = reader.page(state.position, true, 100);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            for (const auto& record : page.records) {
                if (state.physical % state.stride == 0) checkpoints_.push_back({state.selected, record.start, record.end});
                if (selectedLinear(decode(record))) ++state.selected;
                ++state.physical; state.position = record.end;
            }
        }
    }
    if (state.phase == 5) { std::vector<uint64_t>().swap(state.bloom); std::vector<CachedEntry>().swap(checkpoints_); return false; }
    // A linear path never stops early. Defensive: a stopped path needs a
    // forward link or revision, which also makes the file non-linear.
    if (selectedCount_ && ((!tail_ && state.authored) || state.reordered || cutStart_ != absent))
        generation_ = std::string(pi_ ? "pi-chain:" : "claude-chain:") + randomID();
    selectedCount_ = state.selected; tail_ = (pi_ || state.authored) ? state.previous : std::nullopt;
    cutStart_ = absent; pathEnd_ = tail_ ? state.root : absent;
    linear_ = true; state = {}; lookup_ = {}; boundaryLookup_ = {}; buildingWindow_ = false;
    std::vector<CachedEntry>().swap(window_);
    return true;
}

ClaudeChainIndex::Entry ClaudeChainIndex::linearEntry(JsonlReader& reader, size_t ordinal,
        const std::function<bool()>& cancelled) {
    for (const auto& value : window_) if (value.ordinal == ordinal) return readEntry(reader, value.start, value.end);
    const auto capacity = std::max<size_t>(1, std::min<size_t>(300, budget_ / (4 * sizeof(CachedEntry))));
    const auto begin = ordinal / capacity * capacity, end = std::min<size_t>(selectedCount_, begin + capacity);
    if (!buildingWindow_ || windowBegin_ != begin || windowEnd_ != end) {
        const auto checkpoint = std::upper_bound(checkpoints_.begin(), checkpoints_.end(), begin,
            [](uint64_t value, const CachedEntry& candidate) { return value < candidate.ordinal; });
        const auto value = checkpoint == checkpoints_.begin() ? CachedEntry{} : *std::prev(checkpoint);
        linearPagePosition_ = value.start; linearPageOrdinal_ = value.ordinal;
        window_.clear(); window_.reserve(capacity); windowBegin_ = begin; windowEnd_ = end; buildingWindow_ = true;
    }
    while (linearPageOrdinal_ < end && linearPagePosition_ < position_) {
        checkCancelled(cancelled);
        const auto page = reader.page(linearPagePosition_, true, 100);
        if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
        for (const auto& record : page.records) {
            if (selectedLinear(decode(record))) {
                if (linearPageOrdinal_ >= begin && linearPageOrdinal_ < end) window_.push_back({linearPageOrdinal_, record.start, record.end});
                ++linearPageOrdinal_;
            }
            linearPagePosition_ = record.end;
            if (linearPageOrdinal_ >= end) break;
        }
    }
    buildingWindow_ = false;
    for (const auto& value : window_) if (value.ordinal == ordinal) return readEntry(reader, value.start, value.end);
    throw std::runtime_error("claudeIndexUnproven");
}

void ClaudeChainIndex::rebuildLazy(JsonlReader& reader, const std::function<bool()>& cancelled) {
    // Each state owns its loop cursor before any cancellable source lookup.
    // A worker read slice therefore resumes graph proof rather than replaying
    // an ever-growing prefix until its deadline expires.
    auto& state = build_;
    if (!state.phase) {
        state = {}; state.phase = 1; state.scan = position_; state.oldTail = tail_;
        state.oldCount = selectedCount_; state.oldTailFound = !tail_;
    }
    while (state.phase != 10) {
        checkCancelled(cancelled);
        if (state.phase == 1) {
            if (!state.scan) {
                if (!pi_ && !state.bestTerminal && state.authored) throw std::runtime_error("claudeIndexUnproven");
                state.current = state.bestTerminal; state.count = pi_ ? (physicalCount_ ? 1 : 0) : metadataCount_;
                state.steps = 0; state.phase = 8; continue;
            }
            const auto page = reader.page(state.scan, false, 1);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            const auto& record = page.records.front();
            state.candidate = readEntry(reader, record.start, record.end);
            if (!state.candidate->node) { state.scan = record.start; continue; }
            state.leaf = state.candidate; state.steps = 0;
            state.phase = pi_ ? 3 : 2;
        } else if (state.phase == 2) {
            if (state.leaf && !state.leaf->message) {
                if (state.steps >= physicalCount_) { state.leaf.reset(); continue; }
                auto next = parent(reader, *state.leaf, cancelled);
                ++state.steps; state.leaf = std::move(next); continue;
            }
            const auto& leaf = state.leaf;
            const bool better = leaf && (!state.bestLeaf || (leaf->main && !state.bestLeaf->main) ||
                (leaf->main == state.bestLeaf->main && (leaf->start > state.bestLeaf->start ||
                (leaf->start == state.bestLeaf->start && state.candidate->start > state.bestTerminal->start))));
            // With no selected leaf, current authored UUIDs still require
            // proof: an all-cycle graph must not become an empty transcript.
            if (!better && state.bestLeaf) { state.scan = state.candidate->start; state.phase = 1; continue; }
            state.phase = 3;
        } else if (state.phase == 3) {
            const auto current = latest(reader, state.candidate->id, cancelled);
            const bool newest = current && current->start == state.candidate->start;
            if (pi_) {
                if (!newest) throw std::runtime_error("piDuplicateEntryID");
                if (!state.bestTerminal) state.bestTerminal = state.candidate;
                state.phase = 6; continue;
            }
            if (newest && state.candidate->message) state.authored = true;
            if (!newest || !state.leaf) { state.scan = state.candidate->start; state.phase = 1; continue; }
            state.childScan = 0; state.phase = 4;
        } else if (state.phase == 4) {
            if (state.childScan >= position_) {
                state.bestLeaf = state.leaf; state.bestTerminal = state.candidate;
                state.scan = state.candidate->start; state.phase = 1; continue;
            }
            const auto page = reader.page(state.childScan, true, 100);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            bool possibleChild = false;
            for (const auto& record : page.records) {
                const auto child = decode(record);
                if (child.node && child.parent == state.candidate->id) {
                    state.child = child; state.phase = 5; possibleChild = true; break;
                }
                state.childScan = record.end;
            }
            if (!possibleChild) continue;
        } else if (state.phase == 5) {
            const auto child = latest(reader, state.child->id, cancelled);
            if (child && child->start == state.child->start) {
                state.scan = state.candidate->start; state.phase = 1;
            } else { state.childScan = state.child->end; state.phase = 4; }
        } else if (state.phase == 6) {
            // Pi's immutable-entry schema requires every persisted parent to
            // exist earlier, even on a branch other than the selected tail.
            parent(reader, *state.candidate, cancelled);
            state.scan = state.candidate->start; state.phase = 1;
        } else if (state.phase == 8) {
            if (!state.current) {
                // A monotone selection that newly admits nodes before
                // publishedEnd_ (a compaction tail deferred until its summary
                // arrived) extends the published one only if no published
                // metadata follows the earliest such node.
                if (state.deferred != absent && state.oldCount && state.prefix && state.oldTailFound) {
                    if (state.monotone) { state.metadataScan = state.deferred; state.phase = 11; continue; }
                    state.prefix = false;
                }
                state.phase = 10; continue;
            }
            if (state.steps >= physicalCount_) throw std::runtime_error(pi_ ? "piChainUnproven" : "claudeIndexUnproven");
            const auto& current = *state.current;
            if (state.oldTail && current.start == state.oldTail->start) state.oldTailFound = true;
            else if (!state.oldTailFound && state.oldTail && current.start < publishedEnd_) {
                if (!pi_ && current.start > state.oldTail->start) state.deferred = std::min(state.deferred, current.start);
                else state.prefix = false;
            } else if (!pi_ && !state.oldTail && current.start < publishedEnd_) state.deferred = std::min(state.deferred, current.start);
            if (pi_ || !current.message || current.main) ++state.count;
            state.maximum = std::max(state.maximum, current.start);
            state.minimum = std::min(state.minimum, current.start); state.last = current.start;
            if (state.oldTailFound && state.oldTail && current.start >= publishedEnd_) state.prefix = false;
            ++state.steps; state.phase = 9;
        } else if (state.phase == 9) {
            // Selected ancestry continues through compaction boundaries,
            // under chain()'s stop rule.
            const auto& current = *state.current;
            // Only a boundary on the published path can change it unseen.
            auto next = effectiveParent(reader, current, cancelled,
                state.oldTail && state.oldTailFound ? &state.revised : nullptr);
            state.crossed = state.crossed || (!pi_ && current.boundary && current.parent.empty());
            if (state.crossed && next && next->start >= state.minimum) { next.reset(); state.cut = current.start; }
            if (next && next->start >= current.start) state.monotone = false;
            state.current = std::move(next); state.phase = 8;
        } else if (state.phase == 11) {
            if (state.metadataScan >= publishedEnd_) { state.phase = 10; continue; }
            const auto page = reader.page(state.metadataScan, true, 100);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            for (const auto& record : page.records) {
                const auto value = record.start < publishedEnd_ ? decode(record) : Entry();
                if (record.start >= publishedEnd_ || (!value.node && !value.message)) {
                    if (record.start < publishedEnd_) state.prefix = false;
                    state.metadataScan = publishedEnd_; break;
                }
                state.metadataScan = record.end;
            }
        }
    }
    // Below the old tail, the stop rule and revisions change the path only by
    // where it ends, or by a published boundary's choice.
    if (!pi_ && state.oldTail && (state.revised || state.last != pathEnd_)) state.prefix = false;
    if (state.oldCount && (!state.prefix || !state.oldTailFound || state.count < state.oldCount))
        generation_ = std::string(pi_ ? "pi-chain:" : "claude-chain:") + randomID();
    tail_ = state.bestTerminal; selectedCount_ = state.count; monotonePath_ = state.monotone; linear_ = false;
    pathMaximum_ = state.maximum; cutStart_ = state.cut; pathEnd_ = state.last; state = {}; lookup_ = {}; boundaryLookup_ = {};
    std::vector<CachedEntry>().swap(window_); buildingWindow_ = false; maximumActive_ = false; resetCursor();
}

uint64_t ClaudeChainIndex::ancestryMaximum(JsonlReader& reader, const std::optional<Entry>& node,
        const std::function<bool()>& cancelled) {
    if (!node) return absent;
    if (monotonePath_) return node->start;
    if (!maximumActive_) { maximumActive_ = true; maximumCurrent_ = node; maximumValue_ = 0; maximumSteps_ = 0; }
    while (maximumCurrent_) {
        if (maximumSteps_ >= physicalCount_) throw std::runtime_error("claudeIndexUnproven");
        const auto next = displayParent(reader, *maximumCurrent_, cancelled);
        maximumValue_ = std::max(maximumValue_, maximumCurrent_->start); ++maximumSteps_;
        maximumCurrent_ = next;
    }
    maximumActive_ = false; return maximumValue_;
}

void ClaudeChainIndex::resetCursor() {
    cursor_ = {}; cursor_.remaining = selectedCount_; cursor_.metadataEnd = position_; cursor_.node = tail_;
    maximumActive_ = false; maximumCurrent_.reset(); lookup_.active = false; boundaryLookup_ = {};
}

std::optional<ClaudeChainIndex::CachedEntry> ClaudeChainIndex::nextLazy(JsonlReader& reader,
        const std::function<bool()>& cancelled) {
    while (cursor_.remaining) {
        checkCancelled(cancelled);
        if (pi_) {
            if (cursor_.node) {
                const auto value = *cursor_.node; cursor_.node = parent(reader, value, cancelled);
                return CachedEntry{--cursor_.remaining, value.start, value.end};
            }
            const auto header = reader.firstRecord();
            return CachedEntry{--cursor_.remaining, header->start, header->end};
        }
        if (cursor_.emitNode) {
            const auto value = *cursor_.node; cursor_.node = displayParent(reader, value, cancelled);
            cursor_.emitNode = false; cursor_.thresholdKnown = false;
            if (!value.message || value.main) return CachedEntry{--cursor_.remaining, value.start, value.end};
            continue;
        }
        // A full ancestry walk on a non-monotone path: recomputing it for
        // each metadata record, or after a yielded page read, could consume
        // every worker slice without progress.
        if (!cursor_.thresholdKnown) {
            cursor_.threshold = ancestryMaximum(reader, cursor_.node, cancelled); cursor_.thresholdKnown = true;
        }
        const auto threshold = cursor_.threshold;
        while (cursor_.metadataEnd && (threshold == absent || cursor_.metadataEnd > threshold)) {
            const auto page = reader.page(cursor_.metadataEnd, false, 1);
            if (page.records.empty()) throw std::runtime_error("claudeIndexNoProgress");
            const auto& record = page.records.front();
            if (threshold != absent && record.start <= threshold) break;
            cursor_.metadataEnd = record.start;
            const auto value = decode(record);
            if (!value.node && !value.message) return CachedEntry{--cursor_.remaining, value.start, value.end};
        }
        if (cursor_.node) cursor_.emitNode = true;
        else if (cursor_.remaining) throw std::runtime_error("claudeIndexUnproven");
    }
    return std::nullopt;
}

ClaudeChainIndex::Entry ClaudeChainIndex::entry(JsonlReader& reader, size_t ordinal,
        const std::function<bool()>& cancelled) {
    if (ordinal >= selectedCount_ || dirty_) throw std::out_of_range("claudeIndexOrdinal");
    if (linear_) return linearEntry(reader, ordinal, cancelled);
    if (!lazy_) {
        const auto& value = entries_.at(selected_.at(ordinal));
        auto result = readEntry(reader, value.start, value.end);
        // A boundary stores its effective parent. Validate the logical link
        // when that chose it; a positional fallback has no stored identity to
        // compare, but identity and all record flags are still checked.
        const bool boundary = value.flags & boundaryFlag;
        const auto& storedParent = boundary ? result.logicalParent : result.parent;
        if (identityHash(result.id) != value.hash || recordFlags(result) != (value.flags & persistentFlags) ||
            (value.parent != absent && (!boundary || (value.flags & logicalFlag)) &&
             identityHash(storedParent) != entries_[value.parent].hash))
            throw std::runtime_error("sourceChanged");
        return result;
    }
    for (const auto& value : window_) if (value.ordinal == ordinal) return readEntry(reader, value.start, value.end);
    // A page of offsets is cached, never its message bodies or identity strings.
    // Neighbouring older pages continue the same ancestry walk.
    const auto capacity = std::max<size_t>(1, std::min<size_t>(300, budget_ > sizeof(*this) ? (budget_ - sizeof(*this)) / (2 * sizeof(CachedEntry)) : 1));
    const auto begin = ordinal / capacity * capacity, end = std::min<size_t>(selectedCount_, begin + capacity);
    if (!buildingWindow_ || windowBegin_ != begin || windowEnd_ != end) {
        if (cursor_.remaining < end) resetCursor();
        window_.clear(); window_.reserve(capacity);
        windowBegin_ = begin; windowEnd_ = end; buildingWindow_ = true;
    }
    while (cursor_.remaining > begin) {
        const auto value = nextLazy(reader, cancelled);
        if (!value) break;
        if (value->ordinal < end) window_.push_back(*value);
    }
    buildingWindow_ = false;
    for (const auto& value : window_) if (value.ordinal == ordinal) return readEntry(reader, value.start, value.end);
    throw std::runtime_error("claudeIndexUnproven");
}

ClaudeChainCache::ClaudeChainCache(HistoryMetadataBudget* budget) : budget_(budget) {
    if (budget_) budget_->registerFamily(this, [this] { return usedBytes(); });
}
ClaudeChainCache::~ClaudeChainCache() { if (budget_) budget_->unregisterFamily(this); }
size_t ClaudeChainCache::usedBytes() const {
    size_t result = sizeof(*this);
    for (const auto& item : indexes_) result += item.first.capacity() + item.second.index.bytes() + sizeof(Cached) + 64;
    for (const auto* pins : {&pinned_, &transientPins_, &pendingPins_})
        for (const auto& pin : *pins) result += pin.capacity() + sizeof(std::string) + 48;
    return result;
}

ClaudeChainIndex& ClaudeChainCache::get(const std::string& key) {
    auto found = indexes_.find(key);
    if (found == indexes_.end()) {
        if (indexes_.size() >= 24) {
            auto victim = indexes_.end();
            for (auto candidate = indexes_.begin(); candidate != indexes_.end(); ++candidate)
                if (!retained(candidate->first) && (victim == indexes_.end() || candidate->second.touched < victim->second.touched)) victim = candidate;
            if (victim != indexes_.end()) indexes_.erase(victim);
        }
        found = indexes_.try_emplace(key).first;
    }
    // A yielded cold scan owns its admitted prefix until the worker records
    // its pending pins. Other clients must not silently evict that progress.
    transientPins_.insert(key);
    found->second.touched = ++clock_;
    return found->second.index;
}

void ClaudeChainCache::enforce(const std::string& key) {
    while (true) {
        const auto allowance = budget_ ? budget_->allowance(this, HistoryMetadataBudget::totalLimit) : HistoryMetadataBudget::totalLimit;
        if (usedBytes() <= allowance) return;
        auto victim = indexes_.end();
        for (auto candidate = indexes_.begin(); candidate != indexes_.end(); ++candidate)
            if (candidate->first != key && !retained(candidate->first) &&
                (victim == indexes_.end() || candidate->second.touched < victim->second.touched)) victim = candidate;
        if (victim == indexes_.end()) {
            throw std::runtime_error("claudeIndexCapacity");
        }
        indexes_.erase(victim);
    }
}

size_t ClaudeChainCache::budgetFor(const std::string& key) {
    while (true) {
        const auto found = indexes_.find(key);
        const auto otherBytes = usedBytes() - (found == indexes_.end() ? 0 : found->second.index.bytes());
        const auto available = otherBytes >= 256 * 1024 * 1024 ? 0 : 256 * 1024 * 1024 - otherBytes;
        const auto familyAllowance = budget_ ? budget_->allowance(this, HistoryMetadataBudget::totalLimit) : HistoryMetadataBudget::totalLimit;
        const auto sharedAvailable = std::min(available, otherBytes >= familyAllowance ? 0 : familyAllowance - otherBytes);
        if (sharedAvailable >= HistoryMetadataBudget::indexLimit) return HistoryMetadataBudget::indexLimit;
        auto victim = indexes_.end();
        for (auto candidate = indexes_.begin(); candidate != indexes_.end(); ++candidate)
            if (candidate->first != key && !retained(candidate->first) &&
                (victim == indexes_.end() || candidate->second.touched < victim->second.touched)) victim = candidate;
        if (victim == indexes_.end()) return sharedAvailable;
        indexes_.erase(victim);
    }
}
}
