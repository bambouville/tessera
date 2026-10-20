// Synthetic-test driver, not bundled in the host artifact.
#include "WindowPageReader.h"
#include "Json.h"
#include <iostream>
#include <map>

int main(int argc, char** argv) {
    if (argc != 3) return 64;
    try {
        tessera::Catalog catalog; tessera::CodexServer codex;
        auto source = catalog.resolve(argv[1], argv[2]);
        tessera::WindowPageReader reader(catalog, codex, {});
        uint64_t revision = 0;
        std::map<int, tessera::WindowRead> pages;
        std::string line, generation = source.provider == "codex" ? "codex-appserver:synthetic" : "";
        while (std::getline(std::cin, line)) {
            simdjson::dom::parser parser; simdjson::dom::element request;
            if (line.size() > 1024 || parser.parse(line).get(request)) return 64;
            tessera::json::Object output;
            try {
                const auto operation = tessera::json::text(request, "op");
                const int key = static_cast<int>(tessera::json::integer(request, "page"));
                if (operation == "authority") {
                    uint64_t bytes = 0;
                    output.boolean("canonical", reader.canonicalCodexAvailable(source, bytes));
                    output.number("bytesRead", bytes);
                    output.string("path", source.path);
                } else if (operation == "revise") {
                    const auto& page = pages.at(key);
                    const auto index = static_cast<size_t>(tessera::json::integer(request, "index"));
                    uint64_t bytes = 0;
                    auto record = generation.rfind("codex-history:", 0) == 0 ?
                        reader.reviseHistory(page.segment.records.at(index), page.segment.anchors.at(index), source, revision, bytes) :
                        reader.reviseNative(page.segment.records.at(index), page.segment.anchors.at(index), source, revision,
                            std::chrono::steady_clock::now() + std::chrono::milliseconds(1500), codex.bytesRead());
                    output.string("recordID", record.value.providerID); output.number("revision", record.revision);
                    output.boolean("changed", record.value.json != page.segment.records.at(index).value.json);
                } else {
                    std::optional<tessera::WindowAnchor> anchor;
                    const auto direction = tessera::json::text(request, "direction");
                    const bool forward = direction == "after";
                    if (tessera::json::boolean(request, "fallback")) generation.clear();
                    if (!direction.empty()) anchor = forward ? pages.at(key).after : pages.at(key).before;
                    auto page = reader.read(source, generation, anchor, forward, 100, revision);
                    generation = page.segment.source;
                    std::string records;
                    for (const auto& record : page.segment.records) {
                        tessera::json::Object value; value.string("id", record.value.providerID); value.number("order", record.start);
                        value.number("revision", record.revision);
                        if (record.sourceByteOffset != UINT64_MAX) value.number("sourceOffset", record.sourceByteOffset);
                        value.raw("body", record.value.json);
                        if (!records.empty()) records += ',';
                        records += value.finish();
                    }
                    output.raw("records", "[" + records + "]"); output.number("page", pages.size());
                    output.boolean("hasOlder", page.segment.hasOlder); output.boolean("hasNewer", page.segment.hasNewer);
                    output.number("bytesRead", page.bytesRead);
                    output.number("sourceEnd", page.sourceEnd);
                    if (pages.size() >= 32) return 65;
                    pages[static_cast<int>(pages.size())] = std::move(page);
                }
            } catch (const std::exception& error) { output.string("error", error.what()); }
            std::cout << output.finish() << std::endl;
        }
    } catch (...) { return 65; }
}
