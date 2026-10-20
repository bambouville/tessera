#pragma once
#include "SourceDigest.h"
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>

namespace tessera {
// Complete fixed-prefix sweeps, independent of page size and append rate.
// Retain this state across provider-index resets and bounded readPending yields.
// No file contents, descriptors, or history-sized digest tables are retained.
class SourceValidation {
public:
    using Clock = std::chrono::steady_clock;
    using WallClock = std::chrono::system_clock;
    struct Source {
        std::string identity, stamp;
        uint64_t size = 0;
        // Wall-clock stat times; the stamp still carries their full precision.
        int64_t mtimeNanoseconds = 0, ctimeNanoseconds = 0;
    };
    struct Result {
        bool ready = false;
        uint64_t revision = 0, validatedEnd = 0;
        uint64_t checkedBytes = 0, totalBytes = 0, cycle = 0;
    };
    using Read = std::function<void(uint64_t, char*, size_t)>;
    static constexpr size_t defaultSlice = 4 * 1024 * 1024;
    // read must fill the requested range from an authorized descriptor or
    // throw. Successfully consumed blocks remain resumable after cancellation.
    Result advance(const Source& source, const Read& read,
                   size_t byteSlice = defaultSlice, Clock::time_point now = Clock::now(),
                   uint64_t observationToken = 0, uint64_t minimumEnd = 0, bool refresh = true,
                   WallClock::time_point wallNow = WallClock::now());
    uint64_t revision() const { return revision_; }
    Result progress() const;
    // Last published baseline, also available to historical/leased readers
    // while a new sweep runs. Stable across cache eviction/reconstruction for
    // an identical frozen prefix; this is not a continuation namespace.
    std::array<uint8_t, 32> fingerprint() const;
private:
    void begin(const Source& source, WallClock::time_point wallNow);
    void changed();
    void remember(uint64_t token, uint64_t cut);
    struct Lease { uint64_t token = 0, revision = 0, cut = 0, touched = 0; };
    std::array<Lease, 16> leases_{};
    uint64_t leaseClock_ = 0;
    std::string identity_, stamp_, targetStamp_;
    uint64_t observedSize_ = 0, revision_ = 0, cycle_ = 0;
    uint64_t baselineEnd_ = 0, targetEnd_ = 0, position_ = 0, completedWork_ = 0;
    int64_t targetMtimeNanoseconds_ = 0, targetCtimeNanoseconds_ = 0;
    std::array<uint8_t, 32> baseline_{}, candidate_{};
    SourceDigest digest_, baselineState_;
    bool baselinePresent_ = false, active_ = false, verifying_ = false, compared_ = false;
    bool growth_ = false, baselineNeedsConfirmation_ = false;
    Clock::time_point nextSweep_{};
    WallClock::time_point sweepStartWall_{};
};
}
