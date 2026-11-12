#include "JsonlReader.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

using namespace tessera;
static_assert(sizeof(SourceValidation) < 1024, "validation must not retain history-sized state");
static void write(const std::string& path, const std::string& value) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << value;
}
static SourceValidation::Result validate(const std::string& path, SourceValidation& state, uint64_t* bytesRead = nullptr) {
    JsonlReader reader(path, "claude");
    const auto result = reader.validatePrefix(state);
    assert(reader.size() == result.validatedEnd);
    if (bytesRead) *bytesRead = reader.bytesRead();
    return result;
}
int main() {
    // Only an observed unchanged revision permits reuse across growth;
    // unobserved readers keep the existing strict source-state check.
    JsonlContinuation::Source old{"path", "inode", "mtime1", "claude", 100, 1};
    auto appended = old; appended.size = 120; appended.stamp = "mtime2";
    assert(old.same(appended)); appended.observedRevision = 2; assert(!old.same(appended));
    old.observedRevision = appended.observedRevision = 0; assert(!old.same(appended));

    char pattern[] = "/tmp/tessera-source-validation-XXXXXX";
    const auto* directory = ::mkdtemp(pattern); assert(directory);
    const std::string path = std::string(directory) + "/synthetic.jsonl";
    struct Cleanup { std::string path; ~Cleanup() { std::filesystem::remove_all(path); } } cleanup{directory};
    std::string original(65536 * 3 + 17, 'x'); original.back() = '\n';
    write(path, original);

    // Observation reads no bytes, however long the source.
    SourceValidation state; uint64_t bytesRead = 1;
    const auto first = validate(path, state, &bytesRead);
    assert(first.revision && first.validatedEnd == original.size() && bytesRead == 0);
    SourceValidation reconstructed;
    assert(validate(path, reconstructed).revision != first.revision);
    for (int i = 0; i < 20; ++i) assert(validate(path, state).revision == first.revision);

    // Growth keeps the revision, reaches the new end and still reads nothing.
    std::ofstream(path, std::ios::app) << "more live output\n";
    const auto grown = validate(path, state, &bytesRead);
    assert(grown.revision == first.revision && grown.validatedEnd == original.size() + 17 && bytesRead == 0);

    // A same-length write is a new revision even with mtime restored: the
    // stamp also observes ctime.
    {
        write(path, original); SourceValidation changedFile;
        const auto initial = validate(path, changedFile);
        const auto modified = std::filesystem::last_write_time(path);
        ::usleep(20000);
        { std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary); file.seekp(80000); file << 'y'; }
        std::filesystem::last_write_time(path, modified);
        assert(validate(path, changedFile).revision != initial.revision);
    }

    // Truncation and replacement by rename are new revisions.
    write(path, original); SourceValidation replaced;
    const auto oldRevision = validate(path, replaced).revision; write(path, "short\n");
    const auto truncated = validate(path, replaced).revision; assert(truncated != oldRevision);
    write(path + ".next", "other\n"); std::filesystem::rename(path + ".next", path);
    assert(validate(path, replaced).revision != truncated);

    // A lineage prefix stops short of its growing file: the parent's appends
    // change the stamp without rewriting the prefix.
    {
        SourceValidation prefix;
        const auto cut = prefix.advance({"lineage", "stamp1", 100, 100});
        const auto appendedParent = prefix.advance({"lineage", "stamp2", 100, 160});
        assert(appendedParent.revision == cut.revision && appendedParent.validatedEnd == 100);
        assert(prefix.advance({"lineage", "stamp3", 100, 160}).revision != cut.revision);
    }

    // A write in progress stamps the file before its size grows: an
    // observation that already sees the growth is no rewrite. Invalidation
    // is a new revision without any change to the file.
    {
        SourceValidation writing;
        const auto cut = writing.advance({"writing", "stamp1", 100, 100});
        assert(writing.advance({"writing", "stamp2", 100, 100, true}).revision == cut.revision);
        assert(writing.advance({"writing", "stamp3", 100, 100}).revision != cut.revision);
        const auto before = writing.revision(); writing.invalidate();
        assert(writing.revision() != before && writing.advance({"writing", "stamp3", 100, 100}).revision == writing.revision());
    }

    // One read keeps its observed cut through index reduction; a fresh head
    // request reaches the new end.
    {
        SourceValidation leased;
        const auto captured = leased.advance({"leased", "s1", 100, 100}, 11);
        const auto resumed = leased.advance({"leased", "s2", 140, 140}, 11);
        assert(resumed.revision == captured.revision && resumed.validatedEnd == 100);
        assert(leased.advance({"leased", "s2", 140, 140}, 12).validatedEnd == 140);
        assert(leased.advance({"leased", "s2", 140, 140}, 11, 103).validatedEnd == 103);
        bool refused = false;
        try { leased.advance({"leased", "s2", 140, 140}, 11, 141); }
        catch (const std::runtime_error& error) { refused = std::string(error.what()) == "sourceChanged"; }
        assert(refused);
        // A rewrite retires the lease with the revision.
        const auto rewritten = leased.advance({"leased", "s3", 140, 140}, 11);
        assert(rewritten.revision != captured.revision && rewritten.validatedEnd == 140);
    }

    // The observation includes partial physical tail bytes; decoding excludes them.
    write(path, "{}\nunfinished"); SourceValidation partial; JsonlReader reader(path, "claude");
    assert(reader.validatePrefix(partial).validatedEnd == 13); assert(reader.completeEnd() == 3);
    std::cout << "stat-only revisions, growth without reads, leases and partial tails passed\n";
}
