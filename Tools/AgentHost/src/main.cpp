#include "HookSender.h"
#include "LocalTransport.h"
#include "JsonlReader.h"
#include "Json.h"
#include "CodexServer.h"
#include "Scope.h"
#include "VersionPin.h"
#include "Catalog.h"
#include "ProcessContext.h"
#include <cstring>
#include <iostream>
#include <limits.h>
#include <cstdlib>
#include <charconv>
#include <chrono>
#include <limits>
#include <map>
#include <sys/resource.h>
#include <signal.h>

int main(int argc, char** argv) {
    (void)::signal(SIGPIPE, SIG_IGN);
    const bool contextConnect = (argc == 6 || argc == 8) && !std::strcmp(argv[1], "connect") &&
        !std::strcmp(argv[2], "--stdio") && !std::strcmp(argv[3], "--runtime-base") &&
        !std::strcmp(argv[5], "--context-from-hello");
    if (!contextConnect && argc > 1 && (!std::strcmp(argv[1], "serve") || !std::strcmp(argv[1], "connect") ||
                    !std::strcmp(argv[1], "codex-probe") ||
                    (argc == 4 && !std::strcmp(argv[1], "hook") && !std::strcmp(argv[2], "--runtime-base")))) {
        try { tessera::Catalog::freezeProviderEnvironment(); }
        catch (...) { return !std::strcmp(argv[1], "hook") ? 0 : 77; }
    }
    if (argc >= 2 && !std::strcmp(argv[1], "codex-probe")) {
        if (argc != 2 && (argc != 4 || std::strcmp(argv[2], "--thread"))) return 64;
        const auto started = std::chrono::steady_clock::now();
        tessera::json::Object result;
        try {
            tessera::CodexServer server;
            std::string thread = argc == 4 ? argv[3] : "";
            if (thread.size() > 128) return 64;
            simdjson::dom::parser parser;
            if (thread.empty()) {
                auto raw = server.call("thread/list", "{\"limit\":10,\"useStateDbOnly\":true}");
                simdjson::dom::element list;
                if (parser.parse(raw).get(list)) throw std::runtime_error("codexMalformedResponse");
                const auto data = tessera::json::get(list, "data");
                if (!data.is_array() || !data.get_array().value().size()) throw std::runtime_error("codexNoThreads");
                thread = tessera::json::text(*data.get_array().value().begin(), "id");
                result.number("listedThreads", data.get_array().value().size());
            }
            tessera::json::Object params;
            params.string("threadId", thread, 128); params.number("limit", 20); params.string("sortDirection", "desc");
            auto raw = server.call("thread/items/list", params.finish());
            simdjson::dom::element page;
            if (parser.parse(raw).get(page)) throw std::runtime_error("codexMalformedResponse");
            const auto data = tessera::json::get(page, "data");
            if (!data.is_array()) throw std::runtime_error("codexMalformedResponse");
            std::map<std::string, uint64_t> types;
            for (const auto entry : simdjson::dom::array(data.get_array().value())) ++types[tessera::json::text(tessera::json::get(entry, "item"), "type")];
            tessera::json::Object counts;
            for (const auto& type : types) counts.number(type.first, type.second);
            result.raw("itemTypes", counts.finish()); result.number("items", data.get_array().value().size());
            result.boolean("hasOlder", !tessera::json::get(page, "nextCursor").is_null());
            result.boolean("hasLiveAnchor", !tessera::json::get(page, "backwardsCursor").is_null());
            result.number("childPeakRSSBytes", server.peakResidentBytes());
            result.raw("wallMs", std::to_string(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count()));
            std::cout << result.finish() << '\n'; return 0;
        } catch (const std::exception& error) {
            result.string("error", error.what(), 128); std::cout << result.finish() << '\n'; return 65;
        }
    }
    if (argc >= 2 && !std::strcmp(argv[1], "jsonl")) {
        std::string path, provider;
        bool forward = false, audit = false;
        uint64_t position = std::numeric_limits<uint64_t>::max(), limit = 100;
        for (int i = 2; i < argc; ++i) {
            std::string option = argv[i];
            if (option == "--audit") { audit = true; continue; }
            if (++i == argc) return 64;
            if (option == "--path") path = argv[i];
            else if (option == "--provider") provider = argv[i];
            else if (option == "--before" || option == "--after" || option == "--limit") {
                uint64_t value{};
                const char* end = argv[i] + std::strlen(argv[i]);
                const auto parsed = std::from_chars(argv[i], end, value);
                if (parsed.ec != std::errc() || parsed.ptr != end) return 64;
                if (option == "--limit") limit = value;
                else { position = value; forward = option == "--after"; }
            } else return 64;
        }
        if (path.empty() || (provider != "claude" && provider != "codex")) return 64;
        const auto started = std::chrono::steady_clock::now();
        try {
            tessera::JsonlReader reader(path, provider);
            if (!audit) std::cout << reader.page(position, forward, limit).json() << '\n';
            else {
                std::map<std::string, uint64_t> types, dispositions;
                uint64_t records = 0, reads = 0, cursor = 0;
                while (true) {
                    auto page = reader.page(cursor, true);
                    reads += page.bytesRead;
                    for (const auto& record : page.records) {
                        const auto& type = record.value.sourceType;
                        if (types.size() < 1024 || types.count(type)) ++types[type];
                        else ++types["type-budget-exceeded"];
                        ++dispositions[record.value.disposition]; ++records;
                    }
                    if (!page.hasNewer) break;
                    if (page.live <= cursor) throw std::runtime_error("cursorDidNotAdvance");
                    cursor = page.live;
                }
                tessera::json::Object output, typeCounts, dispositionCounts;
                for (const auto& pair : types) typeCounts.number(pair.first, pair.second);
                for (const auto& pair : dispositions) dispositionCounts.number(pair.first, pair.second);
                output.number("records", records); output.number("bytesRead", reads); output.number("fileBytes", reader.size());
                output.number("committedBytes", reader.completeEnd());
                output.number("deferredTailBytes", reader.size() - reader.completeEnd());
                output.raw("types", typeCounts.finish()); output.raw("dispositions", dispositionCounts.finish());
                const auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
                output.raw("wallMs", std::to_string(elapsed));
                rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
                output.number("peakRSSBytes", usage.ru_maxrss);
#else
                output.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
                std::cout << output.finish() << '\n';
            }
            return 0;
        } catch (const std::exception& error) {
            tessera::json::Object output; output.string("error", error.what(), 128);
            std::cout << output.finish() << '\n'; return 65;
        }
    }
    if (argc == 2 && std::strcmp(argv[1], "--version") == 0) {
        std::cout << "tessera-agent-host 0.1.0\n";
        return 0;
    }
    if (argc == 4 && std::strcmp(argv[1], "hook") == 0 &&
        std::strcmp(argv[2], "--socket") == 0) {
        return tessera::sendHook(argv[3]);
    }
    if (argc == 4 && !std::strcmp(argv[1], "hook") && !std::strcmp(argv[2], "--runtime-base")) {
        try { return tessera::sendHook((tessera::scopedRuntime(argv[3], false) + "/hooks.sock").c_str()); }
        catch (...) { return 0; }
    }
    if (argc >= 4 && std::strcmp(argv[1], "serve") == 0 && std::strcmp(argv[2], "--runtime") == 0) {
        int idleMs = 30000, leaseMs = 30000;
        // Explicit service knobs enable deterministic process-lifetime tests.
        for (int i = 4; i < argc; i += 2) {
            if (i + 1 == argc) return 64;
            char* end = nullptr;
            long value = std::strtol(argv[i + 1], &end, 10);
            if (!end || *end || value < 100 || value > 30000) return 64;
            if (!std::strcmp(argv[i], "--idle-ms")) idleMs = static_cast<int>(value);
            else if (!std::strcmp(argv[i], "--lease-ms")) leaseMs = static_cast<int>(value);
            else return 64;
        }
        try {
            tessera::VersionPin pin(argv[0]);
            return tessera::runService(argv[3], idleMs, leaseMs, &pin);
        } catch (...) { return 77; }
    }
    // Read-only attachment for externally supervised integration fixtures.
    // Missing/expired service is an error, never permission to start a daemon.
    if (argc == 6 && !std::strcmp(argv[1], "connect") && !std::strcmp(argv[2], "--stdio") &&
        !std::strcmp(argv[3], "--runtime") && !std::strcmp(argv[5], "--attach-only")) {
        return tessera::runRelay(argv[4], argv[0], {}, 30000, true);
    }
    if ((argc == 5 || ((argc == 6 || argc == 8) && !std::strcmp(argv[5], "--context-from-hello"))) && !std::strcmp(argv[1], "connect") && !std::strcmp(argv[2], "--stdio") &&
        (!std::strcmp(argv[3], "--runtime") || !std::strcmp(argv[3], "--runtime-base"))) {
        char executable[PATH_MAX];
        // Deployment invokes a fixed absolute executable, not a PATH search.
        if (!::realpath(argv[0], executable)) return 64;
        try {
            if (argc >= 6 && std::strcmp(argv[3], "--runtime-base")) return 64;
            int idleMs = 30000;
            if (argc == 8) {
                char* end = nullptr;
                const auto value = std::strtol(argv[7], &end, 10);
                if (std::strcmp(argv[6], "--idle-ms") || !end || !*argv[7] || *end || value < 100 || value > 30000) return 64;
                idleMs = static_cast<int>(value);
            }
            const auto initial = argc >= 6 ? tessera::contextHello(argv[4]) : std::string();
            const auto runtime = !std::strcmp(argv[3], "--runtime-base") ? tessera::scopedRuntime(argv[4], true) : argv[4];
            return tessera::runRelay(runtime, executable, initial, idleMs);
        } catch (...) { return 77; }
    }
    return 64;
}
