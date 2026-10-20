#include "SourceValidation.h"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace tessera {
namespace {
uint64_t twice(uint64_t value) {
    return value > std::numeric_limits<uint64_t>::max() / 2 ? std::numeric_limits<uint64_t>::max() : value * 2;
}
}

void SourceValidation::changed() {
    // Continuations outlive index eviction. A new validator for the same inode
    // must never accidentally reuse a previous validator's numeric revision.
    static std::atomic<uint64_t> nextRevision{1};
    const auto revision = nextRevision.fetch_add(1, std::memory_order_relaxed);
    if (!revision || revision == std::numeric_limits<uint64_t>::max()) throw std::runtime_error("sourceChanged");
    revision_ = revision; baselinePresent_ = false;
}

void SourceValidation::begin(const Source& source, WallClock::time_point wallNow) {
    targetEnd_ = source.size; position_ = 0; digest_ = {};
    targetStamp_ = source.stamp;
    targetMtimeNanoseconds_ = source.mtimeNanoseconds;
    targetCtimeNanoseconds_ = source.ctimeNanoseconds;
    sweepStartWall_ = wallNow;
    growth_ = baselinePresent_ && source.size > baselineEnd_;
    active_ = true; verifying_ = false; compared_ = !baselinePresent_;
    ++cycle_;
}

SourceValidation::Result SourceValidation::progress() const {
    const auto complete = active_ ? (verifying_ ? targetEnd_ + position_ - (growth_ ? baselineEnd_ : 0) : position_)
        : completedWork_;
    const auto total = active_ ? twice(targetEnd_) - (growth_ ? baselineEnd_ : 0) : completedWork_;
    return {!active_ && baselinePresent_, revision_, baselineEnd_, complete,
            total, cycle_};
}

std::array<uint8_t, 32> SourceValidation::fingerprint() const {
    if (!baselinePresent_) throw std::runtime_error("readPending");
    return baseline_;
}

void SourceValidation::remember(uint64_t token, uint64_t cut) {
    if (!token) return;
    auto slot = std::find_if(leases_.begin(), leases_.end(), [&](const Lease& lease) { return lease.token == token; });
    if (slot == leases_.end()) slot = std::min_element(leases_.begin(), leases_.end(),
        [](const Lease& a, const Lease& b) { return a.touched < b.touched; });
    *slot = {token, revision_, cut, ++leaseClock_};
}

SourceValidation::Result SourceValidation::advance(const Source& source, const Read& read,
        size_t byteSlice, Clock::time_point now, uint64_t observationToken, uint64_t minimumEnd, bool refresh,
        WallClock::time_point wallNow) {
    if (!byteSlice) throw std::runtime_error("invalidRequest");
    if (identity_ != source.identity) {
        changed(); identity_ = source.identity; active_ = false;
    } else if ((active_ && source.size < targetEnd_) || (baselinePresent_ && source.size < baselineEnd_)) {
        changed(); active_ = false;
    }
    const bool changedInPlace = baselinePresent_ && source.size == observedSize_ && stamp_ != source.stamp;
    // A resumed job owns its observed cut through reduction/page assembly.
    // It and ordinary historical navigation may use the published baseline
    // while a separate head demand advances a candidate validation sweep.
    const auto lease = std::find_if(leases_.begin(), leases_.end(), [&](const Lease& value) {
        return observationToken && value.token == observationToken && value.revision == revision_;
    });
    if (baselinePresent_ && !changedInPlace && (!refresh || lease != leases_.end())) {
        auto result = progress(); result.ready = true;
        result.validatedEnd = lease != leases_.end() ? std::max(lease->cut, minimumEnd) : baselineEnd_;
        if (result.validatedEnd > baselineEnd_) throw std::runtime_error("sourceChanged");
        remember(observationToken, result.validatedEnd); return result;
    }
    if (!active_) {
        if (baselinePresent_ && observedSize_ == source.size && stamp_ == source.stamp &&
            (!baselineNeedsConfirmation_ || now < nextSweep_)) {
            // A baseline whose sweep began after the timestamp margin needs
            // no periodic rehash. Leases were handled above, even while a
            // racy baseline waits for a confirming sweep.
            remember(observationToken, baselineEnd_); return progress();
        }
        begin(source, wallNow);
    }
    std::array<char, 65536> bytes{};
    size_t consumed = 0;
    for (;;) {
        if (position_ == targetEnd_) {
            const auto digest = digest_.finish();
            if (!verifying_) {
                candidate_ = digest;
                const auto oldBaselineState = baselineState_;
                baselineState_ = digest_;
                // The candidate proved the old prefix. Only its append needs
                // a second pass, seeded with the published prefix state.
                digest_ = growth_ ? oldBaselineState : SourceDigest{};
                position_ = growth_ ? baselineEnd_ : 0;
                verifying_ = true;
            } else if (digest == candidate_) {
                // Growth reads the old prefix once, in the candidate, where it
                // matched the published baseline. A prefix rewrite after that
                // read changes the size or stamp, so the next observation
                // sweeps again and its candidate fails this baseline, as for
                // any write after a full verification pass.
                completedWork_ = twice(targetEnd_) - (growth_ ? baselineEnd_ : 0);
                baseline_ = candidate_; baselineEnd_ = targetEnd_; baselinePresent_ = true;
                active_ = false; observedSize_ = targetEnd_; stamp_ = targetStamp_;
                // A later same-length write keeps the stamp while its
                // timestamp bucket is open. Three seconds cover FAT's and
                // SMB's two-second buckets plus clock rounding; a stamp that
                // recent gets one confirming sweep once it has aged.
                const auto safeStart = sweepStartWall_ - std::chrono::seconds(3);
                const auto safeNanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    safeStart.time_since_epoch()).count();
                baselineNeedsConfirmation_ = std::max(targetMtimeNanoseconds_, targetCtimeNanoseconds_) > safeNanoseconds;
                nextSweep_ = now + std::chrono::seconds(2);
                remember(observationToken, baselineEnd_);
                return progress();
            } else {
                // Finish both entire sweeps before rejecting a candidate. In
                // particular, never repeatedly abort at an early changed byte.
                changed(); begin(source, wallNow);
            }
            if (consumed >= byteSlice) return progress();
            continue;
        }
        if (consumed >= byteSlice) return progress();
        auto count = static_cast<size_t>(std::min<uint64_t>({bytes.size(), byteSlice - consumed, targetEnd_ - position_}));
        if (!verifying_ && !compared_ && baselineEnd_ > position_)
            count = static_cast<size_t>(std::min<uint64_t>(count, baselineEnd_ - position_));
        read(position_, bytes.data(), count);
        digest_.append(std::string_view(bytes.data(), count)); position_ += count; consumed += count;
        if (!verifying_ && !compared_ && position_ == baselineEnd_) {
            if (digest_.finish() != baseline_) { changed(); growth_ = false; }
            compared_ = true;
        }
    }
}
}
