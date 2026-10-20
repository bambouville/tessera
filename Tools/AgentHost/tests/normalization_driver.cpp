// Private streaming differential driver; never bundled with the service.
#include "JsonlReader.h"
#include "Json.h"
#include "BoundedJson.h"
#include <array>
#include <iostream>
#include <memory>
#include <sys/resource.h>

int main(int argc, char** argv) {
    const bool projected = argc == 2 && std::string(argv[1]) == "--public-projected-items";
    if (projected || (argc == 2 && std::string(argv[1]) == "--public-items")) {
        // Private test-only IPC: decimal byte length, LF, exact JSON bytes.
        // Stream the same bounded projection as the public read-server path;
        // neither a giant string nor a whole transcript enters this process.
        try {
            size_t length;
            while (std::cin >> length) {
                if (std::cin.get() != '\n' || !length || length > 32 * 1024 * 1024) return 65;
                // Oracle-only: convert an already bounded Core DOM through
                // upstream without applying a SECOND transport string cut to
                // fields that conversion has renamed, joined or synthesized.
                // This is not a simulation of the public transport reader.
                if (projected) {
                    if (length > 4 * 1024 * 1024) return 65;
                    std::string raw(length, '\0');
                    if (!std::cin.read(raw.data(), length)) return 65;
                    simdjson::dom::parser parser;
                    const auto envelope = parser.parse(raw).value();
                    const auto result = tessera::normalizeCodexItem(tessera::json::get(envelope, "item"),
                        tessera::json::text(envelope, "turn"), tessera::json::boolean(envelope, "sourceTruncated"));
                    tessera::json::Object row; row.string("disposition", result.disposition, 32); row.raw("record", result.json);
                    std::cout << row.finish() << '\n' << std::flush;
                    continue;
                }
                tessera::BoundedJson bounded;
                std::array<char, 65536> buffer;
                while (length) {
                    const auto count = std::min(length, buffer.size());
                    if (!std::cin.read(buffer.data(), count)) return 65;
                    bounded.feed(std::string_view(buffer.data(), count)); length -= count;
                }
                if (bounded.malformed() || bounded.unsupported()) throw std::runtime_error("publicItemBudget");
                simdjson::dom::parser parser;
                const auto envelope = parser.parse(bounded.json()).value();
                const auto result = tessera::normalizeCodexItem(tessera::json::get(envelope, "item"),
                    tessera::json::text(envelope, "turn"), bounded.truncated() || tessera::json::boolean(envelope, "sourceTruncated"));
                tessera::json::Object row; row.string("disposition", result.disposition, 32); row.raw("record", result.json);
                std::cout << row.finish() << '\n' << std::flush;
            }
            return std::cin.eof() ? 0 : 65;
        } catch (...) { return 65; }
    }
    const bool core = argc == 3 && std::string(argv[1]) == "--core-items";
    const bool source = argc == 3 && std::string(argv[1]) == "--bounded-codex-source";
    if (argc != 3 || (!core && !source && std::string(argv[1]) != "claude" && std::string(argv[1]) != "codex" && std::string(argv[1]) != "pi" && std::string(argv[1]) != "kimi")) return 64;
    try {
        tessera::JsonlReader::Normalizer normalizer;
        if (source) normalizer = [](simdjson::dom::element value, bool truncated) {
            tessera::NormalizedRecord result;
            tessera::json::Object wrapper;
            wrapper.raw("source", simdjson::minify(value)); wrapper.boolean("sourceTruncated", truncated);
            result.json = wrapper.finish();
            result.sourceType = tessera::json::text(value, "type");
            const auto subtype = tessera::json::text(tessera::json::get(value, "payload"), "type");
            if (!subtype.empty()) result.sourceType += "/" + subtype;
            return result;
        };
        if (core) normalizer = [](simdjson::dom::element source, bool truncated) {
            const auto payload = tessera::json::get(source, "payload");
            tessera::NormalizedRecord result; result.json = "{}"; result.sourceType = "skipped-non-completed";
            for (const auto object : {source, payload}) if (object.is_object()) {
                std::set<std::string_view> keys;
                for (const auto field : simdjson::dom::object(object.get_object().value())) if (!keys.insert(field.key).second)
                    throw std::runtime_error("ambiguousSourceEnvelope");
            }
            if (tessera::json::text(source, "type") != "event_msg" || tessera::json::text(payload, "type") != "item_completed") return result;
            uint64_t ordinal;
            if (tessera::json::get(source, "ordinal").get_uint64().get(ordinal))
                throw std::runtime_error("invalidSourceOrdinal");
            for (const auto field : {"thread_id", "turn_id"}) {
                const auto value = tessera::json::text(payload, field);
                if (value.empty() || value.size() > 256) throw std::runtime_error("invalidSourceIdentity");
            }
            result = tessera::normalizeCodexCoreItem(tessera::json::get(payload, "item"), tessera::json::text(payload, "turn_id"), truncated);
            if (result.providerID.empty() || result.providerID.size() > 256) throw std::runtime_error("invalidSourceIdentity");
            tessera::json::Object envelope;
            envelope.raw("projection", result.json); envelope.string("owner", tessera::json::text(payload, "thread_id"), 256);
            envelope.string("turn", tessera::json::text(payload, "turn_id"), 256); envelope.string("itemID", result.providerID, 256);
            envelope.number("ordinal", ordinal);
            result.json = envelope.finish(); return result;
        };
        std::unique_ptr<tessera::JsonlReader> sourceReader;
        if (source) {
            sourceReader = std::make_unique<tessera::JsonlReader>(argv[2], "codex", -1, std::function<bool()>{}, normalizer);
            normalizer = [](simdjson::dom::element, bool) {
                tessera::NormalizedRecord result; result.json = "{}"; return result;
            };
        }
        tessera::JsonlReader reader(argv[2], core || source ? "codex" : argv[1], -1, {}, normalizer);
        uint64_t cursor = 0;
        for (;;) {
            auto page = reader.page(cursor, true);
            for (const auto& positioned : page.records) {
                const auto record = source ? sourceReader->readRecord(positioned.start, positioned.end) : positioned;
                if (core && record.value.sourceType == "skipped-non-completed") continue;
                tessera::json::Object row;
                row.number("start", record.start); row.number("end", record.end);
                row.string("sourceType", record.value.sourceType, 256);
                row.string("disposition", record.value.disposition, 32);
                row.boolean("visible", record.value.visible);
                row.raw("record", record.value.json);
                std::cout << row.finish() << '\n';
            }
            std::cout.flush();
            if (!page.hasNewer) break;
            if (page.live <= cursor) throw std::runtime_error("cursorDidNotAdvance");
            cursor = page.live;
        }
        tessera::json::Object end; end.boolean("complete", true);
        end.number("bytesRead", reader.bytesRead()); end.number("sourceEnd", reader.completeEnd());
        rusage usage{};
        if (::getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("memoryMeasurementFailed");
#ifdef __APPLE__
        end.number("peakRSSBytes", usage.ru_maxrss);
#else
        end.number("peakRSSBytes", static_cast<uint64_t>(usage.ru_maxrss) * 1024);
#endif
        std::cout << end.finish() << '\n';
        return 0;
    } catch (const std::exception& error) {
        tessera::json::Object failure; failure.string("error", error.what(), 128);
        std::cout << failure.finish() << '\n'; return 65;
    }
}
