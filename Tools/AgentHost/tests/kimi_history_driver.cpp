// Private semantic oracle IPC. Never packaged with the deployed helper.
#include "KimiHistoryIndex.h"
#include "Json.h"
#include <iostream>
#include <sys/resource.h>

namespace {
// The newest page read cancelled at points across its replay, then a
// smaller page inside it, each against the cached index's.
int interrupted(const char* path, size_t budget, size_t wanted) {
    auto open = [&] { return tessera::JsonlReader(path, "kimi", -1, std::function<bool()>{}, tessera::KimiHistoryIndex::metadata); };
    tessera::KimiHistoryIndex cached;
    { auto reader = open(); cached.refresh(reader, {}, 128 * 1024 * 1024); }
    const size_t wide = std::min<size_t>(100, cached.size()), first = cached.size() - wide;
    std::vector<uint64_t> oracle;
    { auto reader = open(); for (const auto& item : cached.materialize(reader, first, std::min(wanted, wide))) oracle.push_back(item.entry.start); }
    // Returns whether the cancellation fired and the smaller page matched.
    auto run = [&](size_t trigger, size_t& checks) {
        tessera::KimiHistoryIndex lazy;
        { auto reader = open(); lazy.refresh(reader, {}, budget); }
        checks = 0;
        const std::function<bool()> cancel = [&] { return ++checks == trigger; };
        try { auto reader = open(); lazy.materialize(reader, first, wide, cancel); }
        catch (const std::runtime_error& error) { if (std::string(error.what()) != "cancelled") throw; }
        const bool fired = trigger && checks >= trigger;
        std::vector<uint64_t> page;
        { auto reader = open(); for (const auto& item : lazy.materialize(reader, first, oracle.size())) page.push_back(item.entry.start); }
        return std::pair{fired, page == oracle};
    };
    size_t total = 0; run(0, total);
    uint64_t fired = 0, wrong = 0;
    for (size_t step = 1; step < 32; ++step) {
        size_t checks = 0; const auto [cancelled, right] = run(total * step / 32, checks);
        fired += cancelled; wrong += !right;
    }
    tessera::json::Object output; output.number("checks", total); output.number("interrupted", fired); output.number("mismatches", wrong);
    std::cout << output.finish() << '\n'; return 0;
}
}

int main(int argc, char** argv) {
    if (argc < 2 || argc > 5) return 64;
    if (argc == 5 && std::string(argv[3]) == "interrupt") {
        try { return interrupted(argv[1], std::stoull(argv[2]), std::stoull(argv[4])); }
        catch (const std::exception& error) {
            tessera::json::Object output; output.string("error", error.what()); std::cout << output.finish() << '\n'; return 65;
        }
    }
    try {
        tessera::KimiHistoryIndex index;
        tessera::JsonlContinuation continuation; tessera::JsonlContinuation::Scope scope(continuation);
        std::unique_ptr<tessera::JsonlReader> reader;
        uint64_t bytesRead = 0, yields = 0;
        auto resume = [&](const auto& operation) {
            for (;;) {
                continuation.beginSlice(1);
                reader = std::make_unique<tessera::JsonlReader>(argv[1], "kimi", -1, std::function<bool()>{}, tessera::KimiHistoryIndex::metadata);
                try { operation(*reader); bytesRead += reader->bytesRead(); return; }
                catch (const std::runtime_error& error) {
                    bytesRead += reader->bytesRead();
                    if (std::string(error.what()) != "readPending" || ++yields > 100000) throw;
                }
            }
        };
        resume([&](auto& source) { index.refresh(source, {}, argc >= 3 ? std::stoull(argv[2]) : 128 * 1024 * 1024); });
        // `shrink <budget>`: every page, then the page a quarter of the way
        // in again, read right after a refresh at the smaller budget.
        const bool shrink = argc == 5 && std::string(argv[3]) == "shrink";
        std::vector<std::string> selected;
        auto read = [&](size_t first, size_t count, std::vector<std::string>& rows) {
            std::vector<tessera::KimiHistoryIndex::Materialized> page;
            resume([&](auto& source) { page = index.materialize(source, first, count); });
            for (const auto& item : page) {
                tessera::json::Object row; row.number("offset", item.entry.start); row.boolean("interrupted", item.interrupted);
                rows.push_back(row.finish());
            }
        };
        const size_t start = argc >= 4 && !shrink ? (std::string(argv[3]) == "tail" ? index.size() - std::min<size_t>(100, index.size()) : std::stoull(argv[3])) : 0;
        if (start > index.size()) throw std::runtime_error("invalidCursor");
        const size_t end = argc == 5 && !shrink ? start + std::min<size_t>(index.size() - start, std::stoull(argv[4])) : index.size();
        for (size_t first = start; first < end; first += 100) read(first, std::min<size_t>(100, end - first), selected);
        tessera::json::Object output; output.number("count", index.size()); output.raw("selected", tessera::json::array(selected));
        if (shrink) {
            resume([&](auto& source) { index.refresh(source, {}, std::stoull(argv[4])); });
            output.number("refreshedBytes", index.bytes());
            const auto before = bytesRead;
            std::vector<std::string> rows; read(index.size() / 4, std::min<size_t>(100, index.size() - index.size() / 4), rows);
            output.raw("shrunkPage", tessera::json::array(rows)); output.number("shrunkPageBytes", bytesRead - before);
        }
        output.number("bytesRead", bytesRead); output.number("yields", yields); output.number("indexBytes", index.bytes());
        rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
        output.number("peakRSSBytes", usage.ru_maxrss);
#else
        output.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
        std::cout << output.finish() << '\n'; return 0;
    } catch (const std::exception& error) {
        tessera::json::Object output; output.string("error", error.what()); std::cout << output.finish() << '\n'; return 65;
    }
}
