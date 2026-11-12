#include "SourceValidation.h"
#include <algorithm>
#include <atomic>
#include <limits>
#include <stdexcept>

namespace tessera {
void SourceValidation::changed() {
    // Continuations outlive index eviction. A new validator for the same inode
    // must never accidentally reuse a previous validator's numeric revision.
    static std::atomic<uint64_t> nextRevision{1};
    const auto revision = nextRevision.fetch_add(1, std::memory_order_relaxed);
    if (!revision || revision == std::numeric_limits<uint64_t>::max()) throw std::runtime_error("sourceChanged");
    revision_ = revision;
}

void SourceValidation::remember(uint64_t token, uint64_t cut) {
    if (!token) return;
    auto slot = std::find_if(leases_.begin(), leases_.end(), [&](const Lease& lease) { return lease.token == token; });
    if (slot == leases_.end()) slot = std::min_element(leases_.begin(), leases_.end(),
        [](const Lease& a, const Lease& b) { return a.touched < b.touched; });
    *slot = {token, revision_, cut, ++leaseClock_};
}

SourceValidation::Result SourceValidation::advance(const Source& source, uint64_t observationToken, uint64_t minimumEnd) {
    // A same-length stamp change is an in-place write; restoring mtime cannot
    // hide one because the stamp also carries ctime.
    if (!observed_ || identity_ != source.identity || source.size < end_ || source.fileSize < fileSize_ ||
        (source.fileSize == fileSize_ && source.stamp != stamp_ && !source.growing))
        changed();
    observed_ = true; identity_ = source.identity; stamp_ = source.stamp;
    end_ = source.size; fileSize_ = source.fileSize;
    Result result{revision_, source.size};
    const auto lease = std::find_if(leases_.begin(), leases_.end(), [&](const Lease& value) {
        return observationToken && value.token == observationToken && value.revision == revision_;
    });
    if (lease != leases_.end()) {
        result.validatedEnd = std::max(lease->cut, minimumEnd);
        if (result.validatedEnd > source.size) throw std::runtime_error("sourceChanged");
    }
    remember(observationToken, result.validatedEnd);
    return result;
}
}
