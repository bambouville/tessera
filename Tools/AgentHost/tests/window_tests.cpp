#include "PageWindow.h"
#include <cassert>
#include <functional>
#include <iostream>

using namespace tessera;
PageWindow::Segment segment(int start, int total = 1000) {
    auto value = std::make_shared<WindowSegment>();
    value->id = "s" + std::to_string(start); value->source = "source";
    value->before = "b" + std::to_string(start); value->after = "a" + std::to_string(start + 100);
    value->hasOlder = start != 0; value->hasNewer = start + 100 < total;
    for (int index = start; index < start + 100; ++index) {
        PositionedRecord record; record.start = index; record.revision = 1;
        record.value.providerID = "r" + std::to_string(index); record.value.json = "{\"text\":\"synthetic\"}";
        value->records.push_back(record);
    }
    return value;
}
void rejects(const std::function<void()>& operation) {
    bool rejected = false;
    try { operation(); } catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
}
void rejectsWith(const std::string& code, const std::function<void()>& operation) {
    std::string actual;
    try { operation(); } catch (const std::runtime_error& error) { actual = error.what(); }
    assert(actual == code);
}
int main() {
    {
        // window.capacity.v1: the advertised viewport is 64 full pages plus a
        // detached head. The legacy 4-segment/400-record bound no longer applies.
        static_assert(PageWindow::maximumViewportSegments == 64, "hello maxWindowSegments contract");
        static_assert(PageWindow::viewportLimit == 64 * PageWindow::pageLimit, "viewport byte bound");
        static_assert(PageWindow::retainedLimit == 65 * PageWindow::pageLimit, "viewport plus detached head");
        const int total = 100 * 66;
        auto page = [&](int start) {
            auto value = std::make_shared<WindowSegment>(*segment(start, total));
            value->source = "codex-appserver:capacity";
            return PageWindow::Segment(value);
        };
        PageWindow large;
        const auto head = "s" + std::to_string(total - 100);
        large.reserve("head", 0, PageWindow::Kind::Bootstrap); large.stage(page(total - 100));
        large.acknowledge("head", 1, {head}, head);
        std::vector<std::string> viewport{head};
        for (int start = total - 200; viewport.size() < PageWindow::maximumViewportSegments; start -= 100) {
            const auto transaction = "large" + std::to_string(start);
            large.reserve(transaction, large.version()); large.stage(page(start));
            viewport.insert(viewport.begin(), "s" + std::to_string(start));
            large.acknowledge(transaction, large.version() + 1, viewport, head);
        }
        size_t records = 0;
        for (const auto& id : large.viewport()) records += large.find(id)->records.size();
        assert(large.viewport() == viewport && viewport.size() == 64);
        assert(records == PageWindow::maximumViewportSegments * 100 && records > 400);
        assert(large.retainedBytes() <= PageWindow::viewportLimit);
        // A 65-segment ACK is a capacity error and leaves the transaction and
        // committed coverage intact; the contiguous 64-segment ACK then commits.
        const auto extra = "s" + std::to_string(total - 100 * 65);
        const auto committed = large.version();
        large.reserve("overflow", committed); large.stage(page(total - 100 * 65));
        auto oversized = viewport; oversized.insert(oversized.begin(), extra);
        rejectsWith("windowCapacity", [&] { large.acknowledge("overflow", committed + 1, oversized, head); });
        assert(large.version() == committed && large.viewport() == viewport && large.pending());
        oversized.pop_back();
        large.acknowledge("overflow", committed + 1, oversized, head);
        assert(large.viewport().size() == 64 && large.coverage().size() == 65 && large.find(head));
        assert(large.retainedBytes() <= PageWindow::retainedLimit);
        // A revision ACK over the full window rewrites only patched segments.
        const auto untouched = large.find(extra);
        const auto target = large.find("s3000");
        std::vector<PositionedRecord> patches{target->records[7]};
        patches.front().revision = 2; patches.front().value.json = "{\"text\":\"revised\"}";
        size_t serial = 0; auto newID = [&] { return "capacity" + std::to_string(++serial); };
        large.reserve("revise", large.version(), PageWindow::Kind::Revisions); large.stageRevisions(patches, newID);
        assert(large.partitions().empty());
        large.acknowledge("revise", large.version() + 1, oversized, head);
        assert(large.find(extra) == untouched && large.find("s3000") != target);
        assert(large.find("s3000")->records[7].revision == 2 && large.find("s3000")->records[6].revision == 1);
        assert(large.coverage().size() == 65);
    }
    // Service-wide retained budget. ReadWorker passes every window's summed
    // footprint(): committed pages plus staged, unacknowledged pages/revisions.
    static_assert(PageWindow::serviceGrowthLimit == 64 * 1024 * 1024, "64 MiB service growth budget");
    static_assert(PageWindow::serviceRefreshLimit == PageWindow::serviceGrowthLimit +
        2 * PageWindow::maximumServiceWindows * PageWindow::pageLimit, "detached head plus in-flight refresh per window slot");
    auto anchored = [](int start, size_t text, const std::string& source) {
        auto value = std::make_shared<WindowSegment>(*segment(start, 1 << 30));
        value->source = source;
        for (auto& record : value->records) {
            record.value.json = "{\"text\":\"" + std::string(text, 'b') + "\"}";
            WindowRecordAnchors anchors;
            for (auto* anchor : {&anchors.before, &anchors.after, &anchors.reread}) {
                anchor->source = source; anchor->providerCursor = "c" + std::to_string(record.start);
            }
            value->anchors.push_back(anchors);
        }
        return value;
    };
    const auto id = [](int start) { return "s" + std::to_string(start); };
    {
        // Several clients page deep history until the whole service is at the
        // budget; growth is refused there, while live refreshes still commit.
        const int top = 1 << 20;
        auto bulky = [&](int start) {
            auto value = anchored(start, 1900, "codex-appserver:budget");
            assert(value->bytes() > PageWindow::pageLimit - 32768 && value->bytes() <= PageWindow::pageLimit);
            return PageWindow::Segment(value);
        };
        std::vector<PageWindow> service(5);
        std::vector<std::vector<std::string>> viewports(service.size());
        auto total = [&] { size_t value = 0; for (const auto& window : service) value += window.footprint(); return value; };
        for (size_t index = 0; index < service.size(); ++index) {
            service[index].reserve("boot", 0, PageWindow::Kind::Bootstrap, total());
            service[index].stage(bulky(top)); viewports[index] = {id(top)};
            service[index].acknowledge("boot", 1, viewports[index], id(top));
        }
        size_t pages = service.size(); bool refused = false;
        for (int start = top - 100; !refused; start -= 100) {
            for (size_t index = 0; index < service.size() && !refused; ++index) {
                auto& window = service[index];
                const auto before = total(); const auto version = window.version();
                const auto transaction = "grow" + std::to_string(start);
                try { window.reserve(transaction, version, PageWindow::Kind::Before, before); }
                catch (const std::runtime_error& error) {
                    // Refused before any I/O, and only when one more full page cannot fit.
                    assert(std::string(error.what()) == "windowCapacity");
                    assert(before <= PageWindow::serviceGrowthLimit && before + PageWindow::pageLimit > PageWindow::serviceGrowthLimit);
                    assert(!window.pending() && window.version() == version && total() == before);
                    refused = true; break;
                }
                window.stage(bulky(start));
                assert(window.pendingBytes() > 0 && total() == before + window.pendingBytes());
                viewports[index].insert(viewports[index].begin(), id(start));
                window.acknowledge(transaction, version + 1, viewports[index], id(top));
                assert(total() <= PageWindow::serviceGrowthLimit);
                ++pages;
            }
        }
        // About 264 near-full pages: far past the old 24 x 5-page service total,
        // yet no window reached its own 64-segment limit.
        assert(pages > 250);
        for (const auto& viewport : viewports) assert(viewport.size() < PageWindow::maximumViewportSegments);
        const auto full = total();
        for (auto& window : service) {
            rejectsWith("windowCapacity", [&] { window.reserve("older", window.version(), PageWindow::Kind::Before, full); });
            rejectsWith("windowCapacity", [&] { window.reserve("newer", window.version(), PageWindow::Kind::After, full); });
        }
        PageWindow another;
        rejectsWith("windowCapacity", [&] { another.reserve("new", 0, PageWindow::Kind::Bootstrap, full); });
        assert(total() == full);
        // A live head refresh still commits at the budget. A scrolled-back
        // client keeps its history viewport and retains the new head detached.
        auto& live = service.front();
        live.reserve("live1", live.version(), PageWindow::Kind::Head, total());
        live.stage(bulky(top + 100));
        const auto admitted = total();
        live.acknowledge("live1", live.version() + 1, viewports.front(), id(top + 100));
        const auto detached = total();
        assert(detached <= admitted && !PageWindow::fits(detached, PageWindow::serviceGrowthLimit));
        // The next refresh replaces that detached head: no further growth.
        live.reserve("live2", live.version(), PageWindow::Kind::Head, total());
        live.stage(bulky(top + 200));
        live.acknowledge("live2", live.version() + 1, viewports.front(), id(top + 200));
        assert(total() == detached);
        // A revision sweep also commits at the budget, here splitting a full
        // retained page; its ACK stays within what was staged.
        std::vector<PositionedRecord> patches{live.find(id(top))->records[10]};
        patches.front().revision = 2; patches.front().value.json = "{\"text\":\"" + std::string(4000, 'r') + "\"}";
        size_t serial = 0; auto newID = [&] { return "budget" + std::to_string(++serial); };
        const auto beforeRevision = total(), committed = live.retainedBytes();
        live.reserve("revise", live.version(), PageWindow::Kind::Revisions, beforeRevision);
        assert(live.stageRevisionPrefix(patches, newID) == 1 && !live.partitions().empty());
        const auto pendingRevision = live.pendingBytes();
        assert(total() == beforeRevision + pendingRevision);
        std::vector<std::string> split;
        for (const auto& segmentID : viewports.front()) {
            bool replaced = false;
            for (const auto& part : live.partitions()) if (part.original == segmentID) { split.push_back(part.id); replaced = true; }
            if (!replaced) split.push_back(segmentID);
        }
        live.acknowledge("revise", live.version() + 1, split, id(top + 200));
        assert(live.retainedBytes() > committed && live.retainedBytes() <= committed + pendingRevision);
        bool revised = false;
        for (const auto& value : live.coverage()) for (const auto& record : value->records)
            if (record.start == static_cast<uint64_t>(top + 10)) revised = record.revision == 2;
        assert(revised);
        // A re-bootstrap (the clients' Retry) replaces its window's committed
        // pages, so it is admitted at the budget and frees that history.
        auto& reader = service[1];
        const auto own = reader.retainedBytes(), crowded = total();
        rejectsWith("windowCapacity", [&] { another.reserve("new", 0, PageWindow::Kind::Bootstrap, crowded); });
        reader.reserve("rebootstrap", 0, PageWindow::Kind::Bootstrap, crowded);
        reader.stage(bulky(top + 300));
        reader.acknowledge("rebootstrap", 1, {id(top + 300)}, id(top + 300));
        assert(reader.retainedBytes() <= PageWindow::pageLimit && total() == crowded - own + reader.retainedBytes());
        another.reserve("new", 0, PageWindow::Kind::Bootstrap, total());
        another.stage(bulky(top)); another.acknowledge("new", 1, {id(top)}, id(top));
        service[2].reserve("again", service[2].version(), PageWindow::Kind::Before, total() + another.footprint());
        service[2].cancel();
    }
    {
        // Exact admission edges for each lane.
        const auto page = PageWindow::pageLimit;
        PageWindow edge;
        edge.reserve("boot", 0, PageWindow::Kind::Bootstrap); edge.stage(segment(0)); edge.acknowledge("boot", 1, {"s0"}, "s0");
        rejectsWith("windowCapacity", [&] { edge.reserve("g", 1, PageWindow::Kind::Before, PageWindow::serviceGrowthLimit - page + 1); });
        edge.reserve("g", 1, PageWindow::Kind::Before, PageWindow::serviceGrowthLimit - page); edge.cancel();
        edge.reserve("h", 1, PageWindow::Kind::Head, PageWindow::serviceGrowthLimit); edge.cancel();
        edge.reserve("h", 1, PageWindow::Kind::Head, PageWindow::serviceRefreshLimit - page); edge.cancel();
        rejectsWith("windowCapacity", [&] { edge.reserve("h", 1, PageWindow::Kind::Head, PageWindow::serviceRefreshLimit - page + 1); });
        edge.reserve("r", 1, PageWindow::Kind::Revisions, PageWindow::serviceRefreshLimit - page); edge.cancel();
        rejectsWith("windowCapacity", [&] { edge.reserve("r", 1, PageWindow::Kind::Revisions, PageWindow::serviceRefreshLimit - page + 1); });
        // A small window's re-bootstrap cannot free a page, so it is growth.
        rejectsWith("windowCapacity", [&] { edge.reserve("b", 0, PageWindow::Kind::Bootstrap, PageWindow::serviceGrowthLimit); });
        edge.reserve("b", 0, PageWindow::Kind::Bootstrap, PageWindow::serviceGrowthLimit - page); edge.cancel();
        assert(!edge.pending() && edge.version() == 1 && edge.pendingBytes() == 0);
    }
    {
        // Staged but unacknowledged pages count, so a burst of reads from
        // several clients cannot all claim the service's last page.
        PageWindow first, second;
        for (auto* window : {&first, &second}) {
            window->reserve("boot", 0, PageWindow::Kind::Bootstrap); window->stage(segment(900)); window->acknowledge("boot", 1, {"s900"}, "s900");
        }
        const auto others = PageWindow::serviceGrowthLimit - PageWindow::pageLimit - 4096 - first.footprint() - second.footprint();
        auto total = [&] { return others + first.footprint() + second.footprint(); };
        first.reserve("older", 1, PageWindow::Kind::Before, total()); first.stage(segment(800));
        assert(first.pendingBytes() == segment(800)->bytes() && first.pendingBytes() > 4096);
        rejectsWith("windowCapacity", [&] { second.reserve("older", 1, PageWindow::Kind::Before, total()); });
        first.cancel();
        assert(first.pendingBytes() == 0);
        second.reserve("older", 1, PageWindow::Kind::Before, total()); second.stage(segment(800));
        // An ACK is never budget-checked: it only keeps or drops staged pages.
        const auto staged = total();
        second.acknowledge("older", 2, {"s800", "s900"}, "s900");
        assert(total() == staged && second.pendingBytes() == 0);
        rejectsWith("windowCapacity", [&] { first.reserve("again", 1, PageWindow::Kind::Before, total()); });
    }
    {
        // Revision staging counts the patch copies plus everything its ACK can
        // add: each retained copy of a patched record and split-page metadata.
        // Near the ceiling a sweep stages only a prefix that fits its room.
        PageWindow window;
        const std::string source = "codex-appserver:room";
        window.reserve("boot", 0, PageWindow::Kind::Bootstrap); window.stage(anchored(0, 1000, source));
        window.acknowledge("boot", 1, {"s0"}, "s0");
        // A detached head that repeats records 50..99 of the viewport page.
        window.reserve("head", 1, PageWindow::Kind::Head); window.stage(anchored(50, 1000, source));
        window.acknowledge("head", 2, {"s0"}, "s50");
        std::vector<PositionedRecord> patches(window.find("s0")->records.begin() + 50, window.find("s0")->records.begin() + 70);
        for (auto& row : patches) { row.revision = 2; row.value.json = "{\"text\":\"" + std::string(8000, 'z') + "\"}"; }
        size_t serial = 0; auto newID = [&] { return "room" + std::to_string(++serial); };
        const auto committed = window.retainedBytes();
        window.reserve("tight", 2, PageWindow::Kind::Revisions, PageWindow::serviceRefreshLimit - PageWindow::pageLimit);
        rejectsWith("windowCapacity", [&] { window.stageRevisions(patches, newID); });
        const auto staged = window.stageRevisionPrefix(patches, newID);
        assert(staged >= 1 && staged < patches.size() && window.pendingBytes() <= PageWindow::pageLimit);
        std::vector<std::string> viewport; std::string head = "s50";
        for (const auto& part : window.partitions()) {
            if (part.original == "s0") viewport.push_back(part.id);
            if (part.original == "s50") head = part.id;
        }
        if (viewport.empty()) viewport = {"s0"};
        const auto pending = window.pendingBytes();
        window.acknowledge("tight", 3, viewport, head);
        assert(window.retainedBytes() > committed && window.retainedBytes() <= committed + pending);
        // A split head keeps only its final part, so less than projected remains.
        size_t copies = 0;
        for (const auto& value : window.coverage()) for (const auto& record : value->records)
            if (record.start == 50) { assert(record.revision == 2); ++copies; }
        assert(copies == 1);
        // With ample room the same sweep stages every patch at once.
        PageWindow ample;
        ample.reserve("boot", 0, PageWindow::Kind::Bootstrap); ample.stage(anchored(0, 1000, source));
        ample.acknowledge("boot", 1, {"s0"}, "s0");
        ample.reserve("wide", 1, PageWindow::Kind::Revisions, 0);
        assert(ample.stageRevisionPrefix(patches, newID) == patches.size());
    }
    {
        // Unsplit revisions rewrite pages in place. Their ACK growth, twice
        // here for a record repeated by the detached head, counts as pending.
        PageWindow window;
        const std::string source = "codex-appserver:inplace";
        window.reserve("boot", 0, PageWindow::Kind::Bootstrap); window.stage(anchored(0, 20, source));
        window.acknowledge("boot", 1, {"s0"}, "s0");
        window.reserve("head", 1, PageWindow::Kind::Head); window.stage(anchored(50, 20, source));
        window.acknowledge("head", 2, {"s0"}, "s50");
        std::vector<PositionedRecord> patches(window.find("s0")->records.begin() + 50, window.find("s0")->records.begin() + 75);
        for (auto& row : patches) { row.revision = 2; row.value.json = "{\"text\":\"" + std::string(3300, 'g') + "\"}"; }
        size_t copyBytes = 1024;
        for (const auto& row : patches) copyBytes += WindowSegment::recordBytes(row);
        const auto committed = window.retainedBytes();
        window.reserve("grow", 2, PageWindow::Kind::Revisions, 0);
        window.stageRevisions(patches);
        assert(window.partitions().empty());
        const auto pending = window.pendingBytes();
        window.acknowledge("grow", 3, {"s0"}, "s50");
        const auto grown = window.retainedBytes() - committed;
        // The ACK adds more than the staged patch copies alone would cover.
        assert(grown > copyBytes && grown <= pending);
        size_t copies = 0;
        for (const auto& value : window.coverage()) for (const auto& record : value->records)
            if (record.start == 60) { assert(record.revision == 2); ++copies; }
        assert(copies == 2);
    }
    {
        // A re-bootstrap's result must fit the growth budget, and staging it
        // beside the old pages must still fit one page under the ceiling.
        const std::string source = "codex-appserver:rebootstrap";
        PageWindow deep;
        deep.reserve("boot", 0, PageWindow::Kind::Bootstrap); deep.stage(anchored(1 << 20, 1900, source));
        std::vector<std::string> viewport{id(1 << 20)};
        deep.acknowledge("boot", 1, viewport, viewport.front());
        for (int start = (1 << 20) - 100; deep.retainedBytes() <= PageWindow::refreshHeadroom + PageWindow::pageLimit; start -= 100) {
            deep.reserve(id(start), deep.version(), PageWindow::Kind::Before); deep.stage(anchored(start, 1900, source));
            viewport.insert(viewport.begin(), id(start));
            deep.acknowledge(id(start), deep.version() + 1, viewport, id(1 << 20));
        }
        const auto own = deep.retainedBytes(), page = PageWindow::pageLimit;
        assert(own > PageWindow::refreshHeadroom + page && viewport.size() < PageWindow::maximumViewportSegments);
        // Here the result alone would fit the growth budget; staging would not.
        const auto over = PageWindow::serviceRefreshLimit - page + 1;
        assert(PageWindow::fits(over - own, PageWindow::serviceGrowthLimit));
        rejectsWith("windowCapacity", [&] { deep.reserve("retry", 0, PageWindow::Kind::Bootstrap, over); });
        deep.reserve("retry", 0, PageWindow::Kind::Bootstrap, over - 1); deep.cancel();
        assert(!deep.pending() && deep.retainedBytes() == own);
    }
    {
        PageWindow growth;
        auto initial = std::make_shared<WindowSegment>(*segment(0, 100));
        initial->source = "codex-appserver:growth";
        for (auto& row : initial->records) {
            row.value.json = "{\"text\":\"" + std::string(1000, 'a') + "\"}";
            WindowRecordAnchors anchors;
            for (auto* anchor : {&anchors.before, &anchors.after, &anchors.reread}) anchor->source = initial->source;
            anchors.before.providerCursor = "before" + std::to_string(row.start);
            anchors.after.providerCursor = "after" + std::to_string(row.start);
            anchors.reread.providerCursor = "reread" + std::to_string(row.start);
            initial->anchors.push_back(anchors);
        }
        growth.reserve("start", 0, PageWindow::Kind::Bootstrap); growth.stage(initial);
        growth.acknowledge("start", 1, {initial->id}, initial->id);
        auto patches = std::vector<PositionedRecord>(initial->records.begin(), initial->records.begin() + 20);
        for (auto& row : patches) { row.revision = 2; row.value.json = "{\"text\":\"" + std::string(8000, 'z') + "\"}"; }
        unsigned nonce = 0;
        auto nextID = [&] { return "partition" + std::to_string(++nonce); };
        growth.reserve("cancelgrowth", 1, PageWindow::Kind::Revisions); growth.stageRevisions(patches, nextID);
        const auto cancelledID = growth.partitions().front().id;
        assert(growth.find(initial->id)->records.front().revision == 1);
        growth.cancel();
        assert(growth.partitions().empty()); assert(growth.version() == 1);
        rejects([&] { growth.find(cancelledID); });
        growth.reserve("growth", 1, PageWindow::Kind::Revisions); growth.stageRevisions(patches, nextID);
        const auto parts = growth.partitions(); assert(parts.size() >= 3 && parts.size() <= 4);
        std::vector<std::string> ids; size_t offset = 0;
        for (const auto& part : parts) { assert(part.offset == offset); offset += part.count; ids.push_back(part.id); }
        assert(offset == 100); assert(parts.front().before == initial->before); assert(parts.back().after == initial->after);
        rejects([&] { growth.acknowledge("growth", 2, {ids.front(), ids.back()}, ids.back()); });
        rejects([&] { growth.acknowledge("growth", 2, ids, initial->id); });
        assert(growth.version() == 1); assert(growth.find(initial->id)->records.front().revision == 1);
        growth.acknowledge("growth", 2, ids, ids.back());
        growth.acknowledge("growth", 2, ids, ids.back());
        rejects([&] { growth.find(initial->id); });
        assert(growth.find(ids.front())->records.front().revision == 2);
        for (const auto& id : ids) assert(growth.find(id)->bytes() <= PageWindow::pageLimit);
        assert(growth.retainedBytes() <= PageWindow::retainedLimit);
    }
    {
        PageWindow longCursors;
        auto initial = std::make_shared<WindowSegment>(*segment(0, 30));
        initial->source = "codex-appserver:long-cursors"; initial->records.resize(30);
        initial->anchors.resize(30);
        for (auto& anchors : initial->anchors) for (auto* anchor : {&anchors.before, &anchors.after, &anchors.reread}) {
            anchor->source = initial->source; anchor->providerCursor = std::string(2048, 'x');
        }
        longCursors.reserve("start", 0, PageWindow::Kind::Bootstrap); longCursors.stage(initial);
        longCursors.acknowledge("start", 1, {initial->id}, initial->id);
        std::vector<PositionedRecord> patches(initial->records.begin(), initial->records.begin() + 4);
        for (auto& row : patches) { row.revision = 2; row.value.json = "{\"text\":\"" + std::string(16000, 'a') + "\"}"; }
        size_t serial = 0; auto newID = [&] { return "longcursor" + std::to_string(++serial); };
        longCursors.reserve("grow", 1, PageWindow::Kind::Revisions); longCursors.stageRevisions(patches, newID);
        assert(longCursors.partitions().size() >= 2);
        std::vector<std::string> ids;
        for (const auto& part : longCursors.partitions()) ids.push_back(part.id);
        longCursors.acknowledge("grow", 2, ids, ids.back());
        for (const auto& part : longCursors.coverage()) assert(part->bytes() <= PageWindow::pageLimit);
    }
    {
        PageWindow invalid;
        invalid.reserve("invalid", 0, PageWindow::Kind::Bootstrap);
        auto malformed = std::make_shared<WindowSegment>(*segment(0));
        malformed->records[1].start = 0;
        rejects([&] { invalid.stage(malformed); });
        malformed->records[1].start = 1; malformed->records[1].revision = 0;
        rejects([&] { invalid.stage(malformed); });
        malformed->records[1].revision = 1; malformed->source = "codex-appserver:source";
        malformed->records[1].value.providerID = malformed->records[0].value.providerID;
        rejects([&] { invalid.stage(malformed); });
        assert(invalid.coverage().empty());
    }
    PageWindow window;
    window.reserve("bootstrap", 0, PageWindow::Kind::Bootstrap); window.stage(segment(900));
    assert(window.coverage().empty());
    window.acknowledge("bootstrap", 1, {"s900"}, "s900");
    window.acknowledge("bootstrap", 1, {"s900"}, "s900");
    for (int start = 800; start >= 0; start -= 100) {
        const auto transaction = "read" + std::to_string(start);
        const auto previous = window.viewport();
        window.reserve(transaction, window.version()); window.stage(segment(start));
        assert(window.viewport() == previous);
        rejects([&] { window.reserve("overlap", window.version()); });
        rejects([&] { window.acknowledge(transaction, window.version() + 1, {"foreign"}, "s900"); });
        assert(window.viewport() == previous);
        auto next = previous; next.insert(next.begin(), "s" + std::to_string(start));
        if (next.size() > 4) next.pop_back();
        window.acknowledge(transaction, window.version() + 1, next, "s900");
        assert(window.coverage().size() <= 5);
        assert(window.retainedBytes() <= PageWindow::retainedLimit);
    }
    assert(window.find("s0")->records.front().start == 0);
    assert(window.find("s900")->records.back().start == 999);
    rejects([&] { window.find("s500"); });
    const auto before = window.coverage().size();
    window.reserve("cancelled", window.version()); window.stage(segment(400)); window.cancel();
    assert(window.coverage().size() == before);
    rejects([&] { window.acknowledge("cancelled", window.version() + 1, {"s400"}, "s900"); });
    std::cout << "bounded window staging, retention, ACK and cancellation passed\n";
}
