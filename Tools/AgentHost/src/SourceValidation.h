#pragma once
#include <array>
#include <cstdint>
#include <string>

namespace tessera {
// A stat-only source observation; it reads no file contents. A replaced
// (identity), truncated, or same-length rewritten (stamp) source gets a new
// revision, and growth keeps it. Indexes add their boundary witness. An
// interior rewrite that also grows the file and keeps that witness goes
// unnoticed: provider transcripts are append-only, and hashing every byte of
// a long transcript on each open and append cost far more than it caught.
// An index that reads a record contradicting what it proved invalidates the
// state, so its next refresh rebuilds rather than failing every read.
// Retain this state across provider-index resets.
class SourceValidation {
public:
    struct Source {
        std::string identity, stamp;
        // The readable end (a lineage prefix stops short of a growing file)
        // and the physical size the stamp describes.
        uint64_t size = 0, fileSize = 0;
        // The file has grown since the stamp was taken: a write in progress
        // stamps the file before its size grows, which is no rewrite.
        bool growing = false;
    };
    struct Result { uint64_t revision = 0, validatedEnd = 0; };
    // A resumed job, by its observation token, keeps the cut it first
    // observed (raised to minimumEnd) through reduction and page assembly.
    Result advance(const Source& source, uint64_t observationToken = 0, uint64_t minimumEnd = 0);
    uint64_t revision() const { return revision_; }
    // A new revision the next observation reports, for a change only the
    // contents showed; continuations retire what the old revision proved.
    void invalidate() { changed(); }
private:
    void changed();
    void remember(uint64_t token, uint64_t cut);
    struct Lease { uint64_t token = 0, revision = 0, cut = 0, touched = 0; };
    std::array<Lease, 16> leases_{};
    uint64_t leaseClock_ = 0;
    std::string identity_, stamp_;
    uint64_t revision_ = 0, end_ = 0, fileSize_ = 0;
    bool observed_ = false;
};
}
