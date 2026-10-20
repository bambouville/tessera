// Private semantic oracle IPC. Never packaged with the deployed helper.
#include "KimiHistoryIndex.h"
#include "Json.h"
#include <iostream>
#include <sys/resource.h>

int main(int argc, char** argv) {
    if (argc < 2 || argc > 5) return 64;
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
        std::vector<std::string> selected;
        const size_t start = argc >= 4 ? (std::string(argv[3]) == "tail" ? index.size() - std::min<size_t>(100, index.size()) : std::stoull(argv[3])) : 0;
        if (start > index.size()) throw std::runtime_error("invalidCursor");
        const size_t end = argc == 5 ? start + std::min<size_t>(index.size() - start, std::stoull(argv[4])) : index.size();
        for (size_t first = start; first < end; first += 100) {
            std::vector<tessera::KimiHistoryIndex::Materialized> page;
            resume([&](auto& source) { page = index.materialize(source, first, std::min<size_t>(100, end - first)); });
            for (const auto& item : page) {
                tessera::json::Object row; row.number("offset", item.entry.start); row.boolean("interrupted", item.interrupted);
                selected.push_back(row.finish());
            }
        }
        tessera::json::Object output; output.number("count", index.size()); output.raw("selected", tessera::json::array(selected));
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
