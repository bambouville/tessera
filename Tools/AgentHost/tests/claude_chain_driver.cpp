// Private differential-test driver. Not shipped in the host artifact.
// Usage: agent-claude-chain-driver PATH [BUDGET_BYTES]
// A small budget demotes the index to its lazy or linear-proof strategy.
// Output is structural (ids/offsets/counts), never message content.
#include "ClaudeChainIndex.h"
#include "Json.h"
#include <algorithm>
#include <iostream>
#include <sys/resource.h>

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) return 64;
    try {
        const size_t budget = argc == 3 ? static_cast<size_t>(std::stoull(argv[2])) : size_t(128 * 1024 * 1024);
        tessera::JsonlReader reader(argv[1], "claude");
        tessera::ClaudeChainIndex index;
        for (;;) { try { index.refresh(reader, {}, budget); break; }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "readPending") throw; }
        }
        std::vector<std::string> ids, offsets, starts;
        // Newest first, as clients page: a lazy index then continues one
        // ancestry cursor instead of restarting it for every older ordinal.
        for (size_t i = index.size(); i-- > 0;) {
            const auto& entry = index.entry(reader, i);
            starts.push_back(std::to_string(entry.start));
            if (entry.message && entry.main) {
                ids.push_back(tessera::json::quote(entry.id)); offsets.push_back(std::to_string(entry.start));
            }
        }
        std::reverse(ids.begin(), ids.end()); std::reverse(offsets.begin(), offsets.end());
        std::reverse(starts.begin(), starts.end());
        tessera::json::Object output;
        output.raw("ids", tessera::json::array(ids)); output.number("bytesRead", reader.bytesRead());
        output.raw("sourceOffsets", tessera::json::array(offsets));
        output.raw("selectedStarts", tessera::json::array(starts));
        output.number("count", index.size());
        output.string("mode", index.linear() ? "linear" : index.lazy() ? "lazy" : "compact");
        output.number("indexBytes", index.bytes()); output.boolean("parentFields", index.branched());
        rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
        output.number("peakRSSBytes", usage.ru_maxrss);
#else
        output.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
        std::cout << output.finish() << '\n'; return 0;
    } catch (const std::exception& error) {
        tessera::json::Object output; output.string("error", error.what());
        std::cout << output.finish() << '\n'; return 65;
    }
}
