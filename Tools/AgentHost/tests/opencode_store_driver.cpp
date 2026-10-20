// Test-only driver: not included in the distributed helper.
#include "OpenCodeStore.h"
#include "FileWakeups.h"
#include "Json.h"
#include "ReadWorker.h"
#include <chrono>
#include <iostream>
#include <memory>
#include <sys/resource.h>
#include <thread>
int main(int argc, char** argv) {
    if (argc != 2) return 64;
    std::string line;
    std::unique_ptr<tessera::ReadWorker> worker;
    while (std::getline(std::cin, line)) {
        try {
            simdjson::dom::parser parser; auto request = parser.parse(line).value();
            tessera::json::Object result;
            const auto operation = tessera::json::text(request, "operation");
            if (operation == "worker") {
                if (!worker) {
                    tessera::Catalog::freezeProviderEnvironment();
                    worker = std::make_unique<tessera::ReadWorker>("test-epoch");
                }
                tessera::ReadJob job;
                job.client = 1;
                job.request = tessera::json::text(request, "request");
                job.continuationDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                if (!worker->submit(std::move(job))) throw std::runtime_error("workerBusy");
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                bool completed = false;
                while (std::chrono::steady_clock::now() < deadline && !completed) {
                    for (const auto& reply : worker->take()) {
                        if (reply.pending) continue;
                        result.raw("frames", tessera::json::array(reply.frames));
                        result.boolean("failed", reply.failed);
                        completed = true;
                    }
                    if (!completed) std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if (!completed) throw std::runtime_error("workerTimeout");
                std::cout << result.finish() << std::endl; continue;
            }
            if (operation == "codexTitle") {
                result.string("title", tessera::OpenCodeStore::codexTitle(argv[1], tessera::json::text(request, "session"), {}));
                std::cout << result.finish() << std::endl; continue;
            }
            if (operation == "codexMetadata") {
                const auto metadata = tessera::OpenCodeStore::codexMetadata(argv[1], tessera::json::text(request, "session"), {});
                result.optional("nativeTitle", metadata.name, 512);
                result.optional("openingPrompt", metadata.openingPrompt, 4096);
                std::cout << result.finish() << std::endl; continue;
            }
            tessera::OpenCodeStore database(argv[1]);
            result.boolean("snapshot", database.snapshot());
            if (operation == "hold") {
                // Test seam: the store is open; the test mutates the file, then
                // the read below must notice or refuse.
                std::cout << "{\"ready\":true}" << std::endl;
                std::string signal; std::getline(std::cin, signal);
            }
            if (operation == "watch") {
                tessera::FileWakeups wakeups;
                wakeups.watch("synthetic", tessera::OpenCodeStore::wakeupDescriptor(argv[1]));
                std::cout << "{\"ready\":true}" << std::endl;
                std::string signal; std::getline(std::cin, signal);
                result.boolean("changed", !wakeups.take().empty());
            } else if (operation == "inventory" || operation == "hold") {
                std::vector<std::string> sessions;
                for (const auto& row : database.inventory()) sessions.push_back(tessera::json::quote(row.id));
                result.raw("sessions", tessera::json::array(sessions));
            } else {
                const auto session = tessera::json::text(request, "session");
                tessera::OpenCodeStore::Key key{tessera::json::integer(request, "created"), tessera::json::text(request, "id"),
                    tessera::json::text(request, "message").empty() ? "msg_synthetic" : tessera::json::text(request, "message")};
                const auto rows = operation == "exact" ?
                    std::vector<tessera::OpenCodeStore::Row>{database.exact(session, key)} :
                    database.page(session, key.id.empty() ? nullptr : &key, tessera::json::boolean(request, "forward"), 10);
                result.string("identity", database.identity(session)); std::vector<std::string> encoded;
                for (const auto& row : rows) {
                    tessera::json::Object value; value.string("id", row.key.id); value.number("created", row.key.created);
                    value.string("message", row.key.message);
                    value.raw("record", row.value.json); value.string("disposition", row.value.disposition); encoded.push_back(value.finish());
                }
                result.raw("rows", tessera::json::array(encoded)); result.number("bytesRead", database.bytesRead());
            }
            rusage usage{}; ::getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
            result.number("peakRSSBytes", usage.ru_maxrss);
#else
            result.number("peakRSSBytes", usage.ru_maxrss * 1024);
#endif
            std::cout << result.finish() << std::endl;
        } catch (const std::exception& error) {
            std::cout << "{\"error\":" << tessera::json::quote(error.what(), 128) << "}" << std::endl;
        }
    }
}
