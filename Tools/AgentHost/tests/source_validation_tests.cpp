#include "JsonlReader.h"
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <unistd.h>

using namespace tessera;
using Clock = SourceValidation::Clock;
using WallClock = SourceValidation::WallClock;
static_assert(sizeof(SourceValidation) < 1024, "validation must not retain history-sized state");
static std::string hex(const std::array<uint8_t, 32>& digest) {
    std::ostringstream out;
    for (const auto byte : digest) out << std::hex << std::setw(2) << std::setfill('0') << unsigned(byte);
    return out.str();
}
static void write(const std::string& path, const std::string& value) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << value;
}
static SourceValidation::Result validate(const std::string& path, SourceValidation& state,
        size_t slice, Clock::time_point now) {
    for (size_t attempt = 0; attempt < 10000; ++attempt) {
        JsonlReader reader(path, "claude");
        const auto result = reader.validatePrefix(state, slice, now);
        assert(reader.bytesRead() <= slice);
        if (result.ready) { assert(reader.size() == result.validatedEnd); return result; }
    }
    assert(false && "validation failed to converge"); return {};
}
int main() {
    // SHA-256 padding, length encoding, incremental update, and copy vectors.
    SourceDigest empty; assert(hex(empty.finish()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    SourceDigest abc; abc.append("a"); abc.append(std::string_view{}); abc.append("bc");
    assert(hex(abc.finish()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    SourceDigest million;
    for (int i = 0; i < 1000; ++i) million.append(std::string(1000, 'a'));
    assert(hex(million.finish()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    const auto before = abc.finish(); abc.append("d"); assert(abc.finish() != before);
    // Only a fully validated unchanged revision permits reuse across growth;
    // unvalidated readers keep the existing strict source-state check.
    JsonlContinuation::Source old{"path", "inode", "mtime1", "claude", 100, 1};
    auto appended = old; appended.size = 120; appended.stamp = "mtime2";
    assert(old.same(appended)); appended.observedRevision = 2; assert(!old.same(appended));
    old.observedRevision = appended.observedRevision = 0; assert(!old.same(appended));

    char pattern[] = "/tmp/tessera-source-validation-XXXXXX";
    const auto* directory = ::mkdtemp(pattern); assert(directory);
    const std::string path = std::string(directory) + "/synthetic.jsonl";
    struct Cleanup { std::string path; ~Cleanup() { std::filesystem::remove_all(path); } } cleanup{directory};
    const auto start = Clock::now();
    std::string original(65536 * 3 + 17, 'x'); original.back() = '\n';
    write(path, original); SourceValidation state;
    const auto first = validate(path, state, 8191, start);
    assert(first.ready && first.revision && first.validatedEnd == original.size());
    assert(first.checkedBytes == original.size() * 2);
    SourceValidation reconstructed;
    const auto reconstructedResult = validate(path, reconstructed, 8191, start);
    assert(reconstructedResult.revision != first.revision);
    assert(reconstructed.fingerprint() == state.fingerprint());
    // Ordinary unchanged page requests do not rescan the source.
    for (int i = 0; i < 20; ++i) {
        JsonlReader reader(path, "claude");
        assert(reader.validatePrefix(state, 8191, start).ready); assert(reader.bytesRead() == 0);
    }
    // Exercise stat-to-Source timestamp plumbing through a real reader.
    {
        SourceValidation aged;
        const auto agedWall = WallClock::now() + std::chrono::hours(24);
        JsonlReader firstReader(path, "claude");
        const auto proof = firstReader.validatePrefix(aged, SourceValidation::defaultSlice, start, 0, agedWall);
        assert(proof.ready && firstReader.bytesRead() == 2 * original.size());
        JsonlReader laterReader(path, "claude");
        const auto reused = laterReader.validatePrefix(aged, SourceValidation::defaultSlice,
            start + std::chrono::seconds(3), 0, agedWall + std::chrono::seconds(3));
        assert(reused.ready && reused.cycle == proof.cycle && laterReader.bytesRead() == 0);
    }
    // Interior edit + growth preserves the former header and boundary suffix.
    {
        std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
        file.seekp(80000); file << "rewritten";
        file.seekp(0, std::ios::end); file << "appended\n";
    }
    assert(validate(path, state, 8191, start).revision != first.revision);

    // Appends on every resume cannot move the active finite target.
    write(path, original); SourceValidation appending; size_t turns = 0;
    for (;;) {
        JsonlReader reader(path, "claude");
        const auto result = reader.validatePrefix(appending, 8191, start);
        assert(result.totalBytes == original.size() * 2); assert(reader.bytesRead() <= 8191);
        ++turns;
        if (result.ready) { assert(result.validatedEnd == original.size()); break; }
        std::ofstream(path, std::ios::app) << "more live output\n";
        assert(turns < 100);
    }
    assert(turns > 2);
    const auto revision = appending.revision();
    validate(path, appending, 8191, start); assert(appending.revision() == revision);

    // A safely aged stamp is trusted after a full proof; a racy stamp gets
    // exactly one confirming sweep after the two-second delay. A stamp 2.5 s
    // old is still racy: a two-second FAT/SMB bucket may not have closed.
    std::string bytes = original;
    const auto wallStart = WallClock::time_point(std::chrono::seconds(100000));
    const auto stampTime = std::chrono::duration_cast<std::chrono::nanoseconds>(wallStart.time_since_epoch()).count();
    for (int64_t age : {int64_t(4'000'000'000), int64_t(0), int64_t(2'500'000'000)}) {
        const bool racy = age < 3'000'000'000;
        SourceValidation periodic;
        uint64_t readBytes = 0;
        auto observe = [&](int seconds) {
            return periodic.advance({"authorized:1", "unchanged-stamp", bytes.size(),
                    stampTime - age, stampTime - age},
                [&](uint64_t offset, char* out, size_t count) {
                    readBytes += count; std::memcpy(out, bytes.data() + offset, count);
                }, bytes.size() * 2, start + std::chrono::seconds(seconds), 0, 0, true,
                wallStart + std::chrono::seconds(seconds));
        };
        const auto firstProof = observe(0); assert(firstProof.ready && readBytes == bytes.size() * 2);
        readBytes = 0;
        assert(observe(1).cycle == firstProof.cycle && readBytes == 0);
        const auto confirmation = observe(3);
        assert(confirmation.ready && confirmation.cycle == firstProof.cycle + (racy ? 1 : 0));
        assert(readBytes == (racy ? bytes.size() * 2 : 0));
        readBytes = 0;
        assert(observe(30).cycle == confirmation.cycle && readBytes == 0);
    }
    // A same-length rewrite inside a coarse bucket keeps the stamp. The
    // confirming sweep must still retire the first proof's revision.
    {
        SourceValidation coarse;
        auto rewritten = original;
        auto observe = [&](int seconds) {
            return coarse.advance({"authorized:1", "bucket-stamp", rewritten.size(),
                    stampTime - 1'500'000'000, stampTime - 1'500'000'000},
                [&](uint64_t offset, char* out, size_t count) { std::memcpy(out, rewritten.data() + offset, count); },
                rewritten.size() * 2, start + std::chrono::seconds(seconds), 0, 0, true,
                wallStart + std::chrono::seconds(seconds));
        };
        const auto proof = observe(0); assert(proof.ready);
        rewritten[0] = rewritten[0] == 'x' ? 'y' : 'x';
        assert(observe(1).revision == proof.revision);
        for (int seconds = 3; seconds < 10 && coarse.revision() == proof.revision; ++seconds) observe(seconds);
        assert(coarse.revision() != proof.revision);
        const auto confirmed = observe(10); assert(confirmed.ready && confirmed.revision != proof.revision);
    }

    // Growth compares the whole old prefix once, then hashes only the append
    // from the stored SHA-256 state in the verification pass. Small slices
    // retain monotonic, exact byte progress across many reader constructions.
    {
        SourceValidation growing;
        std::string content(1031, 'a');
        uint64_t readBytes = 0;
        auto advance = [&](size_t slice, int seconds, const std::string& stamp, const std::string& identity = "growth") {
            return growing.advance({identity, stamp, content.size(), stampTime - 4'000'000'000,
                    stampTime - 4'000'000'000},
                [&](uint64_t offset, char* out, size_t count) {
                    assert(offset + count <= content.size());
                    readBytes += count; std::memcpy(out, content.data() + offset, count);
                }, slice, start + std::chrono::seconds(seconds), 0, 0, true,
                wallStart + std::chrono::seconds(seconds));
        };
        auto complete = [&](size_t slice, int seconds, const std::string& stamp) {
            uint64_t previous = 0, cycle = 0;
            for (int i = 0; i < 10000; ++i) {
                const auto result = advance(slice, seconds, stamp);
                if (cycle == result.cycle) assert(result.checkedBytes >= previous);
                assert(result.checkedBytes <= result.totalBytes);
                previous = result.checkedBytes; cycle = result.cycle;
                if (result.ready) return result;
            }
            assert(false && "growth validation failed to converge"); return SourceValidation::Result{};
        };
        const auto initial = complete(17, 0, "first");
        assert(initial.checkedBytes == 2 * content.size() && readBytes == 2 * content.size());
        const auto originalFingerprint = growing.fingerprint();
        content += std::string(137, 'b'); readBytes = 0;
        const auto appendedProof = complete(7, 3, "second");
        assert(appendedProof.revision == initial.revision && appendedProof.cycle == initial.cycle + 1);
        assert(appendedProof.checkedBytes == 1031 + 2 * 137 && appendedProof.totalBytes == appendedProof.checkedBytes);
        assert(readBytes == appendedProof.checkedBytes && growing.fingerprint() != originalFingerprint);
        readBytes = 0;
        assert(advance(7, 30, "second").cycle == appendedProof.cycle && readBytes == 0);

        // A rewritten prefix plus append invalidates the old revision at the
        // compared boundary and verifies the new candidate over its full cut.
        content[10] = 'z'; content += std::string(19, 'c'); readBytes = 0;
        const auto rewritten = complete(11, 33, "third");
        assert(rewritten.revision != appendedProof.revision && readBytes == 2 * content.size());
        assert(rewritten.checkedBytes == readBytes);

        // Same-size stamp changes, shrink, and inode replacement retain full
        // sweeps and their existing revision rules.
        readBytes = 0;
        const auto restamped = complete(13, 36, "fourth");
        assert(readBytes == 2 * content.size() && restamped.revision == rewritten.revision);
        content.resize(29); readBytes = 0;
        const auto shrunk = complete(5, 39, "fifth");
        assert(readBytes == 2 * content.size() && shrunk.revision != restamped.revision);
        // Identity change is tested through advance directly, with the same
        // content and size to isolate it from the shrink above.
        readBytes = 0;
        auto replacement = advance(content.size() * 2, 42, "fifth", "replacement");
        assert(replacement.ready && replacement.revision != shrunk.revision && readBytes == 2 * content.size());
    }

    // One read's proof survives periodic expiry through index reduction. A
    // fresh head request, however, must advance beyond its old captured cut.
    bytes = original; SourceValidation leased; uint64_t readBytes = 0;
    auto job = [&](uint64_t token, Clock::time_point now, bool refresh = true, uint64_t minimum = 0) {
        return leased.advance({"authorized:leased", "stamp", bytes.size(), stampTime, stampTime},
            [&](uint64_t offset, char* out, size_t count) {
                readBytes += count; std::memcpy(out, bytes.data() + offset, count);
            }, bytes.size() * 2, now, token, minimum, refresh,
            wallStart + std::chrono::duration_cast<WallClock::duration>(now - start));
    };
    const auto captured = job(11, start); assert(captured.ready);
    readBytes = 0;
    const auto sameBootstrap = job(11, start + std::chrono::seconds(3));
    assert(sameBootstrap.ready && sameBootstrap.cycle == captured.cycle && readBytes == 0);
    bytes += "later bytes\n"; readBytes = 0;
    const auto resumed = job(11, start + std::chrono::seconds(3));
    assert(resumed.ready && resumed.validatedEnd == original.size() && readBytes == 0);
    const auto fresh = job(12, start + std::chrono::seconds(3));
    assert(fresh.ready && fresh.validatedEnd == bytes.size() && readBytes == original.size() + 2 * (bytes.size() - original.size()));
    readBytes = 0;
    const auto upgraded = job(11, start + std::chrono::seconds(6), true, original.size() + 3);
    assert(upgraded.validatedEnd == original.size() + 3 && readBytes == 0);
    assert(job(20, start + std::chrono::seconds(60), false).ready && readBytes == 0);
    assert(job(21, start + std::chrono::seconds(60)).ready && readBytes == 0);
    bytes += "one more append\n";
    const auto headSlice = leased.advance({"authorized:leased", "stamp", bytes.size(), stampTime, stampTime},
        [&](uint64_t offset, char* out, size_t count) { std::memcpy(out, bytes.data() + offset, count); },
        8192, start + std::chrono::seconds(63), 22, 0, true, wallStart + std::chrono::seconds(63));
    assert(!headSlice.ready); readBytes = 0;
    assert(job(23, start + std::chrono::seconds(63), false).ready && readBytes == 0);
    assert(!leased.progress().ready); // historical navigation did not steal/reset the sweep
    assert(job(22, start + std::chrono::seconds(63)).ready);

    // A resuming deep-lineage traversal must not rehash the already completed
    // ancestors every time the next ancestor yields, even after long pauses.
    std::array<SourceValidation, 33> ancestors;
    const std::string ancestorBytes(4096, 'a');
    uint64_t lineageReadBytes = 0; auto now = start; bool lineageReady = false;
    for (size_t attempt = 0; attempt < 200 && !lineageReady; ++attempt) {
        lineageReady = true;
        for (size_t i = 0; i < ancestors.size(); ++i) {
            const auto result = ancestors[i].advance({"ancestor:" + std::to_string(i), "stable", ancestorBytes.size()},
                [&](uint64_t offset, char* out, size_t count) {
                    lineageReadBytes += count; std::memcpy(out, ancestorBytes.data() + offset, count);
                }, 2048, now, 100);
            if (!result.ready) { lineageReady = false; break; }
        }
        now += std::chrono::seconds(3);
    }
    assert(lineageReady && lineageReadBytes == ancestors.size() * ancestorBytes.size() * 2);

    // Mutation behind the scanner cannot abort every sweep before later bytes.
    bytes = original; SourceValidation concurrent; bool changed = false;
    uint64_t largestOffset = 0; size_t attempts = 0;
    for (;;) {
        const auto result = concurrent.advance({"authorized:2", "observed", bytes.size()},
            [&](uint64_t offset, char* out, size_t count) {
                largestOffset = std::max(largestOffset, offset);
                std::memcpy(out, bytes.data() + offset, count);
                if (!changed && offset >= 65536) { bytes[1] = 'y'; changed = true; }
            }, 16384, start);
        if (result.ready) { assert(result.revision > 1); break; }
        assert(++attempts < 100);
    }
    assert(largestOffset >= 65536 * 2);

    // A known in-place write invalidates even a same-job historical lease.
    // Restoring mtime cannot hide it because the reader also observes ctime.
    {
        write(path, original); SourceValidation changedFile;
        JsonlContinuation context; JsonlContinuation::Scope scope(context); context.beginSlice(444);
        const auto initial = validate(path, changedFile, 8191, start);
        const auto modified = std::filesystem::last_write_time(path);
        { std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary); file.seekp(80000); file << 'y'; }
        std::filesystem::last_write_time(path, modified);
        context.beginSlice(444); JsonlReader changedReader(path, "claude"); changedReader.setValidationRefresh(false);
        const auto replacement = changedReader.validatePrefix(changedFile, SourceValidation::defaultSlice, start);
        assert(replacement.ready && replacement.revision != initial.revision && changedReader.bytesRead() > 0);
    }

    // Cancellation preserves exactly the successfully consumed prefix.
    write(path, original); SourceValidation interrupted; unsigned checks = 0; bool cancelled = false;
    try {
        JsonlReader reader(path, "claude", -1, [&] { return ++checks > 1; }); reader.validatePrefix(interrupted);
    } catch (const std::runtime_error& error) { cancelled = std::string(error.what()) == "cancelled"; }
    assert(cancelled && interrupted.progress().checkedBytes == 65536);
    validate(path, interrupted, 8191, start);
    const auto oldRevision = interrupted.revision(); write(path, "short\n");
    assert(validate(path, interrupted, 8191, start).revision > oldRevision);
    const auto truncatedRevision = interrupted.revision();
    write(path + ".next", "other\n"); std::filesystem::rename(path + ".next", path);
    assert(validate(path, interrupted, 8191, start).revision > truncatedRevision);
    // The observation includes partial physical tail bytes; decoding excludes them.
    write(path, "{}\nunfinished"); SourceValidation partial; JsonlReader reader(path, "claude");
    assert(reader.validatePrefix(partial, 8191, start).validatedEnd == 13); assert(reader.completeEnd() == 3);
    std::cout << "full-prefix integrity, append liveness, missed wakeups, bounded work and cancellation passed\n";
}
