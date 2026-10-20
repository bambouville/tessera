// Synthetic-test driver, not bundled in the host artifact. Drives one
// WindowSession like ReadWorker does, but with a caller-chosen service total,
// so budget-bounded revision slices can be tested without 64 MiB of windows.
#include "HistoryMetadataBudget.h"
#include "Json.h"
#include "WindowSession.h"
#include <iostream>

int main(int argc, char** argv) {
    if (argc != 3) return 64;
    try {
        tessera::Catalog catalog; tessera::CodexServer codex;
        tessera::HistoryMetadataBudget budget;
        tessera::ClaudeChainCache chains{&budget};
        tessera::KimiHistoryCache kimi{&budget};
        tessera::CodexHistoryCache histories{&budget};
        auto source = catalog.resolve(argv[1], argv[2]);
        tessera::WindowSession session;
        // The client's retained ids, as the apps track them for ACKs.
        std::vector<std::string> viewport;
        std::string head, transaction;
        uint64_t serial = 0, pendingVersion = 0;
        std::string line;
        while (std::getline(std::cin, line)) {
            simdjson::dom::parser parser; simdjson::dom::element request;
            if (line.size() > 1024 || parser.parse(line).get(request)) return 64;
            tessera::json::Object output;
            try {
                const auto operation = tessera::json::text(request, "op");
                if (operation == "ack") {
                    session.acknowledge(transaction, pendingVersion, viewport, head);
                    output.number("windowVersion", session.version());
                } else if (operation == "bootstrap" || operation == "head") {
                    uint64_t serviceBytes = 0;
                    if (tessera::json::get(request, "serviceBytes").get_uint64().get(serviceBytes)) return 64;
                    transaction = "t" + std::to_string(++serial);
                    tessera::WindowReply reply;
                    for (int attempt = 0;; ++attempt) {
                        tessera::WindowPageReader reader(catalog, codex, {}, &chains, false, &histories, &kimi);
                        try {
                            reply = session.read(reader, codex, source, transaction, operation,
                                operation == "head" ? session.liveCursor() : "", session.version(), 100, false,
                                static_cast<size_t>(serviceBytes));
                            break;
                        } catch (const std::runtime_error& error) {
                            // ReadWorker re-queues an index continuation.
                            if (std::string(error.what()) != "readPending" || attempt >= 1000) throw;
                        }
                    }
                    pendingVersion = reply.version;
                    if (reply.lane == "revisions") {
                        std::vector<std::string> next;
                        for (const auto& id : viewport) {
                            bool split = false;
                            for (const auto& part : reply.partitions) if (part.original == id) { next.push_back(part.id); split = true; }
                            if (!split) next.push_back(id);
                        }
                        // A split head keeps only its final part.
                        const auto original = head;
                        for (const auto& part : reply.partitions) if (part.original == original) head = part.id;
                        viewport = std::move(next);
                    } else {
                        viewport = {reply.segment->id}; head = reply.segment->id;
                    }
                    std::string records;
                    for (const auto& record : reply.records) {
                        tessera::json::Object value; value.string("id", record.value.providerID);
                        value.number("revision", record.revision); value.raw("body", record.value.json);
                        if (!records.empty()) records += ',';
                        records += value.finish();
                    }
                    output.string("lane", reply.lane); output.raw("records", "[" + records + "]");
                    output.boolean("hasNewer", reply.hasNewer); output.number("partitions", reply.partitions.size());
                } else return 64;
            } catch (const std::exception& error) { output.string("error", error.what()); }
            output.number("footprint", session.footprint());
            std::cout << output.finish() << std::endl;
        }
    } catch (...) { return 65; }
}
