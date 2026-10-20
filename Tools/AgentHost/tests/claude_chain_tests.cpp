#include "ClaudeChainIndex.h"
#include "KimiHistoryIndex.h"
#include <cassert>
#include <stdexcept>
#include <fstream>
#include <unistd.h>
#include <memory>
#include <random>
#include <sstream>
#include <iostream>
#include <chrono>

int main() {
    using Index = tessera::ClaudeChainIndex;
    std::vector<Index::Entry> entries{{0, 1, "root", "", true, true, true}};
    for (size_t i = 1; i <= 4000; ++i)
        entries.push_back({i, i + 1, "p" + std::to_string(i), i == 1 ? "root" : "p" + std::to_string(i - 1), true, false, false});
    for (size_t i = 4001; i <= 8000; ++i)
        entries.push_back({i, i + 1, "p" + std::to_string(i), "p4000", true, false, false});
    size_t checks = 0;
    auto path = Index::chain(entries, [&] { ++checks; return false; });
    assert(path == std::vector<size_t>{0});
    // Memoization bounds reconstruction work independently of terminal count
    // times shared-stem length. Callback runs at least once per64 traversals.
    assert(checks > 0 && checks < 300);
    const auto withContext = Index::chain(entries, {}, true);
    assert(withContext.front() == 0 && withContext.back() == 8000 && withContext.size() == 4002);
    // Trailing context from an older authored branch cannot change leaf
    // selection, even if that context is physically the newest record.
    std::vector<Index::Entry> branches{{0, 1, "old", "", true, true, true},
        {1, 2, "current", "", true, true, true},
        {2, 3, "current-context", "current", true, false, false},
        {3, 4, "old-context", "old", true, false, false}};
    assert(Index::chain(branches) == std::vector<size_t>{1});
    assert(Index::chain(branches, {}, true) == (std::vector<size_t>{1, 2}));
    // A context UUID can be revised onto another branch. Its old parent
    // edge must not hide the formerly-parented authored leaf: only the latest
    // revision participates in the current graph, just as for message bodies.
    std::vector<Index::Entry> movedContext{{0, 1, "root", "", true, true, true},
        {1, 2, "main", "root", true, true, true},
        {2, 3, "context", "main", true, false, false},
        {3, 4, "context", "root", true, false, false}};
    assert(Index::chain(movedContext) == (std::vector<size_t>{0, 1}));
    assert(Index::chain(movedContext, {}, true) == (std::vector<size_t>{0, 1}));
    std::vector<Index::Entry> cycle{{0, 1, "a", "b", true, true, true},
        {1, 2, "b", "a", true, false, false}};
    auto rejectsCycle = [&](const auto& graph) {
        bool rejected = false;
        try { Index::chain(graph, {}, true); }
        catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "claudeIndexUnproven"; }
        assert(rejected);
    };
    rejectsCycle(cycle); // No terminal: must not publish empty success.
    cycle.push_back({2, 3, "child", "a", true, true, true});
    rejectsCycle(cycle); // A chosen leaf may still have cyclic ancestry.
    cycle.push_back({3, 4, "current", "", true, true, true});
    // Unreachable stale cycles do not invalidate a valid selected branch.
    assert(Index::chain(cycle, {}, true) == (std::vector<size_t>{3}));
    // Claude compaction writes a root compact_boundary whose advisory
    // logicalParentUuid may name the previous node, an earlier node, a
    // record written after the boundary, or nothing. Display ancestry
    // continues at the logical parent only when its current revision starts
    // before the boundary, else at the nearest earlier current non-sidechain
    // node. Leaf selection still follows parentUuid alone.
    using Graph = std::vector<Index::Entry>;
    auto user = [](uint64_t at, const std::string& id, const std::string& parent, bool main = true) {
        return Index::Entry(at, at + 1, id, parent, true, true, main, {}, false, !main);
    };
    auto context = [](uint64_t at, const std::string& id, const std::string& parent, bool sidechain = false) {
        return Index::Entry(at, at + 1, id, parent, true, false, false, {}, false, sidechain);
    };
    auto boundary = [](uint64_t at, const std::string& id, const std::string& logical) {
        return Index::Entry(at, at + 1, id, "", true, false, false, logical, true, false);
    };
    auto metadata = [](uint64_t at) { return Index::Entry(at, at + 1, "", "", false, false, false); };
    auto both = [&](const Graph& graph, const std::vector<size_t>& expected) {
        assert(Index::chain(graph) == expected);
        assert(Index::chain(graph, {}, true) == expected);
    };
    // Logical parent is the previous node (43 of 70 measured boundaries).
    both({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"), user(3, "s", "b"), user(4, "u1", "s")},
         {0, 1, 2, 3, 4});
    // Logical parent written after the boundary (15/70): a cycle if used;
    // the previous node is the fallback. Missing (5/70) or absent likewise.
    for (const auto& logical : {std::string("late"), std::string("ghost"), std::string(), std::string("b")})
        both({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", logical), context(3, "late", "b"),
              user(4, "s", "late"), user(5, "u1", "s")}, {0, 1, 2, 3, 4, 5});
    // Logical parent is an earlier node (7/70): the /compact command message
    // after it is a stale sibling branch, not display ancestry.
    both({user(0, "u0", ""), user(1, "a0", "u0"), metadata(2), user(3, "command", "a0"), metadata(4),
          boundary(5, "b", "a0"), user(6, "s", "b"), user(7, "u1", "s")}, {0, 1, 5, 6, 7});
    // Two successive compactions, one logical and one positional.
    both({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b1", "a0"), user(3, "s1", "b1"), user(4, "a1", "s1"),
          boundary(5, "b2", "missing"), context(6, "t", "b2"), user(7, "s2", "t"), user(8, "a2", "s2")},
         {0, 1, 2, 3, 4, 5, 6, 7, 8});
    // A sidechain node immediately before the boundary is never the
    // positional parent, whether it is a message or context.
    both({user(0, "u0", ""), user(1, "a0", "u0"), user(2, "side", "a0", false), boundary(3, "b", ""),
          user(4, "s", "b")}, {0, 1, 3, 4});
    both({user(0, "u0", ""), user(1, "a0", "u0"), context(2, "progress", "a0", true), boundary(3, "b", "later"),
          user(4, "s", "b")}, {0, 1, 3, 4});
    // A logical parent whose current revision follows the boundary is not
    // earlier; nor is a superseded revision a positional parent.
    {
        const Graph revised{user(0, "u0", ""), user(1, "a0", "u0"), context(2, "x", "a0"), boundary(3, "b", "x"),
            user(4, "s", "b"), context(5, "x", "s")};
        assert(Index::chain(revised) == (std::vector<size_t>{0, 1, 3, 4}));
        assert(Index::chain(revised, {}, true) == (std::vector<size_t>{0, 1, 3, 4, 5}));
    }
    // No cycle is possible: descendants, self and forward names all fail the
    // before-boundary test; a first-record boundary stays a root.
    both({boundary(0, "b", "s"), user(1, "s", "b")}, {0, 1});
    both({user(0, "u0", ""), boundary(1, "b", "b"), user(2, "s", "b")}, {0, 1, 2});
    // Nor can a forward parentUuid below the boundary lead back onto the
    // path: once a boundary is crossed, each step must reach a node earlier
    // than the whole path so far, or the path stops at that node.
    both({user(0, "u0", ""), context(1, "x", "s"), boundary(2, "b", ""), user(3, "s", "b"), user(4, "t", "s")},
         {1, 2, 3, 4});
    // Likewise when an ancestor of the logical parent is revised after it.
    both({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"), user(3, "s", "b"), user(4, "t", "s"),
          context(5, "u0", "s")}, {1, 2, 3, 4});
    // Before any crossing, a cycle still fails closed.
    {
        bool rejected = false;
        try { Index::chain({user(0, "a", "b"), user(1, "b", "a"), boundary(2, "c", "a"), user(3, "t", "a")}); }
        catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "claudeIndexUnproven"; }
        assert(rejected);
    }
    // Leaf selection is unchanged: before the summary arrives, a boundary
    // tail has no authored leaf of its own, exactly as before this rule.
    both({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"), context(3, "att", "b")}, {0, 1});
    // Only boundary records are special: logicalParentUuid on an ordinary
    // root (such as an isCompactSummary user message) is not ancestry.
    both({user(0, "u0", ""), Index::Entry(1, 2, "s", "", true, true, true, "u0", false, false)}, {1});
    bool cancelled = false;
    try { Index::chain(entries, [] { return true; }); }
    catch (const std::runtime_error& error) { cancelled = std::string(error.what()) == "cancelled"; }
    assert(cancelled);

    char filename[] = "/tmp/tessera-chain-batch-XXXXXX";
    const int descriptor = ::mkstemp(filename);
    assert(descriptor >= 0); ::close(descriptor);
    auto indexEntry = [&](Index& index, size_t ordinal) { tessera::JsonlReader reader(filename, "claude"); return index.entry(reader, ordinal); };
    auto refreshIndex = [](Index& index, tessera::JsonlReader& reader, const std::function<bool()>& cancelled = {}, size_t budget = 128 * 1024 * 1024) {
        for (;;) { try { index.refresh(reader, cancelled, budget); return; }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "readPending") throw; }
        }
    };
    // Real Claude appends context attachments after the assistant and then
    // parents the next user message to that trailing attachment. Last-prompt
    // bookkeeping is already visible to the index before the next turn.
    // Admitting the trailing chain only when the next user arrives inserts it
    // BEFORE that metadata and spuriously changes generation on a plain append.
    {
        const std::string prefix =
            "{\"type\":\"user\",\"uuid\":\"u0\",\"parentUuid\":null,\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
            "{\"type\":\"assistant\",\"uuid\":\"a0\",\"parentUuid\":\"u0\",\"message\":{\"role\":\"assistant\",\"content\":\"reply\"}}\n"
            "{\"type\":\"attachment\",\"uuid\":\"context\",\"parentUuid\":\"a0\",\"attachment\":{\"type\":\"queued_command\"}}\n"
            "{\"type\":\"last-prompt\",\"lastPrompt\":\"hello\",\"sessionId\":\"synthetic\"}\n";
        { std::ofstream file(filename); file << prefix; }
        Index index;
        { tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}); }
        const auto generation = index.generation();
        std::vector<std::string> original;
        for (size_t i = 0; i < index.size(); ++i) original.push_back(indexEntry(index, i).id);
        { std::ofstream file(filename, std::ios::app); file <<
            "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":\"context\",\"message\":{\"role\":\"user\",\"content\":\"next\"}}\n"; }
        { tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}); }
        assert(index.generation() == generation);
        for (size_t i = 0; i < original.size(); ++i) assert(indexEntry(index, i).id == original[i]);
        assert(indexEntry(index, index.size() - 1).id == "u1");
    }
    uint64_t fileBytes = 0;
    {
        std::ofstream file(filename);
        for (size_t i = 0; i < 400; ++i) {
            const auto record = std::string("{\"type\":\"user\",\"uuid\":\"r") + std::to_string(i) +
                "\",\"parentUuid\":" + (i ? "\"r" + std::to_string(i - 1) + "\"" : "null") +
                ",\"message\":{\"role\":\"user\",\"content\":\"" + std::string(4096, 'x') + "\"}}\n";
            file << record; fileBytes += record.size();
        }
    }
    {
        tessera::JsonlReader reader(filename, "claude");
        Index index;
        refreshIndex(index, reader, {});
        assert(index.size() == 400);
        // Batch witness collection must not replay all prior cache blocks.
        // Two complete integrity sweeps plus metadata and parent resolution.
        assert(reader.bytesRead() < fileBytes * 5);
        const auto previous = reader.bytesRead();
        refreshIndex(index, reader, {});
        assert(reader.bytesRead() - previous < 131072);
    }
    {
        tessera::JsonlReader reader(filename, "claude");
        Index index;
        size_t batches = 0;
        bool stopped = false;
        try { refreshIndex(index, reader, [&] { return ++batches == 3; }); }
        catch (const std::runtime_error& error) { stopped = std::string(error.what()) == "cancelled"; }
        assert(stopped);
        refreshIndex(index, reader, {});
        assert(index.size() == 400);
        assert(indexEntry(index, 399).id == "r399");
    }
    // Inject cancellation at every input-cache/anchor callback, including the
    // post-admission witness. A plain append must never change generation on
    // retry (another device may still hold cursors for that generation).
    const std::string first = "{\"type\":\"user\",\"uuid\":\"r0\",\"parentUuid\":null,\"message\":{\"role\":\"user\",\"content\":\"synthetic message\"}}\n";
    const std::string second = "{\"type\":\"user\",\"uuid\":\"r1\",\"parentUuid\":\"r0\",\"message\":{\"role\":\"user\",\"content\":\"synthetic message\"}}\n";
    for (size_t interruptAt = 1; interruptAt <= 160; ++interruptAt) {
        { std::ofstream file(filename); file << first; }
        Index index;
        { tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}); }
        const auto generation = index.generation();
        { std::ofstream file(filename, std::ios::app); file << second; }
        size_t calls = 0;
        try {
            tessera::JsonlReader reader(filename, "claude", -1, [&] { return ++calls == interruptAt; });
            refreshIndex(index, reader, {});
        } catch (const std::runtime_error& error) { assert(std::string(error.what()) == "cancelled"); }
        { tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}); }
        assert(index.size() == 2);
        assert(index.generation() == generation);
    }
    // Capacity changes cache strategy, never conversation completeness. The
    // same complete selection must work past the former 20,000-record ceiling
    // and when the compact metadata budget forces dependency reconstruction.
    for (const auto count : {size_t(20001), size_t(96)}) {
        { std::ofstream file(filename);
          for (size_t i = 0; i < count; ++i) file <<
            "{\"type\":\"user\",\"uuid\":\"r" << i << "\",\"parentUuid\":" <<
            (i ? "\"r" + std::to_string(i - 1) + "\"" : "null") <<
            ",\"message\":{\"role\":\"user\",\"content\":\"synthetic\"}}\n";
        }
        tessera::JsonlReader reader(filename, "claude"); Index index;
        refreshIndex(index, reader, {}, count > 100 ? 8 * 1024 * 1024 : 4096);
        assert(index.size() == count);
        assert(indexEntry(index, count - 1).id == "r" + std::to_string(count - 1));
        assert(indexEntry(index, 0).id == "r0");
    }
    // Replay bounded reader yields inside both compact parent reconstruction
    // and lazy dependency lookups. A completed source prefix must converge;
    // restarting an entire dependency scan on every slice would stall here.
    for (const size_t budget : {size_t(128 * 1024 * 1024), size_t(4096)}) {
        Index index; size_t yields = 0;
        auto reader = [&] {
            return std::make_unique<tessera::JsonlReader>(filename, "claude", -1, std::function<bool()>(),
                [remaining = size_t(64)](simdjson::dom::element value, bool truncated) mutable {
                    if (!remaining) throw std::runtime_error("readPending");
                    --remaining;
                    return tessera::normalize("claude", value, truncated);
                });
        };
        for (;;) {
            auto input = reader();
            try { index.refresh(*input, {}, budget); break; }
            catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 10000); }
        }
        assert(index.size() == 96 && yields);
        for (size_t ordinal = 0; ordinal < index.size(); ++ordinal) {
            for (;;) {
                auto input = reader();
                try { assert(index.entry(*input, ordinal).id == "r" + std::to_string(ordinal)); break; }
                catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 10000); }
            }
        }
    }
    {
        Index index;
        tessera::JsonlReader interrupted(filename, "claude", -1, {},
            // Fail during the initial 96-record scan. Compact parent links
            // may now resolve without a second full-file normalization pass.
            [remaining = size_t(50)](simdjson::dom::element value, bool truncated) mutable {
                if (!remaining) throw std::runtime_error("readPending");
                --remaining; return tessera::normalize("claude", value, truncated);
            });
        bool yielded = false;
        try { index.refresh(interrupted, {}); }
        catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); yielded = true; }
        assert(yielded);
        tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}, 128);
        assert(index.lazy() && index.size() == 96 && index.bytes() < 16384);
        assert(index.entry(reader, 0).id == "r0" && index.entry(reader, 95).id == "r95");
    }
    // A read owns one finite validation cut. Appends at every reconstruction
    // yield cannot keep moving its target or restart branch proof forever.
    for (const size_t budget : {size_t(4096), size_t(128 * 1024 * 1024)}) {
        { std::ofstream file(filename); for (size_t i = 0; i < 96; ++i) file <<
            "{\"type\":\"user\",\"uuid\":\"r" << i << "\",\"parentUuid\":" <<
            (i ? "\"r" + std::to_string(i - 1) + "\"" : "null") << ",\"message\":{\"role\":\"user\",\"content\":\"synthetic\"}}\n"; }
        Index index; tessera::JsonlContinuation continuation; size_t appended = 0;
        for (;;) {
            continuation.beginSlice(77); tessera::JsonlContinuation::Scope scope(continuation);
            tessera::JsonlReader reader(filename, "claude", -1, {},
                [remaining = size_t(64)](simdjson::dom::element value, bool truncated) mutable {
                    if (!remaining) throw std::runtime_error("readPending");
                    --remaining; return tessera::normalize("claude", value, truncated);
                });
            try { index.refresh(reader, {}, budget); break; }
            catch (const std::runtime_error& error) {
                assert(std::string(error.what()) == "readPending" && appended < 1000);
                const auto id = 96 + appended++; std::ofstream file(filename, std::ios::app);
                file << "{\"type\":\"user\",\"uuid\":\"r" << id << "\",\"parentUuid\":\"r" << id - 1 <<
                    "\",\"message\":{\"role\":\"user\",\"content\":\"synthetic\"}}\n";
            }
        }
        assert(appended && index.size() == 96);
        continuation.beginSlice(78); tessera::JsonlContinuation::Scope scope(continuation);
        tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}, budget);
        assert(index.size() == 96 + appended);
    }
    // Force the exact lazy evaluator through revisions, context-only old
    // branches, non-monotone ancestor offsets and selected/unselected cycles.
    // Returns each graph entry's physical byte offset.
    auto lineFor = [](const Index::Entry& value) {
        std::ostringstream line;
        if (!value.node && !value.message) line << "{\"type\":\"last-prompt\",\"lastPrompt\":\"synthetic\"}\n";
        else if (value.boundary) line << "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"uuid\":\"" << value.id <<
            "\",\"parentUuid\":null" << (value.logicalParent.empty() ? "" : ",\"logicalParentUuid\":\"" + value.logicalParent + "\"") <<
            (value.sidechain ? ",\"isSidechain\":true" : "") << ",\"content\":\"Conversation compacted\"}\n";
        else line << "{\"type\":\"" << (value.message ? "user" : "attachment") <<
            "\",\"uuid\":\"" << value.id << "\",\"parentUuid\":" <<
            (value.parent.empty() ? "null" : "\"" + value.parent + "\"") <<
            ((value.message && !value.main) || (!value.message && value.sidechain) ? ",\"isSidechain\":true" : "") <<
            (value.message ? ",\"message\":{\"role\":\"user\",\"content\":\"synthetic\"}" : ",\"attachment\":{\"type\":\"queued_command\"}") << "}\n";
        return line.str();
    };
    auto writeGraph = [&](const std::vector<Index::Entry>& graph) {
        std::ofstream file(filename);
        std::vector<uint64_t> offsets; uint64_t offset = 0;
        for (const auto& value : graph) {
            const auto line = lineFor(value);
            offsets.push_back(offset); offset += line.size(); file << line;
        }
        return offsets;
    };
    std::vector<std::vector<Index::Entry>> lazyGraphs{branches, movedContext,
        {{0, 1, "a", "", true, true, true}, {1, 2, "b", "a", true, true, true},
         {2, 3, "a", "", true, true, true}}, cycle};
    for (auto graph : lazyGraphs) {
        writeGraph(graph);
        tessera::JsonlReader reader(filename, "claude"); Index index;
        refreshIndex(index, reader, {}, 128);
        assert(index.lazy());
        const auto expected = Index::chain(graph, {}, true);
        assert(index.size() == expected.size());
        for (size_t i = 0; i < expected.size(); ++i) assert(index.entry(reader, i).id == graph[expected[i]].id);
    }
    writeGraph({{0, 1, "a", "b", true, true, true}, {1, 2, "b", "a", true, false, false}});
    {
        tessera::JsonlReader reader(filename, "claude"); Index index;
        bool rejected = false;
        try { refreshIndex(index, reader, {}, 128); }
        catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "claudeIndexUnproven"; }
        assert(rejected);
    }
    std::mt19937 random(0x434c4155);
    for (size_t scenario = 0; scenario < 80; ++scenario) {
        std::vector<Index::Entry> graph;
        const auto count = 5 + random() % 16;
        for (size_t i = 0; i < count; ++i) {
            const bool message = random() % 4 != 0;
            graph.push_back({i, i + 1, "n" + std::to_string(random() % count),
                random() % 5 ? "n" + std::to_string(random() % count) : "", true, message, random() % 4 != 0});
        }
        writeGraph(graph);
        std::vector<std::string> expected; bool expectedFailure = false;
        try { for (const auto ordinal : Index::chain(graph, {}, true))
            if (!graph[ordinal].message || graph[ordinal].main) expected.push_back(graph[ordinal].id);
        } catch (const std::runtime_error&) { expectedFailure = true; }
        for (size_t budget : {size_t(128), size_t(128 * 1024 * 1024)}) {
            tessera::JsonlReader reader(filename, "claude"); Index index;
            bool failed = false;
            try {
                refreshIndex(index, reader, {}, budget);
                assert(!expectedFailure && index.size() == expected.size());
                for (size_t i = 0; i < expected.size(); ++i) assert(index.entry(reader, i).id == expected[i]);
            } catch (const std::runtime_error& error) { assert(std::string(error.what()) == "claudeIndexUnproven"); failed = true; }
            assert(failed == expectedFailure);
        }
    }
    // Compaction across every file-backed strategy. The selection oracle is
    // chain()'s ancestry plus all metadata, interleaved exactly as documented
    // for compact/lazy publication (metadata before each later path node).
    auto selection = [](const Graph& graph, const std::vector<size_t>& path) {
        std::vector<size_t> result; size_t metadataCursor = 0;
        auto add = [&](size_t end) { for (; metadataCursor < end; ++metadataCursor)
            if (!graph[metadataCursor].node && !graph[metadataCursor].message) result.push_back(metadataCursor); };
        for (const auto index : path) { add(index); if (!graph[index].message || graph[index].main) result.push_back(index); }
        add(graph.size());
        return result;
    };
    enum class Tiny { lazy, linear, either };
    auto checkModes = [&](const Graph& graph, Tiny tiny) {
        const auto offsets = writeGraph(graph);
        const auto expected = selection(graph, Index::chain(graph, {}, true));
        for (const size_t budget : {size_t(128), size_t(4096), size_t(128 * 1024 * 1024)}) {
            tessera::JsonlReader reader(filename, "claude"); Index index;
            refreshIndex(index, reader, {}, budget);
            // 4096 bytes keeps small graphs compact but gives larger ones a
            // multi-entry lazy window; 128 always demotes.
            if (budget > 4096) assert(!index.lazy() && !index.linear());
            else if (budget == 128 && tiny == Tiny::linear) assert(index.lazy() && index.linear());
            else if (budget == 128 && tiny == Tiny::lazy) assert(index.lazy() && !index.linear());
            assert(index.size() == expected.size());
            for (size_t i = 0; i < expected.size(); ++i) {
                const auto value = index.entry(reader, i);
                assert(value.start == offsets[expected[i]] && value.id == graph[expected[i]].id);
            }
            // Reverse window reads rebuild the lazy ancestry cursor.
            for (size_t i = expected.size(); i-- > 0;) assert(index.entry(reader, i).start == offsets[expected[i]]);
        }
        return expected;
    };
    {
        // Linear compaction (logical = previous node, or a later/missing
        // name with a main previous node) stays in the linear proof.
        const Graph linear{user(0, "u0", ""), metadata(1), user(2, "a0", "u0"), metadata(3), boundary(4, "b", "a0"),
            context(5, "att", "b"), user(6, "s", "att"), metadata(7), user(8, "a1", "s"), boundary(9, "b2", "late"),
            metadata(10), context(11, "late", "b2"), user(12, "s2", "late"), user(13, "a2", "s2")};
        assert(checkModes(linear, Tiny::linear).size() == linear.size());
        // A trailing sidechain branch makes the same history nonlinear
        // without changing its selection: the exact lazy path must agree.
        auto branched = linear; branched.push_back(user(14, "aside", "a0", false));
        assert(checkModes(branched, Tiny::lazy) == checkModes(linear, Tiny::linear));
        // Earlier logical parent, sidechain before the boundary, and a
        // boundary tail without a summary all require the exact evaluator.
        const auto earlier = checkModes({user(0, "u0", ""), user(1, "a0", "u0"), metadata(2), user(3, "command", "a0"),
            metadata(4), boundary(5, "b", "a0"), user(6, "s", "b"), user(7, "u1", "s")}, Tiny::lazy);
        assert(earlier == (std::vector<size_t>{0, 1, 2, 4, 5, 6, 7}));
        const auto side = checkModes({user(0, "u0", ""), user(1, "a0", "u0"), context(2, "progress", "a0", true),
            boundary(3, "b", ""), user(4, "s", "b")}, Tiny::lazy);
        assert(side == (std::vector<size_t>{0, 1, 3, 4}));
        const auto pending = checkModes({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"),
            metadata(3), context(4, "att", "b")}, Tiny::lazy);
        assert(pending == (std::vector<size_t>{0, 1, 3}));
        // The stop rule (see chain()) holds in every strategy.
        const auto forward = checkModes({user(0, "u0", ""), context(1, "x", "s"), metadata(2), boundary(3, "b", ""),
            user(4, "s", "b"), user(5, "t", "s")}, Tiny::lazy);
        assert(forward == (std::vector<size_t>{1, 2, 3, 4, 5}));
        const auto revisedAncestor = checkModes({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"),
            user(3, "s", "b"), user(4, "t", "s"), metadata(5), context(6, "u0", "s")}, Tiny::lazy);
        assert(revisedAncestor == (std::vector<size_t>{1, 2, 3, 4, 5}));
    }
    // Random revisions, cycles, sidechains, metadata and boundaries with
    // absent, missing, earlier, self and later logical names. Every strategy
    // must match chain() or fail closed exactly when chain() does.
    for (size_t scenario = 0; scenario < 400; ++scenario) {
        Graph graph;
        const auto count = 5 + random() % 20;
        for (size_t i = 0; i < count; ++i) {
            const auto kind = random() % 8;
            const auto id = "n" + std::to_string(random() % count);
            const auto other = random() % 5 ? "n" + std::to_string(random() % count) : std::string(random() % 2 ? "" : "ghost");
            if (kind == 0) graph.push_back(metadata(i));
            else if (kind == 1) graph.push_back(boundary(i, id, other));
            else if (kind == 2) graph.push_back(context(i, id, random() % 5 ? other : "", random() % 3 == 0));
            else graph.push_back(user(i, id, random() % 6 ? other : "", random() % 4 != 0));
        }
        // Keep most scenarios parent-linked to the previous node, as real
        // transcripts are, so linear and lazy proofs both run.
        if (scenario % 2) for (size_t i = 0, previous = SIZE_MAX; i < graph.size(); ++i) {
            if (!graph[i].node) continue;
            graph[i].id = "m" + std::to_string(i);
            if (!graph[i].boundary) graph[i].parent = previous == SIZE_MAX ? "" : graph[previous].id;
            else if (const auto choice = random() % 4; choice == 0 && previous != SIZE_MAX) graph[i].logicalParent = graph[previous].id;
            else if (choice == 1) graph[i].logicalParent = "m" + std::to_string(random() % (i + 1)); // earlier or self
            else if (choice == 2) graph[i].logicalParent = "m" + std::to_string(i + 1 + random() % 3); // later
            previous = i;
        }
        const auto offsets = writeGraph(graph);
        std::vector<size_t> expected; bool expectedFailure = false;
        try { expected = selection(graph, Index::chain(graph, {}, true)); }
        catch (const std::runtime_error&) { expectedFailure = true; }
        for (const size_t budget : {size_t(128), size_t(128 * 1024 * 1024)}) {
            tessera::JsonlReader reader(filename, "claude"); Index index;
            bool failed = false;
            try {
                refreshIndex(index, reader, {}, budget);
                assert(!expectedFailure && index.size() == expected.size());
                for (size_t i = 0; i < expected.size(); ++i) assert(index.entry(reader, i).start == offsets[expected[i]]);
            } catch (const std::runtime_error& error) { assert(std::string(error.what()) == "claudeIndexUnproven"); failed = true; }
            assert(failed == expectedFailure);
        }
    }
    // Appends through a compaction keep cursors valid when the published
    // prefix is unchanged, and invalidate them when it is not.
    for (const size_t budget : {size_t(128), size_t(128 * 1024 * 1024)}) {
        auto append = [&](const Graph& rows) { std::ofstream file(filename, std::ios::app); for (const auto& row : rows) file << lineFor(row); };
        auto ids = [&](Index& index) {
            tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {}, budget);
            std::vector<std::string> result;
            for (size_t i = 0; i < index.size(); ++i) result.push_back(index.entry(reader, i).id);
            return result;
        };
        auto extends = [](const std::vector<std::string>& before, const std::vector<std::string>& after) {
            return after.size() > before.size() && std::equal(before.begin(), before.end(), after.begin());
        };
        for (const bool metadataAfterBoundary : {false, true}) {
            { std::ofstream file(filename); }
            append({user(0, "u0", ""), metadata(1), user(2, "a0", "u0")});
            Index index; const auto initial = ids(index); const auto generation = index.generation();
            // The boundary alone has no authored leaf: prior history remains
            // selected, and the tail waits for the compact summary.
            append({boundary(3, "b", "a0"), context(4, "att", "b")});
            if (metadataAfterBoundary) append({metadata(5)});
            const auto pending = ids(index);
            assert(index.generation() == generation && (pending == initial || extends(initial, pending)));
            append({user(6, "s", "att"), user(7, "a1", "s")});
            const auto compacted = ids(index);
            assert(std::count(compacted.begin(), compacted.end(), "u0") == 1 && compacted.back() == "a1");
            // Inserting the deferred tail before published metadata is not an
            // append; with no such metadata it is, and cursors survive.
            assert(metadataAfterBoundary ? index.generation() != generation : index.generation() == generation);
            if (!metadataAfterBoundary) assert(extends(pending, compacted));
            const auto stable = index.generation();
            append({user(8, "u2", "a1")});
            assert(extends(compacted, ids(index)) && index.generation() == stable);
        }
        // An earlier logical parent drops the /compact command branch.
        { std::ofstream file(filename); }
        append({user(0, "u0", ""), user(1, "a0", "u0"), user(2, "command", "a0")});
        Index index; const auto before = ids(index); const auto generation = index.generation();
        assert(before.back() == "command");
        append({boundary(3, "b", "a0"), user(4, "s", "b")});
        const auto after = ids(index);
        assert(index.generation() != generation && after == (std::vector<std::string>{"u0", "a0", "b", "s"}));
        // A boundary published before its summary, behind a sidechain record
        // (so not linear): the deferred tail is still an append.
        {
            { std::ofstream file(filename); }
            append({user(0, "u0", ""), user(1, "side", "u0", false), user(2, "a0", "u0")});
            Index index; const auto initial = ids(index); const auto generation = index.generation();
            append({boundary(3, "b", "a0")});
            assert(ids(index) == initial && index.generation() == generation);
            append({user(4, "s", "b"), user(5, "a1", "s")});
            assert(ids(index) == (std::vector<std::string>{"u0", "a0", "b", "s", "a1"}) && index.generation() == generation);
        }
        // Revising a published boundary's logical parent after the boundary
        // moves it to the positional parent: nothing is appended to the path,
        // but the selection changes.
        {
            { std::ofstream file(filename); }
            append({user(0, "A", ""), user(1, "L", "A"), user(2, "X", ""), user(3, "P", "X"), boundary(4, "B", "L"),
                user(5, "S", "B"), user(6, "T", "S")});
            Index index; assert(ids(index) == (std::vector<std::string>{"A", "L", "B", "S", "T"}));
            const auto generation = index.generation();
            append({context(7, "L", "A")});
            assert(ids(index) == (std::vector<std::string>{"X", "P", "B", "S", "T"}) && index.generation() != generation);
        }
        // A logical parent first written after publication (not a revision)
        // leaves a published boundary's choice, and cursors, unchanged.
        {
            { std::ofstream file(filename); }
            append({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "late"), user(3, "s", "b"), user(4, "a1", "s")});
            Index index; const auto before = ids(index); const auto generation = index.generation();
            append({context(5, "late", "b")});
            assert(ids(index) == before && index.generation() == generation);
        }
        // A revision that stops the path early changes the selection; a later
        // append to the same stopped path keeps it.
        {
            { std::ofstream file(filename); }
            append({user(0, "u0", ""), user(1, "a0", "u0"), boundary(2, "b", "a0"), user(3, "s", "b"), user(4, "t", "s")});
            Index index; assert(ids(index) == (std::vector<std::string>{"u0", "a0", "b", "s", "t"}));
            auto generation = index.generation();
            append({context(5, "u0", "s")});
            assert(ids(index) == (std::vector<std::string>{"a0", "b", "s", "t"}) && index.generation() != generation);
            generation = index.generation();
            append({user(6, "u1", "t")});
            assert(ids(index) == (std::vector<std::string>{"a0", "b", "s", "t", "u1"}) && index.generation() == generation);
        }
        // With only metadata published, a first authored message that
        // selects an earlier context node ahead of that metadata is not an
        // append (the sidechain record keeps this out of the linear proof).
        {
            { std::ofstream file(filename); }
            append({context(0, "c0", ""), metadata(1)});
            Index index; assert(ids(index).size() == 1);
            const auto generation = index.generation();
            append({user(2, "side", "c0", false), user(3, "u", "c0")});
            assert(ids(index) == (std::vector<std::string>{"c0", "", "u"}) && index.generation() != generation);
        }
    }
    // Yielding readers must resume boundary resolution: a missing logical
    // name scans the whole file and a sidechain run forces a long backward
    // positional scan, each longer than one 64-record slice. (Each sidechain
    // record parents its predecessor: compact reconstruction's separate
    // non-adjacent parent lookup is not what this case measures.)
    {
        Graph graph{user(0, "u0", ""), user(1, "a0", "u0")};
        for (size_t i = 2; i < 90; ++i) graph.push_back(user(i, "side" + std::to_string(i), i == 2 ? "a0" : "side" + std::to_string(i - 1), false));
        graph.push_back(boundary(90, "b", "ghost"));
        graph.push_back(user(91, "s", "b")); graph.push_back(user(92, "a1", "s"));
        const auto offsets = writeGraph(graph);
        const auto expected = selection(graph, Index::chain(graph, {}, true));
        assert(expected == (std::vector<size_t>{0, 1, 90, 91, 92}));
        for (const size_t budget : {size_t(128), size_t(4096), size_t(128 * 1024 * 1024)}) {
            Index index; size_t yields = 0;
            auto reader = [&] {
                return std::make_unique<tessera::JsonlReader>(filename, "claude", -1, std::function<bool()>(),
                    [remaining = size_t(64)](simdjson::dom::element value, bool truncated) mutable {
                        if (!remaining) throw std::runtime_error("readPending");
                        --remaining; return tessera::normalize("claude", value, truncated);
                    });
            };
            for (;;) {
                auto input = reader();
                try { index.refresh(*input, {}, budget); break; }
                catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 10000); }
            }
            assert(index.size() == expected.size() && yields);
            for (size_t ordinal = 0; ordinal < index.size(); ++ordinal) {
                for (;;) {
                    auto input = reader();
                    try { assert(index.entry(*input, ordinal).start == offsets[expected[ordinal]]); break; }
                    catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 10000); }
                }
            }
        }
    }
    // A non-monotone lazy path interleaves metadata by its ancestry maximum.
    // That walk spans several yielded slices; paging must still converge.
    {
        Graph graph{user(0, "r", "")};
        for (uint64_t i = 1; i <= 40; ++i) graph.push_back(metadata(i));
        graph.push_back(user(41, "c", "p")); graph.push_back(user(42, "p", "r"));
        for (uint64_t i = 43; i <= 80; ++i) graph.push_back(metadata(i));
        graph.push_back(user(81, "t", "c"));
        const auto offsets = writeGraph(graph);
        const auto expected = selection(graph, Index::chain(graph, {}, true));
        assert(expected.size() == graph.size() && expected[41] == 42 && expected[42] == 41);
        // A walk whose record count is a multiple of the slice would be
        // restarted forever if its result were discarded at a yield. (One
        // record cannot hold a lazy scan step's page and record reads.)
        for (size_t slice = 2; slice <= 24; ++slice) {
            Index index; size_t yields = 0;
            auto reader = [&] {
                return std::make_unique<tessera::JsonlReader>(filename, "claude", -1, std::function<bool()>(),
                    [remaining = slice](simdjson::dom::element value, bool truncated) mutable {
                        if (!remaining) throw std::runtime_error("readPending");
                        --remaining; return tessera::normalize("claude", value, truncated);
                    });
            };
            for (;;) {
                auto input = reader();
                try { index.refresh(*input, {}, 128); break; }
                catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 20000); }
            }
            assert(index.lazy() && !index.linear() && index.size() == expected.size());
            for (size_t ordinal = index.size(); ordinal-- > 0;) {
                for (;;) {
                    auto input = reader();
                    try { assert(index.entry(*input, ordinal).start == offsets[expected[ordinal]]); break; }
                    catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 20000); }
                }
            }
        }
    }
    // Pi keeps its persisted active branch and version-specific identities.
    for (unsigned version : {1U, 2U, 3U}) {
        { std::ofstream file(filename); file << "{\"type\":\"session\",\"version\":" << version << ",\"id\":\"synthetic\"}\n";
          for (size_t i = 0; i < 48; ++i) {
              file << "{\"type\":\"message\",";
              if (version > 1) file << "\"id\":\"p" << i << "\",\"parentId\":" << (i ? "\"p" + std::to_string(i - 1) + "\"" : "null") << ",";
              file << "\"message\":{\"role\":\"user\",\"content\":\"synthetic\"}}\n";
          }
        }
        for (size_t budget : {size_t(4096), size_t(128 * 1024 * 1024)}) {
            tessera::JsonlReader reader(filename, "pi"); Index index;
            index.refresh(reader, {}, budget, true, "synthetic");
            assert(index.size() == 49 && index.entry(reader, 0).id == "synthetic");
            for (size_t i = 1; i < index.size(); ++i) {
                const auto value = index.entry(reader, i);
                assert(version == 1 ? value.id == "v1:" + std::to_string(value.start) : value.id == "p" + std::to_string(i - 1));
            }
        }
    }
    for (const auto parentID : {"missing", "good"}) {
        { std::ofstream file(filename); file << "{\"type\":\"session\",\"version\":3,\"id\":\"synthetic\"}\n" <<
            "{\"type\":\"message\",\"id\":\"bad\",\"parentId\":\"" << parentID << "\",\"message\":{\"role\":\"user\",\"content\":\"bad\"}}\n" <<
            "{\"type\":\"message\",\"id\":\"good\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"good\"}}\n"; }
        for (const size_t budget : {size_t(128), size_t(128 * 1024 * 1024)}) {
            tessera::JsonlReader reader(filename, "pi"); Index index; bool rejected = false;
            try { index.refresh(reader, {}, budget, true, "synthetic"); }
            catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "piChainUnproven"; }
            assert(rejected);
        }
    }
    // Restore a valid source for the cache ownership checks.
    { std::ofstream file(filename); file << first << second; }
    // Every JSONL index family must retain a yielded reader's scan across
    // unrelated-client cache churn, then release that admission on completion.
    // Claude and Pi share this cache; Kimi uses its own bounded replay cache.
    auto pendingCache = [&](auto& cache, auto refresh) {
        refresh(cache.get("pending-scan"));
        const auto generation = cache.get("pending-scan").generation();
        assert(!generation.empty());
        cache.pending(cache.readPaths()); cache.beginRead();
        for (size_t i = 0; i < 30; ++i) {
            cache.get("other-client-" + std::to_string(i)); cache.beginRead();
        }
        assert(cache.get("pending-scan").generation() == generation);
        std::set<std::string> pending;
        for (size_t i = 0; i < 24; ++i) {
            cache.beginRead();
            const auto key = "queued-scan-" + std::to_string(i);
            cache.get(key); pending.insert(key); cache.pending(pending);
        }
        cache.beginRead();
        // Twenty-four is an eviction target, not an active-history limit.
        const auto retainedGeneration = cache.get("queued-scan-0").generation();
        cache.get("over-target");
        assert(cache.get("queued-scan-0").generation() == retainedGeneration);
        cache.pending({}); cache.beginRead(); cache.get("released-scan");
    };
    tessera::ClaudeChainCache claudeCache;
    pendingCache(claudeCache, [&](auto& index) {
        tessera::JsonlReader reader(filename, "claude"); refreshIndex(index, reader, {});
    });
    { std::ofstream file(filename); file <<
        R"({"type":"metadata","protocol_version":"1.5"})" "\n"
        R"({"type":"context.append_message","message":{"id":"m","role":"user","content":[{"type":"text","text":"synthetic"}]}})" "\n"; }
    tessera::KimiHistoryCache kimiCache;
    pendingCache(kimiCache, [&](auto& index) {
        tessera::JsonlReader reader(filename, "kimi", -1, {}, tessera::KimiHistoryIndex::metadata);
        index.refresh(reader, {}, 4 * 1024 * 1024);
    });

    // Compare a service-style append refresh (new reader, retained index) to
    // rebuilding the same source from scratch. A failed proof has no published
    // selection to compare; the next successful refresh starts a new baseline.
    size_t smallGenerationChecks[2]{}, smallGenerationDifferences[2]{}; // linear, lazy
    auto compareFresh = [&](Index& retained, size_t budget, bool& previousSuccess,
                            std::vector<uint64_t>& previousStarts, std::string& previousGeneration) {
        using Snapshot = std::pair<std::string, std::vector<std::pair<uint64_t, std::string>>>;
        auto snapshot = [&](Index& value) -> Snapshot {
            tessera::JsonlReader reader(filename, "claude");
            Snapshot result;
            try {
                refreshIndex(value, reader, {}, budget);
                for (size_t i = 0; i < value.size(); ++i) {
                    const auto entry = value.entry(reader, i);
                    result.second.emplace_back(entry.start, entry.id);
                }
            } catch (const std::runtime_error& error) { result.first = error.what(); }
            return result;
        };
        const auto actual = snapshot(retained);
        Index fresh;
        const auto expected = snapshot(fresh);
        assert(actual.first == expected.first);
        if (!actual.first.empty()) { previousSuccess = false; return; }
        assert(retained.size() == fresh.size());
        assert(actual.second == expected.second);
        std::vector<uint64_t> starts;
        for (const auto& entry : actual.second) starts.push_back(entry.first);
        if (previousSuccess) {
            const bool prefix = starts.size() >= previousStarts.size() &&
                std::equal(previousStarts.begin(), previousStarts.end(), starts.begin());
            const bool changed = retained.generation() != previousGeneration;
            if (budget == 128 * 1024 * 1024) assert(changed == !prefix);
            else if (retained.lazy()) {
                const size_t mode = retained.linear() ? 0 : 1;
                ++smallGenerationChecks[mode];
                smallGenerationDifferences[mode] += changed != !prefix;
            }
        }
        // Lazy and linear modes retain a path/count proof rather than the
        // compact mode's selected-offset vector, so compare their publication
        // with a fresh index but do not impose compact generation semantics.
        previousStarts = std::move(starts);
        previousGeneration = retained.generation();
        previousSuccess = true;
    };
    auto mixedLine = [&](const Index::Entry& value) {
        auto line = lineFor(value);
        if (value.message && value.start % 2) {
            const auto type = line.find("\"type\":\"user\"");
            const auto role = line.find("\"role\":\"user\"");
            assert(type != std::string::npos && role != std::string::npos);
            line.replace(role, 13, "\"role\":\"assistant\"");
            line.replace(type, 13, "\"type\":\"assistant\"");
        }
        return line;
    };
    auto appendGraph = [&](const Graph& graph, size_t begin, size_t end, bool mixed = false) {
        std::ofstream file(filename, std::ios::app);
        for (size_t i = begin; i < end; ++i) file << (mixed ? mixedLine(graph[i]) : lineFor(graph[i]));
    };
    // Fixed-seed histories put metadata between nodes, then append 1-3 rows
    // per refresh. The cases mix linked turns with revisions, late parents,
    // forward references, cycles, boundaries, context and sidechains.
    std::mt19937 appendRandom(0x41505045);
    const auto differentialStart = std::chrono::steady_clock::now();
    for (size_t scenario = 0; scenario < 300; ++scenario) {
        Graph graph;
        const size_t nodeCount = 6 + appendRandom() % 2;
        const size_t splitNode = nodeCount - 1 - (appendRandom() % 5 == 0 ? 1 : 0);
        size_t split = 0;
        std::string prior;
        for (size_t node = 0; node < nodeCount; ++node) {
            if (node) for (size_t m = 0, count = 2 + (appendRandom() % 8 == 0 ? 1 : 0); m < count; ++m)
                graph.push_back(metadata(graph.size()));
            std::string id = "n" + std::to_string(node);
            if (scenario % 6 == 0 && (node == 2 || node == nodeCount - 1)) id = "n1";
            if (scenario % 6 == 1 && node == nodeCount - 1) id = "ghost";
            std::string parent = prior;
            if (scenario % 6 == 1 && node == 2) parent = "ghost";
            if (scenario % 6 == 2 && node == 2) parent = "n" + std::to_string(nodeCount - 1);
            if (scenario % 6 == 3 && node == 2) parent = "n3";
            if (scenario % 6 == 3 && node == 3) parent = "n2";
            if (scenario % 6 >= 4 && node > 2 && appendRandom() % 5 == 0)
                parent = appendRandom() % 2 ? "n0" : "ghost";
            const size_t kind = node && appendRandom() % 7 == 0 ? 1 : appendRandom() % 6 == 0 ? 2 : 0;
            if (kind == 1) {
                const size_t choice = (scenario + node) % 6;
                const std::string logical = choice == 0 ? prior : choice == 1 ? "n0" :
                    choice == 2 ? id : choice == 3 ? "ghost-logical" :
                    choice == 4 ? "n" + std::to_string(node + 1) : "";
                graph.push_back(boundary(graph.size(), id, logical));
            } else if (kind == 2) graph.push_back(context(graph.size(), id, parent, appendRandom() % 4 == 0));
            else graph.push_back(user(graph.size(), id, parent, appendRandom() % 5 != 0));
            prior = id;
            if (node + 1 == splitNode) split = graph.size();
        }
        std::vector<size_t> appendCuts;
        for (size_t cursor = split; cursor < graph.size();) {
            const auto choice = appendRandom() % 8;
            cursor = std::min(graph.size(), cursor + (choice < 6 ? 3 : choice - 5));
            appendCuts.push_back(cursor);
        }
        { std::ofstream file(filename); for (size_t i = 0; i < split; ++i) file << mixedLine(graph[i]); }
        for (const size_t budget : {size_t(128 * 1024 * 1024), size_t(4096), size_t(128)}) {
            // Recreate the same prefix for each strategy.
            if (budget != 128 * 1024 * 1024) {
                std::ofstream file(filename);
                for (size_t i = 0; i < split; ++i) file << mixedLine(graph[i]);
            }
            Index retained;
            bool previousSuccess = false;
            std::vector<uint64_t> previousStarts;
            std::string previousGeneration;
            compareFresh(retained, budget, previousSuccess, previousStarts, previousGeneration);
            size_t cursor = split;
            for (const auto end : appendCuts) {
                appendGraph(graph, cursor, end, true); cursor = end;
                compareFresh(retained, budget, previousSuccess, previousStarts, previousGeneration);
            }
        }
    }
    std::cerr << "claude-chain append differential: 300 scenarios, " <<
        std::chrono::duration<double>(std::chrono::steady_clock::now() - differentialStart).count() << "s; " <<
        "linear generation differences=" << smallGenerationDifferences[0] << "/" << smallGenerationChecks[0] <<
        " lazy differences=" << smallGenerationDifferences[1] << "/" << smallGenerationChecks[1] << '\n';
    // Targeted transitions guard the full-rebuild fallback and a boundary's
    // deferred summary. Each intermediate append is checked independently.
    auto checkStages = [&](const Graph& graph, const std::vector<size_t>& cuts, bool preserveGeneration = false) {
        { std::ofstream file(filename); for (size_t i = 0; i < cuts.front(); ++i) file << lineFor(graph[i]); }
        Index retained; bool previousSuccess = false;
        std::vector<uint64_t> previousStarts; std::string previousGeneration;
        compareFresh(retained, 128 * 1024 * 1024, previousSuccess, previousStarts, previousGeneration);
        const auto initialGeneration = retained.generation();
        for (size_t stage = 1; stage < cuts.size(); ++stage) {
            appendGraph(graph, cuts[stage - 1], cuts[stage]);
            compareFresh(retained, 128 * 1024 * 1024, previousSuccess, previousStarts, previousGeneration);
        }
        if (preserveGeneration) assert(retained.generation() == initialGeneration);
    };
    checkStages({user(0, "root", ""), user(1, "other", "root"), user(2, "old", "root"),
        user(3, "leaf", "old"), user(4, "old", "other"), user(5, "next", "old")}, {4, 5, 6});
    checkStages({user(0, "root", ""), user(1, "child", "ghost"), user(2, "leaf", "child"),
        user(3, "ghost", "root"), user(4, "next", "leaf")}, {3, 4, 5});
    checkStages({user(0, "root", ""), user(1, "leaf", "root"), boundary(2, "b", "leaf"),
        user(3, "summary", "b"), user(4, "next", "summary"), user(5, "tail", "next")}, {2, 3, 4, 6}, true);
    checkStages({user(0, "root", ""), user(1, "leaf", "root"), user(2, "side", "leaf", false),
        user(3, "side-child", "side", false), user(4, "main", "leaf")}, {2, 3, 4, 5});

    // About 3,000 Claude-shaped rows, with three uuid-less metadata records
    // between turns and a 64 KiB text body on every tenth user/assistant node.
    // Validation may reread the old prefix once; graph reconstruction should
    // read only newly appended records after a complete compact build.
    uint64_t costFileSize = 0;
    std::string lastID;
    {
        std::ofstream file(filename);
        for (size_t i = 0; i < 750; ++i) {
            if (i) for (size_t m = 0; m < 3; ++m) {
                const auto row = lineFor(metadata(0)); file << row; costFileSize += row.size();
            }
            const auto id = "cost" + std::to_string(i);
            const auto role = i % 2 ? "assistant" : "user";
            const auto payload = i % 10 == 0 ? std::string(64 * 1024, 'x') : std::string("synthetic");
            std::ostringstream row;
            row << "{\"type\":\"" << role << "\",\"uuid\":\"" << id << "\",\"parentUuid\":" <<
                (i ? "\"" + lastID + "\"" : "null") <<
                ",\"sessionId\":\"s\",\"isSidechain\":false,\"message\":{\"role\":\"" << role <<
                "\",\"content\":[{\"type\":\"text\",\"text\":\"" << payload << "\"}]}}\n";
            const auto line = row.str(); file << line; costFileSize += line.size(); lastID = id;
        }
    }
    Index costIndex;
    uint64_t coldRead = 0;
    { tessera::JsonlReader reader(filename, "claude"); refreshIndex(costIndex, reader, {}, 128 * 1024 * 1024);
      coldRead = reader.bytesRead(); assert(costIndex.size() == 2997); }
    const auto appended = lineFor(user(0, "cost-tail", lastID));
    { std::ofstream file(filename, std::ios::app); file << appended; }
    uint64_t appendRead = 0;
    { tessera::JsonlReader reader(filename, "claude"); refreshIndex(costIndex, reader, {}, 128 * 1024 * 1024);
      appendRead = reader.bytesRead(); assert(costIndex.size() == 2998); }
    const auto appendBound = costFileSize + 4 * appended.size() + 1024 * 1024;
    std::cerr << "claude-chain read cost: cold=" << coldRead << "/" << costFileSize <<
        " append=" << appendRead << "/" << appendBound << " appendBytes=" << appended.size() << '\n';
    assert(appendRead <= appendBound);
    assert(coldRead * 2 <= costFileSize * 9);
    // Fixed costs count against the budget: long UUIDs never grow the
    // recent-UUID ring beyond what a compact index reserves for it.
    for (const size_t rows : {size_t(16), size_t(64)}) {
        { std::ofstream file(filename);
          for (size_t i = 0; i < rows; ++i) file << lineFor(user(i, "id" + std::to_string(i) + std::string(240, 'q'), "")); }
        tessera::JsonlReader reader(filename, "claude"); Index index;
        refreshIndex(index, reader, {}, 16384);
        assert(index.bytes() <= 16384);
    }
    ::unlink(filename);
}
