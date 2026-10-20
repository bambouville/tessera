#include "CodexHistoryIndex.h"
#include "Json.h"
#include <cassert>
#include <fstream>
#include <unistd.h>

int main() {
    using Index = tessera::CodexHistoryIndex;
    char filename[] = "/tmp/tessera-codex-index-XXXXXX";
    const auto descriptor = ::mkstemp(filename); assert(descriptor >= 0); ::close(descriptor);
    const std::string meta = R"({"ordinal":0,"type":"session_meta","payload":{"id":"child","history_mode":"paginated","subagent_history_start_ordinal":2}})" "\n";
    auto item = [](size_t ordinal, const char* owner, const char* id, const char* body) {
        return std::string("{\"ordinal\":") + std::to_string(ordinal) +
            ",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":" + tessera::json::quote(owner) +
            ",\"turn_id\":\"turn\",\"item\":{\"type\":\"AgentMessage\",\"id\":" + tessera::json::quote(id) +
            ",\"content\":[{\"type\":\"Text\",\"text\":" + tessera::json::quote(body) + "}]}}}\n";
    };
    auto refreshBudget = [&](Index& index, size_t budget) {
        for (;;) {
            try { tessera::JsonlReader reader(filename, "codex", -1, {}, Index::metadata); index.refresh(reader, {}, budget); return; }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "readPending") throw; }
        }
    };
    auto refresh = [&](Index& index) { refreshBudget(index, tessera::HistoryMetadataBudget::indexLimit); };
    auto selected = [&](Index& index, size_t position) {
        for (;;) {
            try { tessera::JsonlReader reader(filename, "codex", -1, {}, Index::metadata); return index.entry(reader, position); }
            catch (const std::runtime_error& error) { if (std::string(error.what()) != "readPending") throw; }
        }
    };
    // Total history is not a record-count admission budget. Content remains
    // paged even when metadata spans more than the former 20,000 entries.
    {
        std::ofstream file(filename);
        file << R"({"ordinal":0,"type":"session_meta","payload":{"id":"long","history_mode":"paginated"}})" "\n";
        for (size_t i = 1; i <= 20001; ++i)
            file << item(i, "long", ("large-" + std::to_string(i)).c_str(), "fixture");
    }
    Index overOldLimit; refresh(overOldLimit);
    assert(overOldLimit.size() == 20001 && selected(overOldLimit, 20000).id == "large-20001");
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "parent body") << item(2, "child", "a", "first"); }
    Index index; refresh(index);
    assert(index.paginated() && index.size() == 1 && selected(index, 0).id == "a");
    const auto generation = index.generation(); const auto firstOffset = selected(index, 0).start;
    { std::ofstream file(filename, std::ios::app); file << item(3, "child", "b", "second") << item(4, "child", "a", "revised"); }
    refresh(index);
    assert(index.generation() == generation && index.size() == 2);
    assert(selected(index, 0).ordinal == 2 && selected(index, 0).updatedOrdinal == 4 && selected(index, 0).start > firstOffset);
    assert(selected(index, 1).id == "b" && selected(index, 1).ordinal == 3);
    {
        tessera::JsonlReader reader(filename, "codex", -1, {}, Index::completed);
        const auto& entry = selected(index, 0);
        assert(reader.readRecord(entry.start, entry.end).value.json.find("revised") != std::string::npos);
    }
    const auto bytes = index.bytes(); refresh(index); assert(index.bytes() == bytes && index.generation() == generation);
    // Upstream skips rejected/blank complete lines without consuming an
    // ordinal. Keep explicit diagnostic rows, then accept its retried ordinal.
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context")
        << item(2, "child", "before", "before") << "not json\n\n"
        << item(3, "child", "after", "after"); }
    Index repaired; refresh(repaired);
    assert(repaired.size() == 4 && selected(repaired, 0).id == "before" && selected(repaired, 3).id == "after");
    for (size_t i = 1; i <= 2; ++i) {
        tessera::JsonlReader reader(filename, "codex", -1, {}, Index::completed);
        const auto& entry = selected(repaired, i);
        const auto diagnostic = reader.readRecord(entry.start, entry.end);
        assert(diagnostic.value.disposition == "malformed" && diagnostic.value.visible);
    }
    const auto repairedGeneration = repaired.generation();
    refresh(repaired); assert(repaired.size() == 4 && repaired.generation() == repairedGeneration);
    // A corrupt line must not invent the ordinal of a lost valid event.
    { std::ofstream file(filename, std::ios::app); file << "broken\n" << item(5, "child", "gap", "gap"); }
    bool missingOrdinal = false;
    try { refresh(repaired); } catch (const std::runtime_error& error) {
        missingOrdinal = std::string(error.what()) == "codexOrdinalDiscontinuity";
    }
    assert(missingOrdinal && repaired.size() == 4 && repaired.generation() == repairedGeneration);
    for (const auto rejected : {
        "{}\n",
        R"({"ordinal":2,"type":"event_msg","payload":null})" "\n",
        R"({"ordinal":2,"type":"event_msg","payload":{"type":7}})" "\n",
        R"({"ordinal":2,"type":"response_item","payload":null})" "\n",
        R"({"ordinal":2,"type":"event_msg","payload":{"type":"item_completed","thread_id":"child","turn_id":"turn","item":{"type":"AgentMessage","content":[]}}})" "\n",
        R"({"ordinal":"bad","type":"event_msg","payload":{"type":"task_started"}})" "\n"
    }) {
        { std::ofstream file(filename); file << meta << item(1, "parent", "context", "context")
            << rejected << item(2, "child", "retried", "valid retry"); }
        Index recovered; refresh(recovered);
        assert(recovered.size() == 2 && selected(recovered, 1).ordinal == 2);
        tessera::JsonlReader reader(filename, "codex", -1, {}, Index::completed);
        assert(reader.readRecord(selected(recovered, 0).start, selected(recovered, 0).end).value.disposition == "malformed");
    }
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context")
        << R"({"ordinal":2,"type":"event_msg","payload":{"type":"future_visible_event","message":"not understood"}})" "\n"
        << item(3, "child", "after-unknown", "after"); }
    Index unknown; refresh(unknown);
    assert(unknown.size() == 2 && selected(unknown, 0).id.empty() && selected(unknown, 1).id == "after-unknown");
    {
        tessera::JsonlReader reader(filename, "codex", -1, {}, Index::completed);
        const auto diagnostic = reader.readRecord(selected(unknown, 0).start, selected(unknown, 0).end);
        assert(diagnostic.value.disposition == "unclassified" && diagnostic.value.visible);
    }
    { std::ofstream file(filename); file << meta << R"({"ordinal":1,"type":"session_meta","payload":{"id":"parent","history_mode":"paginated"}})" "\n" << item(2, "child", "own", "own body"); }
    Index inherited; refresh(inherited);
    assert(inherited.sessionID() == "child" && inherited.size() == 1 && selected(inherited, 0).id == "own");
    const auto pinnedGeneration = inherited.generation(); const auto pinnedEntry = selected(inherited, 0);
    { std::ofstream file(filename, std::ios::app); file << item(3, "child", "own", "revised") << item(4, "child", "new", "new body"); }
    refreshBudget(inherited, 4096);
    assert(inherited.lazy() && inherited.generation() == pinnedGeneration && inherited.size() == 2);
    assert(selected(inherited, 0).updatedOrdinal == 3 && selected(inherited, 0).start > pinnedEntry.start);
    refresh(inherited); assert(inherited.generation() == pinnedGeneration && inherited.size() == 2 && selected(inherited, 0).updatedOrdinal == 3);
    for (const auto raw : {
        R"({"ordinal":5,"type":"session_meta","payload":{"id":"fixture","history_mode":"paginated"}})" "\n",
        R"({"ordinal":0,"type":"session_meta","payload":{"id":"fixture","history_mode":"future"}})" "\n",
        R"({"ordinal":0,"type":"session_meta","payload":{"id":"fixture","history_mode":"paginated","history_base":{}}})" "\n",
        R"({"ordinal":0,"type":"event_msg","payload":{"type":"task_started"}})" "\n",
        R"({"type":"session_meta","payload":{"id":"fixture","history_mode":"paginated"}})" "\n"
    }) {
        { std::ofstream file(filename); file << raw; }
        Index bad; bool rejected = false;
        try { refresh(bad); } catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
    }
    { std::ofstream file(filename); file << R"({"type":"session_meta","payload":{"id":"old","history_mode":"legacy"}})" "\n"; }
    Index old; refresh(old); assert(!old.paginated() && old.sessionID() == "old");
    // Codex rollouts can carry a thread_settings_applied row that repeats the
    // preceding ordinal, with the counter continuing from that value. A repeat
    // is tolerated only on rows without transcript content: settings and
    // diagnostic rows, inside or above the inherited prefix, and under a lazy
    // refresh; a repeated session_meta or item row still fails closed.
    auto settings = [](size_t ordinal, const char* owner) {
        return std::string("{\"ordinal\":") + std::to_string(ordinal) +
            ",\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_id\":" + tessera::json::quote(owner) +
            ",\"thread_settings\":{\"model\":\"m\",\"cwd\":\"/x\",\"model_provider_id\":\"openai\",\"approval_policy\":\"on-request\","
            "\"approvals_reviewer\":\"user\",\"permission_profile\":{},\"collaboration_mode\":{},\"runtime_workspace_roots\":[],\"disabled_plugin_ids\":[]}}}\n";
    };
    auto rejectedWith = [&](const char* code) {
        Index bad; std::string caught;
        try { refresh(bad); } catch (const std::runtime_error& error) { caught = error.what(); }
        return caught == code;
    };
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context") << settings(1, "parent") << item(2, "child", "own", "own body"); }
    Index inheritedRepeat; refresh(inheritedRepeat);
    assert(inheritedRepeat.size() == 1 && selected(inheritedRepeat, 0).id == "own");
    { std::ofstream file(filename); file << meta << R"({"ordinal":1,"type":"session_meta","payload":{"id":"parent","history_mode":"paginated"}})" "\n"
        << R"({"ordinal":1,"type":"session_meta","payload":{"id":"grandparent","history_mode":"paginated"}})" "\n" << item(2, "child", "own", "own body"); }
    assert(rejectedWith("codexOrdinalDiscontinuity"));
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context") << item(2, "child", "before", "before")
        << R"({"ordinal":2,"type":"event_msg","payload":{"type":"future_visible_event","message":"not understood"}})" "\n" << item(3, "child", "after", "after"); }
    Index diagnosticRepeat; refresh(diagnosticRepeat);
    assert(diagnosticRepeat.size() == 3 && selected(diagnosticRepeat, 0).id == "before" && selected(diagnosticRepeat, 1).id.empty() && selected(diagnosticRepeat, 2).id == "after");
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context") << item(2, "child", "a", "first"); }
    Index lazyRepeat; refresh(lazyRepeat); assert(lazyRepeat.size() == 1);
    { std::ofstream file(filename, std::ios::app); file << settings(2, "child") << item(3, "child", "b", "second") << item(4, "child", "a", "revised"); }
    refreshBudget(lazyRepeat, 4096);
    assert(lazyRepeat.lazy() && lazyRepeat.size() == 2 && selected(lazyRepeat, 0).updatedOrdinal == 4 && selected(lazyRepeat, 1).id == "b");
    { std::ofstream file(filename); file << meta << item(1, "parent", "inherited", "context") << item(2, "child", "a", "first") << item(2, "child", "b", "second"); }
    assert(rejectedWith("codexOrdinalDiscontinuity"));
    const std::string legacyMeta = R"({"type":"session_meta","payload":{"id":"old","history_mode":"legacy"}})" "\n";
    const std::string begin = R"({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}})" "\n";
    auto legacy = [](bool event, const char* role, const std::string& body) {
        const auto text = tessera::json::quote(body, body.size());
        if (event) return std::string(R"({"type":"event_msg","payload":{"type":)") + tessera::json::quote(std::string(role) == "user" ? "user_message" : "agent_message") + ",\"message\":" + text + "}}\n";
        return std::string(R"({"type":"response_item","payload":{"type":"message","role":)") + tessera::json::quote(role) + ",\"content\":[{\"type\":\"input_text\",\"text\":" + text + "}]}}\n";
    };
    { std::ofstream file(filename); file << legacyMeta << begin << legacy(false, "user", "same") << legacy(true, "user", "same")
        << legacy(true, "assistant", "reply"); }
    Index mirrored; refresh(mirrored);
    assert(mirrored.indexed() && !mirrored.paginated() && mirrored.size() == 4 && mirrored.mirroredRecords() == 1);
    const auto legacyGeneration = mirrored.generation(); const auto legacyTail = selected(mirrored, 3).start;
    { std::ofstream file(filename, std::ios::app); file << legacy(false, "assistant", "reply") << begin
        << legacy(true, "user", "same") << legacy(true, "user", "same")
        << legacy(false, "user", "same") << legacy(false, "user", "same"); }
    refresh(mirrored);
    assert(mirrored.generation() == legacyGeneration && selected(mirrored, 3).start == legacyTail);
    assert(mirrored.size() == 7 && mirrored.mirroredRecords() == 4);
    // Same preview is insufficient proof: differing suffixes remain visible.
    const std::string shared(20000, 'x');
    { std::ofstream file(filename, std::ios::app); file << begin << legacy(false, "assistant", shared + "a") << legacy(true, "assistant", shared + "b"); }
    refresh(mirrored); assert(mirrored.size() == 10 && mirrored.mirroredRecords() == 4);
    const auto legacyCount = mirrored.size(), legacyBytes = mirrored.bytes();
    { std::ofstream file(filename, std::ios::app); file << legacy(true, "assistant", "capacity"); }
    (void)legacyBytes;
    refreshBudget(mirrored, 4096);
    assert(mirrored.lazy() && mirrored.size() == legacyCount + 1 && mirrored.generation() == legacyGeneration);
    refresh(mirrored); assert(mirrored.size() == legacyCount + 1);
    { std::ofstream file(filename, std::ios::app); file << legacy(false, "assistant", "capacity"); }
    refresh(mirrored); assert(mirrored.size() == legacyCount + 1 && mirrored.mirroredRecords() == 5);
    // Malformed physical records remain a visible diagnostic, not EOF.
    { std::ofstream file(filename, std::ios::app); file << "not json\n" << legacy(true, "assistant", "after malformed"); }
    refresh(mirrored); assert(mirrored.size() == legacyCount + 3);
    { std::ofstream file(filename); file << legacyMeta << begin; for (int i = 0; i < 150; ++i)
        file << legacy(false, "assistant", std::to_string(i)) << legacy(true, "assistant", std::to_string(i)); }
    Index legacyResumed; size_t legacyChecks = 0;
    try { tessera::JsonlReader reader(filename, "codex", -1, {}, Index::metadata); legacyResumed.refresh(reader, [&] { return ++legacyChecks == 23; }); }
    catch (const std::runtime_error& error) { assert(std::string(error.what()) == "cancelled"); }
    assert(legacyResumed.size() > 2 && legacyResumed.size() < 152);
    refresh(legacyResumed); assert(legacyResumed.size() == 152 && legacyResumed.mirroredRecords() == 150);
    // Positional annotations can exclude injected fragments from the visible
    // response. Raw concatenation is then not proof of authored equality.
    { std::ofstream file(filename); file << legacyMeta
        << R"({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"A"},{"type":"input_text","text":"B"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["context.environment","user.text"]}}})" "\n"
        << legacy(true, "user", "AB"); }
    Index annotated; refresh(annotated); assert(annotated.size() == 3 && annotated.mirroredRecords() == 0);
    // Cancellation leaves committed batches resumable, including revisions.
    { std::ofstream file(filename); file << meta; for (size_t i = 1; i < 401; ++i) file << item(i, "child", ("id" + std::to_string(i)).c_str(), "fixture"); }
    Index resumed; size_t checks = 0; bool cancelled = false;
    try {
        tessera::JsonlReader reader(filename, "codex", -1, {}, Index::metadata);
        resumed.refresh(reader, [&] { return ++checks == 3; });
    } catch (const std::runtime_error& error) { cancelled = std::string(error.what()) == "cancelled"; }
    assert(cancelled); const auto resumableGeneration = resumed.generation(); refresh(resumed);
    assert(resumed.generation() == resumableGeneration && resumed.size() == 399);
    // A 64 MiB read slice ends inside the next record, evicting the last
    // admitted boundary. Canonical indexing must still witness and commit
    // that prefix, then resume without missing or duplicating ordinals.
    {
        std::ofstream file(filename);
        file << R"({"ordinal":0,"type":"session_meta","payload":{"id":"large","history_mode":"paginated"}})" "\n";
        const std::string opaque(4 * 1024 * 1024, 'x');
        for (size_t i = 1; i <= 20; ++i) {
            file << "{\"ordinal\":" << i << ",\"type\":\"world_state\",\"payload\":{\"full\":false,\"state\":\"" << opaque << "\"}}\n";
        }
        file << item(21, "large", "after-slice", "admitted after continuation");
    }
    Index sliced; refresh(sliced);
    assert(sliced.paginated() && sliced.size() == 1 && selected(sliced, 0).ordinal == 21);
    // Active child windows pin the complete metadata dependency set, not just
    // the child index. Churn must not evict the parent's canonical generation.
    tessera::CodexHistoryCache cache;
    refresh(cache.get("parent-prefix")); const auto parentGeneration = cache.get("parent-prefix").generation();
    refresh(cache.get("child"));
    cache.lineage("child", {"child", "parent-prefix"}); cache.beginRead(); cache.pin({"child"});
    for (size_t i = 0; i < 30; ++i) cache.get("unrelated-" + std::to_string(i));
    assert(cache.get("parent-prefix").generation() == parentGeneration);
    // Yielded summary indexes remain owned even after another read clears
    // transient pins. Explicit pressure must not reset their generations.
    tessera::CodexHistoryCache pendingCache;
    refresh(pendingCache.get("pending-summary"));
    const auto pendingGeneration = pendingCache.get("pending-summary").generation();
    pendingCache.hold("pending-summary");
    pendingCache.pending(pendingCache.readPaths()); pendingCache.beginRead();
    for (size_t i = 0; i < 30; ++i) pendingCache.get("summary-churn-" + std::to_string(i));
    assert(pendingCache.get("pending-summary").generation() == pendingGeneration);
    std::set<std::string> allPending;
    for (size_t i = 0; i < 24; ++i) {
        const auto key = "admitted-" + std::to_string(i);
        pendingCache.get(key); allPending.insert(key); pendingCache.pending(allPending);
    }
    // More pinned sources choose bounded reconstruction rather than permanent
    // refusal at an unrelated fixed cache-entry count.
    pendingCache.get("not-admitted");
    pendingCache.pending({}); pendingCache.get("released-admission");
    ::unlink(filename);
}
