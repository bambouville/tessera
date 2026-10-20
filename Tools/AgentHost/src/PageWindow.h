#pragma once
#include "JsonlReader.h"
#include <algorithm>
#include <chrono>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace tessera {
struct WindowAnchor {
    std::string source, providerCursor, recordID;
    uint64_t position = 0, fileWitness = 0;
    bool forward = false, terminal = false;
};
struct WindowRecordAnchors {
    WindowAnchor before, after, reread;
};
// Describes a slice of retained records, not another copy of their bodies.
// Only the server mints the replacement IDs and recovery boundaries.
struct WindowPartition {
    std::string original, id, before, after;
    size_t offset = 0, count = 0;
    bool hasOlder = false, hasNewer = false;
};
// One authenticated client's one thread. Provider adapters own anchors inside
// these immutable pages; only an ACK changes revision coverage. The reader
// must reserve staging before doing I/O and publish a complete bounded page.
struct WindowSegment {
    std::string id, source, before, after;
    // Provider-local read anchors. Never sent directly to an app.
    std::string providerBefore, providerAfter, rereadCursor;
    uint64_t beforeOrder = 0, afterOrder = 0;
    bool hasOlder = false, hasNewer = false;
    std::vector<PositionedRecord> records;
    std::vector<WindowRecordAnchors> anchors;
    static size_t recordBytes(const PositionedRecord& record) {
        return record.value.json.size() + record.value.providerID.size() + record.value.parentID.size() + 256;
    }
    static size_t anchorBytes(const WindowRecordAnchors& item) {
        size_t count = 0;
        for (const auto* anchor : {&item.before, &item.after, &item.reread})
            count += anchor->source.size() + anchor->providerCursor.size() + anchor->recordID.size() + 64;
        return count;
    }
    size_t bytes() const {
        size_t count = 1024 + id.size() + source.size() + before.size() + after.size() +
            providerBefore.size() + providerAfter.size() + rereadCursor.size();
        for (const auto& record : records) count += recordBytes(record);
        for (const auto& item : anchors) count += anchorBytes(item);
        return count;
    }
};

class PageWindow {
public:
    enum class Kind { Bootstrap, Before, After, Head, Revisions };
    using Segment = std::shared_ptr<const WindowSegment>;
    using Clock = std::chrono::steady_clock;
    static constexpr size_t pageLimit = 262144;
    // Advertised as hello `maxWindowSegments` with `window.capacity.v1`.
    // Clients without that capability keep the legacy four-segment viewport.
    static constexpr size_t maximumViewportSegments = 64;
    static constexpr size_t viewportLimit = maximumViewportSegments * pageLimit;
    // The viewport plus a detached head.
    static constexpr size_t retainedLimit = (maximumViewportSegments + 1) * pageLimit;
    // Clients reject a revisions lane with more partitions. A sweep patches at
    // most this many distinct segments (plus a possible detached-head alias):
    // the legacy five-segment retention that bound was sized for.
    static constexpr size_t maximumPartitions = 20;
    static constexpr size_t maximumRevisedSegments = 4;
    // Window slots per service (all clients) and per client connection.
    static constexpr size_t maximumServiceWindows = 24, maximumClientWindows = 4;
    // Service-wide budget over every window of one service: committed pages
    // plus staged, unacknowledged pages and revision patches (footprint()).
    // History growth (bootstrap/before/after) is refused with windowCapacity
    // before any I/O unless one more full page fits under this limit.
    static constexpr size_t serviceGrowthLimit = 64 * 1024 * 1024;
    // Live head refreshes (appends and revision sweeps) may also use this
    // headroom, so they keep committing after history growth is refused. It
    // fits a detached head plus one in-flight refresh page per window slot.
    // Accumulated refresh growth (a head replacing a smaller page, growing
    // revisions) can still use it up; refreshes then fail with windowCapacity
    // until windows are released, evicted or disconnected.
    static constexpr size_t refreshHeadroom = 2 * maximumServiceWindows * pageLimit;
    static constexpr size_t serviceRefreshLimit = serviceGrowthLimit + refreshHeadroom;
    uint64_t version() const { return version_; }
    const std::vector<std::string>& viewport() const { return viewport_; }
    const std::string& head() const { return head_; }
    bool pending() const { return !transaction_.empty(); }
    const std::vector<WindowPartition>& partitions() const { return partitions_; }
    size_t retainedBytes() const { return retainedBytes_; }
    // The staged page, or staged revision patches plus the most their ACK can
    // add by rewriting or splitting retained pages. An ACK only keeps or drops
    // staged data, so it never raises footprint() above the admitted total.
    size_t pendingBytes() const { return pendingBytes_; }
    size_t footprint() const { return retainedBytes_ + pendingBytes_; }
    std::vector<Segment> coverage() const {
        std::vector<Segment> value;
        for (const auto& item : retained_) value.push_back(item.second);
        return value;
    }
    Segment find(const std::string& id) const {
        const auto found = retained_.find(id);
        if (found == retained_.end()) throw std::runtime_error("segmentExpired");
        return found->second;
    }
    // `serviceBytes` is footprint() summed over every window of this service,
    // including this one. Checked before any I/O; the admitted room bounds
    // what this transaction may stage.
    static bool fits(size_t serviceBytes, size_t limit) { return serviceBytes <= limit && limit - serviceBytes >= pageLimit; }
    void reserve(const std::string& transaction, uint64_t expectedVersion, Kind kind = Kind::Before, size_t serviceBytes = 0) {
        const bool reset = kind == Kind::Bootstrap;
        if (pending()) throw std::runtime_error("windowBusy");
        if (std::any_of(acknowledgments_.begin(), acknowledgments_.end(), [&](const auto& ack) { return ack.transaction == transaction; }))
            throw std::runtime_error("windowTransactionReused");
        if (transaction.empty() || transaction.size() > 128 ||
            (expectedVersion != version_ && !(reset && expectedVersion == 0)))
            throw std::runtime_error("windowStale");
        if (retainedBytes() > retainedLimit) throw std::runtime_error("windowCapacity");
        serviceBytes = std::max(serviceBytes, footprint());
        const bool refresh = kind == Kind::Head || kind == Kind::Revisions;
        // A bootstrap ACK replaces all of this window's committed pages: its
        // result must fit the growth limit, while staging overlaps the old pages.
        const bool replacing = reset && !retained_.empty();
        if (!(refresh ? fits(serviceBytes, serviceRefreshLimit) : replacing ?
                fits(serviceBytes - retainedBytes_, serviceGrowthLimit) && fits(serviceBytes, serviceRefreshLimit) :
                fits(serviceBytes, serviceGrowthLimit)))
            throw std::runtime_error("windowCapacity");
        transaction_ = transaction; resetting_ = reset; kind_ = kind; deadline_ = Clock::now() + std::chrono::seconds(30);
        room_ = (refresh || replacing ? serviceRefreshLimit : serviceGrowthLimit) - serviceBytes;
    }
    void stage(Segment segment) {
        if (!pending() || kind_ == Kind::Revisions || staged_ || !segment || segment->id.empty() || segment->source.empty() ||
            segment->before.empty() || segment->after.empty() || segment->id.size() > 128 || segment->source.size() > 512 ||
            segment->before.size() > 128 || segment->after.size() > 128 || segment->providerBefore.size() > 2048 ||
            segment->providerAfter.size() > 2048 || segment->rereadCursor.size() > 2048 ||
            segment->records.size() > 100 || (!segment->anchors.empty() && segment->anchors.size() != segment->records.size()) || segment->bytes() > pageLimit)
            throw std::runtime_error("invalidSegment");
        std::set<std::string> nativeIDs;
        const bool native = segment->source.rfind("codex-appserver:", 0) == 0 || segment->source.rfind("opencode-sqlite:", 0) == 0;
        uint64_t previous = 0; bool havePrevious = false;
        for (const auto& record : segment->records) {
            if (!record.revision || (havePrevious && record.start <= previous) ||
                record.value.providerID.size() > 256 || (native && (record.value.providerID.empty() || !nativeIDs.insert(record.value.providerID).second)))
                throw std::runtime_error("invalidSegmentRecord");
            previous = record.start; havePrevious = true;
        }
        if (retained_.count(segment->id) || (!resetting_ && !retained_.empty() && retained_.begin()->second->source != segment->source))
            throw std::runtime_error("segmentSourceChanged");
        // A caller may still hold a mutable alias to its construction object.
        // Retained segments must not change after budget/identity validation.
        staged_ = std::make_shared<const WindowSegment>(*segment);
        pendingBytes_ = staged_->bytes();
    }
    void stageRevisions(const std::vector<PositionedRecord>& patches, const std::function<std::string()>& newID = {}) {
        if (!pending() || kind_ != Kind::Revisions || revisionsStaged_ || patches.size() > 100) throw std::runtime_error("invalidRevisionTransaction");
        if (!patches.empty() && (retained_.empty() ||
            (retained_.begin()->second->source.rfind("codex-appserver:", 0) != 0 && retained_.begin()->second->source.rfind("codex-history:", 0) != 0 &&
             retained_.begin()->second->source.rfind("opencode-sqlite:", 0) != 0)))
            throw std::runtime_error("sourceDoesNotSupportRevisions");
        std::set<uint64_t> seen;
        size_t bytes = 1024;
        for (const auto& patch : patches) {
            if (!seen.insert(patch.start).second) throw std::runtime_error("duplicateRevision");
            bool found = false, sameProviderID = false;
            for (const auto& entry : retained_) for (const auto& old : entry.second->records) {
                if (old.value.providerID != patch.value.providerID) continue;
                sameProviderID = true;
                if (old.start != patch.start) continue;
                if (patch.revision < old.revision ||
                    (patch.revision == old.revision && patch.value.json != old.value.json)) throw std::runtime_error("revisionChangedOrder");
                found = true;
            }
            if (!found && sameProviderID) throw std::runtime_error("revisionChangedOrder");
            if (!found) throw std::runtime_error("revisionOutsideCoverage");
            bytes += patch.value.json.size() + patch.value.providerID.size() + patch.value.parentID.size() + 256;
        }
        if (bytes > pageLimit - 16384) throw std::runtime_error("windowCapacity");
        std::vector<WindowPartition> partitions;
        // What acknowledge() can add: it rewrites every retained copy of a
        // patched record (a detached head may repeat a viewport record) and
        // repeats per-page metadata in split parts. Mirrors its construction.
        size_t growth = 0;
        for (const auto& entry : retained_) {
            const auto& original = *entry.second;
            auto replacement = [&](size_t index) -> const PositionedRecord& {
                const auto& old = original.records[index];
                for (const auto& patch : patches)
                    if (old.start == patch.start && old.value.providerID == patch.value.providerID) return patch;
                return old;
            };
            // Include conservative Swift/wire encoding expansion and record
            // envelopes, not just the smaller native normalized body size.
            auto cost = [&](size_t index) {
                const auto& row = replacement(index);
                const auto wire = row.value.json.size() * 2 + (row.value.providerID.size() + original.source.size() +
                    row.value.sourceType.size() + row.value.disposition.size()) * 6 + 512;
                size_t native = row.value.json.size() + row.value.providerID.size() + row.value.parentID.size() + 256;
                if (!original.anchors.empty()) for (const auto* anchor : {&original.anchors[index].before,
                        &original.anchors[index].after, &original.anchors[index].reread})
                    native += anchor->source.size() + anchor->providerCursor.size() + anchor->recordID.size() + 64;
                return std::max(wire, native);
            };
            // Includes three maximum provider cursors even when the original
            // metadata was empty: a split fills them from per-record anchors.
            constexpr size_t base = 8192;
            size_t total = base; bool changed = false;
            for (size_t index = 0; index < original.records.size(); ++index) {
                total += cost(index); changed |= &replacement(index) != &original.records[index];
            }
            if (!changed) continue;
            if (total <= pageLimit - 8192) {
                size_t revised = original.bytes();
                for (size_t index = 0; index < original.records.size(); ++index)
                    revised = revised - WindowSegment::recordBytes(original.records[index]) + WindowSegment::recordBytes(replacement(index));
                if (revised > original.bytes()) growth += revised - original.bytes();
                continue;
            }
            if (!newID || original.anchors.size() != original.records.size()) throw std::runtime_error("revisionAnchorMissing");
            size_t offset = 0, revised = 0;
            while (offset < original.records.size()) {
                size_t count = 0, size = base;
                while (offset + count < original.records.size() && size + cost(offset + count) <= pageLimit - 8192) {
                    size += cost(offset + count); ++count;
                }
                if (!count || partitions.size() >= maximumPartitions) throw std::runtime_error("windowItemCapacity");
                WindowPartition part{original.id, newID(), offset ? newID() : original.before,
                    offset + count == original.records.size() ? original.after : newID(), offset, count,
                    original.hasOlder || offset > 0, original.hasNewer || offset + count < original.records.size()};
                if (part.id.empty() || part.id.size() > 128 || part.before.empty() || part.before.size() > 128 ||
                    part.after.empty() || part.after.size() > 128 || retained_.count(part.id) ||
                    std::any_of(partitions.begin(), partitions.end(), [&](const auto& old) { return old.id == part.id; }))
                    throw std::runtime_error("invalidPartitionIdentity");
                bytes += part.original.size() + part.id.size() + part.before.size() + part.after.size() + 256;
                if (bytes > pageLimit) throw std::runtime_error("windowCapacity");
                revised += 1024 + part.id.size() + original.source.size() + part.before.size() + part.after.size() +
                    original.anchors[offset].before.providerCursor.size() + original.anchors[offset + count - 1].after.providerCursor.size() +
                    original.anchors[offset].reread.providerCursor.size();
                for (size_t index = offset; index < offset + count; ++index)
                    revised += WindowSegment::recordBytes(replacement(index)) + WindowSegment::anchorBytes(original.anchors[index]);
                partitions.push_back(std::move(part)); offset += count;
            }
            if (revised > original.bytes()) growth += revised - original.bytes();
        }
        // Patch copies stay pending until the ACK; the room was admitted by
        // reserve() before any provider I/O.
        if (bytes + growth > room_) throw std::runtime_error("windowCapacity");
        patches_ = patches; partitions_ = std::move(partitions); revisionsStaged_ = true;
        pendingBytes_ = bytes + growth;
    }
    // Near the service ceiling a revision sweep defers its newest patches to
    // a later slice instead of refusing the live refresh. Returns how many
    // leading patches were staged; a lone patch that cannot fit still throws.
    size_t stageRevisionPrefix(const std::vector<PositionedRecord>& patches, const std::function<std::string()>& newID = {}) {
        for (auto count = patches.size();; count /= 2) {
            try { stageRevisions({patches.begin(), patches.begin() + count}, newID); return count; }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "windowCapacity" || count <= 1) throw; }
        }
    }
    // Atomic after validation: invalid/lost ACK cannot discard the previous
    // viewport, expire its pinned cursors or reduce its revision coverage.
    void acknowledge(const std::string& transaction, uint64_t nextVersion,
                     const std::vector<std::string>& viewport, const std::string& head) {
        for (const auto& previous : acknowledgments_) if (previous.transaction == transaction) {
            if (previous.version == nextVersion && previous.viewport == viewport && previous.head == head) return;
            throw std::runtime_error("windowAckConflict");
        }
        if (transaction != transaction_ || (!staged_ && !revisionsStaged_) || version_ == UINT64_MAX || nextVersion != (resetting_ ? 1 : version_ + 1) ||
            viewport.empty() || head.empty() || Clock::now() >= deadline_)
            throw std::runtime_error("windowAckStale");
        if (viewport.size() > maximumViewportSegments) throw std::runtime_error("windowCapacity");
        std::vector<std::vector<std::string>> candidates;
        if (kind_ == Kind::Bootstrap) {
            if (head != staged_->id) throw std::runtime_error("windowAckHead");
            candidates.push_back({staged_->id});
        } else if (kind_ == Kind::Before || kind_ == Kind::After) {
            if (head != head_) throw std::runtime_error("windowAckHead");
            auto candidate = viewport_;
            if (kind_ == Kind::Before) candidate.insert(candidate.begin(), staged_->id);
            else candidate.push_back(staged_->id);
            if (std::find(viewport.begin(), viewport.end(), staged_->id) == viewport.end()) throw std::runtime_error("windowAckDroppedIncoming");
            candidates.push_back(std::move(candidate));
        } else if (kind_ == Kind::Head) {
            if (head != staged_->id) throw std::runtime_error("windowAckHead");
            candidates.push_back(viewport_); candidates.push_back({staged_->id});
            if (!viewport_.empty() && viewport_.back() == head_) {
                const auto old = find(head_);
                if (!old->records.empty() && !staged_->records.empty() && old->records.front().start == staged_->records.front().start &&
                    old->records.front().value.providerID == staged_->records.front().value.providerID) {
                    auto replacement = viewport_; replacement.back() = staged_->id; candidates.push_back(std::move(replacement));
                }
            }
        } else {
            auto revisedHead = head_;
            for (const auto& part : partitions_) if (part.original == head_) revisedHead = part.id;
            if (head != revisedHead) throw std::runtime_error("windowAckRevisionRetention");
            std::vector<std::string> expanded;
            for (const auto& id : viewport_) {
                bool split = false;
                for (const auto& part : partitions_) if (part.original == id) { expanded.push_back(part.id); split = true; }
                if (!split) expanded.push_back(id);
            }
            candidates.push_back(std::move(expanded));
        }
        const bool contiguous = std::any_of(candidates.begin(), candidates.end(), [&](const auto& candidate) {
            return std::search(candidate.begin(), candidate.end(), viewport.begin(), viewport.end()) != candidate.end();
        });
        if (!contiguous) throw std::runtime_error("windowAckGap");
        std::map<std::string, Segment> admitted;
        size_t bytes = 0, records = 0;
        auto resolve = [&](const std::string& id) {
            if (staged_ && id == staged_->id) return staged_;
            if (resetting_) throw std::runtime_error("windowAckStale");
            const WindowPartition* partition = nullptr;
            for (const auto& part : partitions_) if (part.id == id) partition = &part;
            if (!partition && std::any_of(partitions_.begin(), partitions_.end(), [&](const auto& part) { return part.original == id; }))
                throw std::runtime_error("windowAckRevisionRetention");
            auto original = find(partition ? partition->original : id);
            auto patched = [&](const PositionedRecord& record) {
                return std::any_of(patches_.begin(), patches_.end(), [&](const auto& patch) {
                    return record.start == patch.start && record.value.providerID == patch.value.providerID;
                });
            };
            // Unpatched whole segments are immutable: share them rather than
            // copying up to the full retained window on every revision ACK.
            if (!revisionsStaged_ || patches_.empty() ||
                (!partition && std::none_of(original->records.begin(), original->records.end(), patched))) return original;
            auto revised = std::make_shared<WindowSegment>();
            if (partition) {
                revised->id = partition->id; revised->source = original->source;
                revised->before = partition->before; revised->after = partition->after;
                revised->hasOlder = partition->hasOlder; revised->hasNewer = partition->hasNewer;
                const auto offset = partition->offset, end = offset + partition->count;
                revised->records.assign(original->records.begin() + offset, original->records.begin() + end);
                revised->anchors.assign(original->anchors.begin() + offset, original->anchors.begin() + end);
                revised->beforeOrder = revised->records.front().start; revised->afterOrder = revised->records.back().end;
                revised->providerBefore = revised->anchors.front().before.providerCursor;
                revised->providerAfter = revised->anchors.back().after.providerCursor;
                revised->rereadCursor = revised->anchors.front().reread.providerCursor;
            } else *revised = *original;
            for (auto& record : revised->records) for (const auto& patch : patches_)
                if (record.start == patch.start && record.value.providerID == patch.value.providerID) record = patch;
            if (revised->bytes() > pageLimit) throw std::runtime_error("windowCapacity");
            return Segment(revised);
        };
        uint64_t previous = 0; bool havePrevious = false;
        for (const auto& id : viewport) {
            auto value = resolve(id);
            if (!admitted.emplace(id, value).second) throw std::runtime_error("windowAckDuplicateSegment");
            bytes += value->bytes(); records += value->records.size();
            if (!value->records.empty()) {
                if (havePrevious && value->records.front().start <= previous) throw std::runtime_error("windowAckOrder");
                previous = value->records.back().start; havePrevious = true;
            }
        }
        if (bytes > viewportLimit || records > maximumViewportSegments * 100) throw std::runtime_error("windowCapacity");
        auto newest = resolve(head);
        admitted.emplace(head, newest);
        retained_ = std::move(admitted); viewport_ = viewport; head_ = head;
        retainedBytes_ = 0;
        for (const auto& item : retained_) retainedBytes_ += item.second->bytes();
        version_ = nextVersion;
        if (resetting_) acknowledgments_.clear();
        acknowledgments_.push_back({transaction, head, nextVersion, viewport});
        if (acknowledgments_.size() > 8) acknowledgments_.erase(acknowledgments_.begin());
        cancel();
    }
    bool expire() {
        if (!pending() || Clock::now() < deadline_) return false;
        cancel(); return true;
    }
    void cancel() {
        staged_.reset(); transaction_.clear(); resetting_ = false; revisionsStaged_ = false; patches_.clear(); partitions_.clear();
        pendingBytes_ = 0; room_ = 0;
    }
private:
    struct Acknowledgment { std::string transaction, head; uint64_t version; std::vector<std::string> viewport; };
    uint64_t version_ = 0;
    std::map<std::string, Segment> retained_;
    std::vector<std::string> viewport_;
    std::string head_, transaction_;
    std::vector<Acknowledgment> acknowledgments_;
    std::vector<PositionedRecord> patches_;
    std::vector<WindowPartition> partitions_;
    Segment staged_;
    // Cached: retained_ changes only in acknowledge().
    size_t retainedBytes_ = 0, pendingBytes_ = 0, room_ = 0;
    Kind kind_ = Kind::Bootstrap;
    bool resetting_ = false, revisionsStaged_ = false;
    Clock::time_point deadline_{};
};
}
