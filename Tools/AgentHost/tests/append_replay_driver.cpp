// Test-only persistent indexes versus independent fresh indexes at every
// caller-written prefix. Outputs counts, never authored text or identities.
#include "ClaudeChainIndex.h"
#include "CodexHistoryIndex.h"
#include "Json.h"
#include <iostream>
#include <sys/resource.h>

int main(int argc, char** argv) {
    if (argc != 3) return 64;
    const std::string provider(argv[1]), path(argv[2]);
    if (provider != "codex" && provider != "claude") return 64;
    tessera::CodexHistoryIndex codex;
    tessera::ClaudeChainIndex claude;
    std::string command;
    std::string previousGeneration;
    while (std::getline(std::cin, command)) {
        if (command != "refresh") return 64;
        try {
            tessera::JsonlReader live(path, provider, -1, {}, provider == "codex" ?
                tessera::JsonlReader::Normalizer(tessera::CodexHistoryIndex::metadata) : tessera::JsonlReader::Normalizer());
            tessera::JsonlReader cold(path, provider, -1, {}, provider == "codex" ?
                tessera::JsonlReader::Normalizer(tessera::CodexHistoryIndex::metadata) : tessera::JsonlReader::Normalizer());
            auto resume = [](auto&& operation) {
                for (;;) { try { operation(); return; } catch (const std::runtime_error& error) {
                    if (std::string(error.what()) != "readPending") throw;
                } }
            };
            size_t count = 0, retained = 0;
            if (provider == "codex") {
                resume([&] { codex.refresh(live); });
                tessera::CodexHistoryIndex reference; resume([&] { reference.refresh(cold); });
                if (codex.paginated() != reference.paginated() || codex.indexed() != reference.indexed() ||
                    codex.sessionID() != reference.sessionID() || codex.size() != reference.size() ||
                    codex.mirroredRecords() != reference.mirroredRecords()) throw std::runtime_error("replaySelectionMismatch");
                count = codex.size(); retained = codex.bytes();
                for (size_t i = 0; i < count; ++i) {
                    const auto& a = codex.entry(live, i); const auto& b = reference.entry(cold, i);
                    if (a.start != b.start || a.end != b.end || a.ordinal != b.ordinal || a.updatedOrdinal != b.updatedOrdinal ||
                        a.turn != b.turn || a.id != b.id) throw std::runtime_error("replayRecordMismatch");
                }
            } else {
                resume([&] { claude.refresh(live, {}); });
                tessera::ClaudeChainIndex reference; resume([&] { reference.refresh(cold, {}); });
                if (claude.size() != reference.size() || claude.branched() != reference.branched())
                    throw std::runtime_error("replaySelectionMismatch");
                count = claude.size(); retained = claude.bytes();
                for (size_t i = 0; i < count; ++i) {
                    const auto& a = claude.entry(live, i); const auto& b = reference.entry(cold, i);
                    if (a.start != b.start || a.end != b.end || a.id != b.id || a.parent != b.parent ||
                        a.node != b.node || a.message != b.message || a.main != b.main) throw std::runtime_error("replayRecordMismatch");
                }
            }
            live.validateSnapshot(); cold.validateSnapshot();
            tessera::json::Object out;
            out.boolean("matched", true); out.number("records", count); out.number("indexBytes", retained);
            if (provider == "claude") {
                out.boolean("generationChanged", !previousGeneration.empty() && previousGeneration != claude.generation());
                previousGeneration = claude.generation();
            }
            out.number("sourceEnd", live.size()); out.number("incrementalBytesRead", live.bytesRead());
            out.number("freshBytesRead", cold.bytesRead());
            rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
            out.number("peakRSSBytes", usage.ru_maxrss);
#else
            out.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
            std::cout << out.finish() << std::endl;
        } catch (const std::exception& error) {
            tessera::json::Object out; out.string("error", error.what(), 128);
            std::cout << out.finish() << std::endl;
            return 65;
        }
    }
    return 0;
}
