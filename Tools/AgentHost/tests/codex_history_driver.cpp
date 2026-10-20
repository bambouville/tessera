// Private identity/order oracle bridge. Never bundled with the host tool.
#include "CodexHistoryIndex.h"
#include "Json.h"
#include <iostream>
#include <sys/resource.h>

int main(int argc, char** argv) {
    const bool metadata = argc == 3 && std::string(argv[1]) == "--metadata";
    const bool coreSource = argc == 3 && std::string(argv[1]) == "--selected-source";
    const bool legacy = argc == 3 && std::string(argv[1]) == "--legacy-items";
    const bool selected = legacy || coreSource || (argc == 3 && std::string(argv[1]) == "--selected-items");
    if (argc != 2 && !metadata && !selected) return 64;
    try {
        tessera::JsonlReader reader(argv[metadata || selected ? 2 : 1], "codex", -1, {}, tessera::CodexHistoryIndex::metadata);
        if (metadata) {
            uint64_t cursor = 0;
            for (;;) {
                const auto page = reader.page(cursor, true);
                for (const auto& record : page.records) std::cout << record.value.json << '\n';
                if (!page.hasNewer) return 0;
                if (page.live <= cursor) throw std::runtime_error("cursorDidNotAdvance");
                cursor = page.live;
            }
        }
        tessera::CodexHistoryIndex index;
        for (;;) {
            try { index.refresh(reader); break; }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "readPending") throw; }
        }
        if (legacy && index.paginated()) throw std::runtime_error("expectedLegacyHistory");
        if (coreSource) reader.setNormalizer([](simdjson::dom::element source, bool truncated) {
            auto result = tessera::CodexHistoryIndex::completed(source, truncated);
            tessera::json::Object wrapper;
            wrapper.raw("projection", result.json);
            wrapper.raw("coreItem", simdjson::minify(tessera::json::get(tessera::json::get(source, "payload"), "item")));
            wrapper.boolean("sourceTruncated", truncated);
            result.json = wrapper.finish(); return result;
        });
        else if (legacy) reader.setNormalizer({});
        else if (selected) reader.setNormalizer(tessera::CodexHistoryIndex::completed);
        for (size_t i = 0; (index.paginated() || legacy) && i < index.size(); ++i) {
            const auto& entry = index.entry(reader, i); tessera::json::Object row;
            row.string("thread", index.sessionID(), 256); row.string("turn", entry.turn, 256); row.string("id", entry.id, 256);
            row.number("ordinal", entry.ordinal); row.number("updatedOrdinal", entry.updatedOrdinal);
            row.number("start", entry.start); row.number("end", entry.end);
            if (selected) {
                const auto record = reader.readRecord(entry.start, entry.end);
                if (record.value.providerID != entry.id) throw std::runtime_error("selectedIdentityChanged");
                tessera::json::Object envelope;
                envelope.string("owner", index.sessionID(), 256); envelope.string("turn", entry.turn, 256);
                envelope.string("itemID", entry.id, 256); envelope.number("ordinal", entry.updatedOrdinal);
                if (coreSource) {
                    simdjson::dom::parser parser;
                    const auto wrapper = parser.parse(record.value.json).value();
                    envelope.raw("projection", simdjson::minify(tessera::json::get(wrapper, "projection")));
                    envelope.raw("coreItem", simdjson::minify(tessera::json::get(wrapper, "coreItem")));
                    envelope.boolean("sourceTruncated", tessera::json::boolean(wrapper, "sourceTruncated"));
                } else envelope.raw("projection", record.value.json);
                row.raw("record", envelope.finish()); row.string("sourceType", record.value.sourceType, 256);
                row.string("disposition", record.value.disposition, 32); row.boolean("visible", record.value.visible);
            }
            std::cout << row.finish() << '\n';
        }
        tessera::json::Object row; row.boolean("complete", true); row.boolean("paginated", index.paginated());
        row.string("thread", index.sessionID(), 256); row.number("records", index.size());
        row.number("sourceEnd", reader.size());
        row.number("indexBytes", index.bytes()); row.number("bytesRead", reader.bytesRead());
        row.number("mirroredRecords", index.mirroredRecords());
        rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
        row.number("peakRSSBytes", usage.ru_maxrss);
#else
        row.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
        std::cout << row.finish() << '\n'; return 0;
    } catch (const std::exception& error) {
        tessera::json::Object row; row.string("error", error.what(), 128);
        std::cout << row.finish() << '\n'; return 65;
    }
}
