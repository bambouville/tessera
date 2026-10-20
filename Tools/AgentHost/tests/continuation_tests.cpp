#include "JsonlReader.h"
#include "ReadWorker.h"
#include "Json.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
#include <poll.h>

using namespace tessera;
static void giant(const std::string& path, bool newline = true, bool malformedTail = false) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << "{\"type\":\"user\",\"uuid\":\"large\",\"opaque\":\"";
    const std::string block(65536, 'x');
    for (int n = 0; n < 70 * 16; ++n) file << block;
    file << "\",\"message\":{\"content\":\"after giant field\"}}";
    if (malformedTail) file << '!';
    if (newline) file << '\n';
}
int main() {
    char pattern[] = "/tmp/tessera-jsonl-continuation-XXXXXX";
    const auto* directory = ::mkdtemp(pattern); assert(directory);
    const std::string path = std::string(directory) + "/synthetic.jsonl";
    // Finished results are keyed by the exact source and record bounds.
    {
        JsonlContinuation context;
        JsonlContinuation::Source source{path, "jsonl:1:2", "stamp:a", "claude", 1000, 0};
        NormalizedRecord value; value.json = "first"; value.providerID = "record";
        context.remember(source, 10, 20, value);
        const auto* hit = context.result(source, 10, 20);
        assert(hit && hit->json == "first" && hit->providerID == "record");
        assert(context.result(source, 10, 21) == nullptr);
        auto changedStamp = source; changedStamp.stamp = "stamp:b";
        assert(context.result(changedStamp, 10, 20) == nullptr);
        assert(context.result(source, 10, 20) == nullptr);
        context.remember(source, 10, 20, value);
        auto replaced = source; replaced.identity = "jsonl:1:3";
        assert(context.result(replaced, 10, 20) == nullptr);
        assert(context.result(source, 10, 20) == nullptr);
        auto revised = source; revised.observedRevision = 7;
        context.remember(revised, 10, 20, value);
        auto nextRevision = revised; nextRevision.observedRevision = 8;
        assert(context.result(nextRevision, 10, 20) == nullptr);
        assert(context.result(revised, 10, 20) == nullptr);
    }
    // A hit moves to the newest LRU position before count pressure evicts.
    {
        JsonlContinuation context;
        JsonlContinuation::Source source{path, "jsonl:1:2", "stamp", "claude", 1000, 0};
        NormalizedRecord value; value.json = "small";
        for (size_t index = 0; index < JsonlContinuation::resultLimit; ++index)
            context.remember(source, index, index + 1, value);
        assert(context.result(source, 0, 1) != nullptr);
        context.remember(source, JsonlContinuation::resultLimit, JsonlContinuation::resultLimit + 1, value);
        assert(context.result(source, 0, 1) != nullptr);
        assert(context.result(source, 1, 2) == nullptr);
        assert(context.result(source, JsonlContinuation::resultLimit, JsonlContinuation::resultLimit + 1));
    }
    // Byte pressure evicts even below the entry count; a single oversized
    // normalized result is omitted rather than crowding out existing entries.
    {
        JsonlContinuation context;
        JsonlContinuation::Source source{path, "jsonl:1:2", "stamp", "claude", 1000, 0};
        NormalizedRecord value; value.json.assign(400 * 1024, 'x');
        for (uint64_t index = 0; index < 21; ++index)
            context.remember(source, index, index + 1, value);
        assert(context.result(source, 0, 1) == nullptr);
        assert(context.result(source, 20, 21) != nullptr);
        value.json.assign(JsonlContinuation::resultBudget / 16, 'x');
        context.remember(source, 100, 101, value);
        assert(context.result(source, 100, 101) == nullptr);
        assert(context.result(source, 20, 21) != nullptr);
    }
    // A new reader must reuse the default normalized result without physical
    // I/O. Custom normalization must run again, even for the same source.
    {
        const std::string line = "{\"type\":\"user\",\"uuid\":\"cached\",\"message\":{\"content\":\"hello\"}}\n";
        std::ofstream(path) << line;
        JsonlContinuation context; JsonlContinuation::Scope scope(context);
        context.beginSlice();
        JsonlReader first(path, "claude");
        const auto initial = first.readRecord(0, line.size());
        assert(first.bytesRead() > 0);
        JsonlReader second(path, "claude");
        const auto cached = second.readRecord(0, line.size());
        assert(second.bytesRead() == 0);
        assert(cached.value.json == initial.value.json);
        assert(cached.value.providerID == initial.value.providerID);
        int calls = 0;
        auto custom = [&](simdjson::dom::element source, bool truncated) {
            ++calls; return normalize("claude", source, truncated);
        };
        JsonlReader customFirst(path, "claude"); customFirst.setNormalizer(custom);
        assert(customFirst.readRecord(0, line.size()).value.json == initial.value.json);
        assert(customFirst.bytesRead() > 0);
        JsonlReader customSecond(path, "claude"); customSecond.setNormalizer(custom);
        assert(customSecond.readRecord(0, line.size()).value.json == initial.value.json);
        assert(customSecond.bytesRead() > 0 && calls == 2);
    }
    // A validated giant-record continuation survives interleaved
    // pre-validation observations of the same file (a bounded header check
    // has no revision). Only a later revision, or a different inode, retires it.
    {
        JsonlContinuation context;
        JsonlContinuation::Source validated{path, "jsonl:1:2", "stamp:observed:7", "codex", 1000, 7};
        JsonlContinuation::Source header{path, "jsonl:1:2", "stamp", "codex", 1000, 0};
        JsonlContinuation::Source revised{path, "jsonl:1:2", "stamp:observed:8", "codex", 1200, 8};
        JsonlContinuation::Source replaced{path, "jsonl:1:3", "stamp", "codex", 1000, 0};
        JsonlContinuation::Record pending(true);
        pending.source = validated; pending.start = 100; pending.position = 600; pending.end = 1000;
        pending.locateEnd = true; pending.oversized = true;
        context.retain(std::move(pending));
        assert(context.find(header, 0, 1000, true) == nullptr);
        assert(context.find(validated, 100, 1000, true) != nullptr);
        assert(context.find(revised, 100, 1200, true) == nullptr);
        assert(context.find(validated, 100, 1000, true) == nullptr);
        JsonlContinuation::Record again(true);
        again.source = validated; again.start = 100; again.position = 600; again.end = 1000;
        again.locateEnd = true; again.oversized = true;
        context.retain(std::move(again));
        assert(context.find(replaced, 100, 1000, true) == nullptr);
        assert(context.find(validated, 100, 1000, true) == nullptr);
        auto& scan = context.scan(validated, 1000, false); scan.position = 500;
        (void)context.scan(header, 1000, false);
        assert(context.scan(validated, 1000, false).position == 500);
        (void)context.scan(revised, 1200, false);
        assert(context.scan(validated, 1000, false).position == 1000);
    }
    for (bool forward : {true, false}) {
        giant(path);
        JsonlContinuation context; JsonlContinuation::Scope scope(context);
        uint64_t consumed = 0; int yields = 0;
        for (;;) {
            context.beginSlice();
            JsonlReader reader(path, "claude");
            try {
                auto page = reader.page(UINT64_MAX, forward, 1);
                consumed += context.consumed();
                assert(page.records.size() == 1);
                assert(page.records[0].value.providerID == "large");
                assert(page.records[0].value.json.find("after giant field") != std::string::npos);
                assert(page.records[0].value.disposition == "message");
                break;
            } catch (const std::runtime_error& error) {
                assert(std::string(error.what()) == "readPending");
                consumed += context.consumed();
                assert(context.consumed() <= JsonlContinuation::sliceLimit);
                assert(++yields < 5);
            }
        }
        assert(yields >= 1);
        assert(consumed <= std::filesystem::file_size(path) * (forward ? 1 : 2) + 1024 * 1024);
    }
    // Cancellation after promotion retains validated streaming state. Reopen
    // and continue; never finish from a clipped prefix without tail validation.
    for (const bool malformed : {false, true}) {
        giant(path, true, malformed);
        JsonlContinuation context; JsonlContinuation::Scope scope(context);
        context.beginSlice(); int checks = 0; bool cancelled = false;
        try { JsonlReader reader(path, "claude", -1, [&] { return ++checks > 100; }); reader.page(0, true, 1); }
        catch (const std::runtime_error& error) { cancelled = std::string(error.what()) == "cancelled"; }
        assert(cancelled);
        for (int tries = 0;; ++tries) {
            assert(tries < 4); context.beginSlice(); JsonlReader reader(path, "claude");
            try {
                auto page = reader.page(0, true, 1);
                assert(page.records.size() == 1);
                assert(page.records[0].value.disposition == (malformed ? "malformed" : "message"));
                break;
            } catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); }
        }
    }
    // Truncation/rewrite invalidates a pending projection and its scan cache.
    {
        giant(path); JsonlContinuation context; JsonlContinuation::Scope scope(context);
        context.beginSlice(); bool pending = false;
        try { JsonlReader reader(path, "claude"); reader.page(0, true, 1); }
        catch (const std::runtime_error& error) { pending = std::string(error.what()) == "readPending"; }
        assert(pending);
        std::ofstream(path) << "{\"type\":\"user\",\"uuid\":\"replacement\",\"message\":{\"content\":\"new\"}}\n";
        context.beginSlice(); JsonlReader reader(path, "claude"); auto page = reader.page(0, true, 1);
        assert(page.records.size() == 1 && page.records[0].value.providerID == "replacement");
    }
    // Growth is not proof of append-only mutation. A rewrite plus append must
    // never reuse a previously completed body or an in-flight JSON decoder.
    {
        giant(path); JsonlContinuation context; JsonlContinuation::Scope scope(context);
        for (;;) {
            context.beginSlice(); JsonlReader reader(path, "claude");
            try { assert(reader.page(0, true, 1).records[0].value.providerID == "large"); break; }
            catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); }
        }
        {
            std::fstream file(path, std::ios::in | std::ios::out | std::ios::binary);
            const std::string prefix = "{\"type\":\"user\",\"uuid\":\"";
            file.seekp(prefix.size()); file << "newid";
            file.seekp(0, std::ios::end); file << "\n";
        }
        for (;;) {
            context.beginSlice(); JsonlReader reader(path, "claude");
            try { assert(reader.page(0, true, 1).records[0].value.providerID == "newid"); break; }
            catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); }
        }
    }
    // A giant unfinished physical line is not malformed or a visible message.
    {
        giant(path, false); JsonlContinuation context; JsonlContinuation::Scope scope(context);
        int yields = 0;
        for (;;) {
            context.beginSlice(); JsonlReader reader(path, "claude");
            try { assert(reader.page(0, true, 1).records.empty()); break; }
            catch (const std::runtime_error& error) { assert(std::string(error.what()) == "readPending"); assert(++yields < 4); }
        }
        assert(yields > 0);
    }
    // A yielded bootstrap stays before its same-client cancel drain barrier.
    {
        const auto providerHome = std::string(directory) + "/claude";
        const auto providerPath = providerHome + "/projects/project/synthetic.jsonl";
        std::filesystem::create_directories(std::filesystem::path(providerPath).parent_path());
        giant(providerPath);
        assert(::setenv("CLAUDE_CONFIG_DIR", providerHome.c_str(), 1) == 0);
        assert(::setenv("PI_CODING_AGENT_DIR", (std::string(directory) + "/pi").c_str(), 1) == 0);
        assert(::setenv("CODEX_HOME", (std::string(directory) + "/codex").c_str(), 1) == 0);
        ReadWorker worker("synthetic");
        auto receive = [&] {
            // A notification byte may outlive the take() that already
            // drained its result; wait for results, not for wakeups.
            for (;;) {
                pollfd descriptor{worker.notificationFD(), POLLIN, 0};
                assert(::poll(&descriptor, 1, 10000) > 0);
                worker.drainNotifications();
                auto results = worker.take();
                if (!results.empty()) return results;
            }
        };
        assert(worker.submit({1, "{\"kind\":\"resolve\",\"id\":\"resolve\",\"provider\":\"claude\",\"transcriptRef\":\"" + providerPath + "\"}"}));
        auto resolved = receive(); assert(resolved.size() == 1 && !resolved[0].failed);
        const auto thread = resolved[0].thread;
        ReadJob large{1, "{\"kind\":\"window.read\",\"id\":\"read\",\"thread\":\"" + thread +
            "\",\"operation\":\"bootstrap\",\"windowVersion\":0,\"readProgress\":true}"};
        // An old absolute deadline must not abandon a slice that still makes
        // physical progress. Each intermediate result keeps read admission.
        large.continuationDeadline = std::chrono::steady_clock::now() - std::chrono::seconds(1);
        assert(worker.submit(std::move(large)));
        assert(worker.submit({1, "{\"kind\":\"window.cancel\",\"id\":\"cancel\",\"thread\":\"" + thread +
            "\",\"transaction\":\"read\"}", false, true}));
        assert(worker.submit({2, "{\"kind\":\"resolve\",\"id\":\"other\",\"provider\":\"claude\",\"transcriptRef\":\"" + providerPath + "\"}"}));
        std::vector<std::string> completed;
        uint64_t progressSequence = 0, progressBytes = 0;
        while (completed.size() < 3) for (const auto& result : receive()) {
            assert(!result.failed);
            if (result.pending) {
                assert(result.id == "read" && result.thread == thread && result.frames.size() == 1);
                simdjson::dom::parser parser;
                const auto value = parser.parse(result.frames.front()).value();
                const auto sequence = std::stoull(json::text(value, "sequence"));
                const auto bytes = std::stoull(json::text(value, "bytesRead"));
                assert(sequence > progressSequence && bytes > progressBytes);
                assert(json::text(value, "kind") == "read.progress");
                assert(json::text(json::get(value, "status"), "recovery") == "continue");
                progressSequence = sequence; progressBytes = bytes;
            } else completed.push_back(result.id);
        }
        assert(progressSequence > 0 && progressBytes > 0);
        assert((completed == std::vector<std::string>{"other", "read", "cancel"}));
        // The receipt frontier reads current raw EOF, including a partial tail,
        // with no page transaction or history/index admission dependency.
        { std::ofstream file(providerPath, std::ios::app); file << "{\"unfinished\":"; }
        assert(worker.submit({1, "{\"kind\":\"receipt.frontier\",\"id\":\"frontier\",\"thread\":\"" + thread +
            "\",\"actionID\":\"action\"}", false, true, true}));
        auto frontier = receive(); assert(frontier.size() == 1 && !frontier[0].failed && !frontier[0].requiresWindowAck);
        simdjson::dom::parser parser;
        const auto frame = parser.parse(frontier[0].frames[0]).value();
        const auto proof = json::get(frame, "frontier");
        assert(json::text(proof, "consistency") == "observedPrefix");
        assert(std::stoull(json::text(proof, "sourceEnd")) == std::filesystem::file_size(providerPath));
        assert(json::text(proof, "actionID") == "action");
        assert(json::text(proof, "sourceIdentity").rfind("jsonl:", 0) == 0);
        worker.shutdown();
    }
    std::filesystem::remove_all(directory);
    std::cout << "oversized forward/backward, cancellation, tail validation, rewrite and partial-line continuation passed\n";
}
