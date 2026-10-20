#include "Normalize.h"
#include "Json.h"
#include "CodexShellDisplay.h"
#include "CodexReviewDisplay.h"
#include <cassert>
#include <cstring>
#include <iostream>

namespace {
std::string varint(size_t value) {
    std::string result;
    while (value >= 128) { result += static_cast<char>((value & 127) | 128); value >>= 7; }
    result += static_cast<char>(value);
    return result;
}
std::string field(size_t number, const std::string& data) {
    return varint(number * 8 + 2) + varint(data.size()) + data;
}
std::string base64(const std::string& bytes) {
    constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    for (size_t i = 0; i < bytes.size(); i += 3) {
        const auto a = static_cast<unsigned char>(bytes[i]);
        const auto b = i + 1 < bytes.size() ? static_cast<unsigned char>(bytes[i + 1]) : 0;
        const auto c = i + 2 < bytes.size() ? static_cast<unsigned char>(bytes[i + 2]) : 0;
        result += alphabet[a >> 2]; result += alphabet[((a & 3) << 4) | (b >> 4)];
        result += i + 1 < bytes.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : '=';
        result += i + 2 < bytes.size() ? alphabet[c & 63] : '=';
    }
    return result;
}
std::string kindSignature(const std::string& kind) { return base64(field(2, field(1, field(8, kind)))); }
}

int main(int argc, char** argv) {
    assert(tessera::json::displayText("safe\x1b[31m\xE2\x80\xAE" "evil\xC2\x85\t\n", 1024) == "safe[31mevil\t\n");
    assert(tessera::json::displayText("éé", 3) == "é");
    if (argc == 2) {
        simdjson::dom::parser input, output;
        const auto fixtures = input.load(argv[1]).value();
        for (const auto fixture : simdjson::dom::array(fixtures.get_array().value())) {
            const auto result = tessera::normalizeCodexItem(tessera::json::get(fixture, "item"), "synthetic-turn");
            assert(result.disposition != "unclassified");
            assert(result.json.find("synthetic-opaque-not-for-display") == std::string::npos);
            const auto body = output.parse(result.json).value();
            assert(tessera::json::integer(body, "unparsedContentCount") == 0);
            const auto actual = tessera::json::get(body, "blocks").get_array().value();
            const auto expected = tessera::json::get(fixture, "blocks").get_array().value();
            assert(actual.size() == expected.size());
            auto names = expected.begin();
            for (const auto block : actual) {
                assert(tessera::json::text(block, "type") == std::string_view((*names).get_string().value()));
                ++names;
            }
        }
    }
    simdjson::dom::parser parser;
    auto parsed = [&](const char* raw) { return parser.parse(raw, std::strlen(raw)).value(); };
    const auto narration = kindSignature("narration");
    auto normalizedThinking = [&](const std::string& signature, const std::string& prose = "Between calls", const std::string& provider = "claude") {
        const auto part = std::string(R"({"type":"thinking","thinking":)") +
            tessera::json::quote(prose, prose.size()) + R"(,"signature":)" + tessera::json::quote(signature, signature.size()) + "}";
        const auto source = provider == "codex" ? R"({"type":"response_item","payload":{"type":"message","role":"assistant","content":[)" + part + "]}}" :
            provider == "pi" ? R"({"type":"message","message":{"role":"assistant","content":[)" + part + "]}}" :
            R"({"type":"assistant","message":{"content":[)" + part + "]}}";
        return tessera::normalize(provider, parsed(source.c_str()), false).json;
    };
    auto firstBlock = [&](const std::string& raw) {
        return tessera::json::text(tessera::json::get(parsed(raw.c_str()), "blocks").at(0).value(), "type");
    };
    assert(firstBlock(normalizedThinking(narration)) == "text");
    std::string spaced;
    for (size_t i = 0; i < narration.size(); i += 4) spaced += " \n" + narration.substr(i, 4);
    assert(firstBlock(normalizedThinking(spaced)) == "text");
    auto unpadded = narration;
    while (!unpadded.empty() && unpadded.back() == '=') unpadded.pop_back();
    assert(firstBlock(normalizedThinking(unpadded)) == "text");
    assert(tessera::json::get(parsed(normalizedThinking(narration).c_str()), "blocks").get_array().value().size() == 1);
    assert(tessera::json::get(parsed(normalizedThinking(narration, "  \t\n ").c_str()), "blocks").get_array().value().size() == 0);
    // atob rejects a vertical tab but skips a form feed.
    assert(firstBlock(normalizedThinking(narration.substr(0, 4) + "\v" + narration.substr(4))) == "thinking");
    assert(firstBlock(normalizedThinking(narration.substr(0, 4) + "\f" + narration.substr(4))) == "text");
    // An oversized record clips strings at 16 KiB: never classify a
    // signature that long, even when its visible fields say narration.
    const auto filler = field(2, field(1, field(8, "narration") + field(9, std::string(12500, 'x'))));
    assert(base64(filler).size() >= 16384 && firstBlock(normalizedThinking(base64(filler))) == "thinking");
    assert(firstBlock(normalizedThinking(base64(field(2, field(1, field(8, "narration") + field(9, std::string(9000, 'x'))))))) == "text");
    // Blankness is Claude's trim of the source text, not of the bounded preview.
    assert(firstBlock(normalizedThinking(narration, std::string(20000, ' ') + "late")) == "text");
    {
        const auto source = std::string(R"({"type":"assistant","message":{"content":[{"type":"thinking","text":"Fallback text","signature":)") +
            tessera::json::quote(narration) + R"(}]}})";
        assert(firstBlock(tessera::normalize("claude", parsed(source.c_str()), false).json) == "thinking");
    }
    for (const auto& signature : {kindSignature("summary"), std::string("legacy"), std::string("garbage!"),
        base64(field(2, field(1, field(8, "narration")).substr(0, 5))),
        std::string(65537, 'A'), base64(field(2, field(1, field(8, "narration"))) + "\x80")}) {
        assert(firstBlock(normalizedThinking(signature)) == "thinking");
    }
    assert(firstBlock(normalizedThinking(base64(field(2, field(1, field(8, "summary"))) +
        field(2, field(1, field(8, "narration")))))) == "text");
    assert(firstBlock(normalizedThinking(base64(field(2, field(1, field(8, "narration"))) +
        field(2, field(1, field(8, "summary")))))) == "thinking");
    assert(firstBlock(normalizedThinking(narration, "Between calls", "pi")) == "thinking");
    assert(firstBlock(normalizedThinking(narration, "Between calls", "codex")) == "thinking");
    {
        std::string content;
        for (int i = 0; i < 70; ++i) {
            if (!content.empty()) content += ',';
            content += R"({"type":"tool_use","name":"Synthetic","input":")" + std::string(600, 'x') + R"("})";
        }
        const std::string prose(5000, 'n');
        const auto source = std::string(R"({"type":"assistant","message":{"content":[)") + content +
            R"(,{"type":"thinking","thinking":)" + tessera::json::quote(prose) +
            R"(,"signature":)" + tessera::json::quote(narration) + R"(}]}})";
        const auto result = tessera::normalize("claude", parsed(source.c_str()), false);
        const auto body = parsed(result.json.c_str());
        bool kept = false;
        for (const auto block : simdjson::dom::array(tessera::json::get(body, "blocks").get_array().value()))
            kept |= tessera::json::text(block, "type") == "text" && tessera::json::text(block, "text") == prose;
        assert(kept && tessera::json::boolean(body, "truncated"));
    }
    auto queued = [&](const std::string& attachment) {
        const auto source = std::string(R"({"type":"attachment","uuid":"queued","parentUuid":"previous","isSidechain":false,"timestamp":"synthetic-time","sessionId":"synthetic-session","attachment":)") + attachment + "}";
        return tessera::normalize("claude", parsed(source.c_str()), false);
    };
    const auto human = queued(R"({"type":"queued_command","commandMode":"prompt","origin":{"kind":"human"},"prompt":"Typed during turn"})");
    const auto humanBody = parsed(human.json.c_str());
    assert(human.disposition == "message" && human.visible);
    assert(tessera::json::text(humanBody, "type") == "message" && tessera::json::text(humanBody, "role") == "user");
    assert(tessera::json::text(tessera::json::get(humanBody, "blocks").at(0).value(), "text") == "Typed during turn");
    assert(!tessera::json::boolean(humanBody, "isMeta"));
    assert(tessera::json::text(humanBody, "timestamp") == "synthetic-time" && tessera::json::text(humanBody, "sessionID") == "synthetic-session");
    const auto array = queued(R"({"type":"queued_command","prompt":[{"type":"text","text":"Look here"},{"type":"image","source":{"type":"base64","data":"synthetic"}}]})");
    const auto arrayBlocks = tessera::json::get(parsed(array.json.c_str()), "blocks").get_array().value();
    assert(arrayBlocks.size() == 2);
    assert(tessera::json::text(arrayBlocks.at(0).value(), "type") == "text");
    assert(tessera::json::text(arrayBlocks.at(1).value(), "type") == "attachment");
    for (const auto& attachment : {
        R"({"type":"queued_command","commandMode":"prompt","origin":{"kind":"peer","name":"synthetic-peer"},"prompt":"Peer"})",
        R"({"type":"queued_command","commandMode":"task-notification","origin":{"kind":"human"},"prompt":"Notification"})",
        R"({"type":"queued_command","commandMode":"prompt","origin":{"kind":"task-notification"},"prompt":"Notification"})",
        R"({"type":"queued_command","commandMode":"prompt","origin":{"kind":"unclassified"},"forwardedIntent":true,"prompt":"Forwarded"})",
        R"({"type":"queued_command","commandMode":"prompt","origin":{"kind":"human"},"isMeta":true,"prompt":"Meta"})"
    }) {
        const auto context = queued(attachment);
        assert(context.disposition == "system" && tessera::json::text(parsed(context.json.c_str()), "text") == "Provider context: queued_command");
        assert(context.chainEntry == human.chainEntry && context.chainMessage == human.chainMessage &&
            context.chainMain == human.chainMain && context.chainID == human.chainID &&
            context.chainParentID == human.chainParentID && context.chainSidechain == human.chainSidechain);
    }
    const auto defaults = queued(R"({"type":"queued_command","prompt":"No mode or origin"})");
    assert(tessera::json::text(parsed(defaults.json.c_str()), "role") == "user");
    const auto toolPrompt = queued(R"({"type":"queued_command","prompt":[{"type":"tool_result","content":"Synthetic tool output"}]})");
    assert(tessera::json::text(parsed(toolPrompt.json.c_str()), "role") == "tool");
    assert(defaults.chainEntry && !defaults.chainMessage && !defaults.chainMain && defaults.chainID == "queued" && defaults.chainParentID == "previous");
    const auto legacyUser = tessera::normalize("codex", parsed(R"({"type":"event_msg","timestamp":"synthetic-time","payload":{"type":"user_message","message":"hello","images":["data:image/png;base64,AA"],"local_images":["/synthetic/image"],"audio":["data:audio/wav;base64,AA"],"local_audio":["/synthetic/audio"]}})"), false);
    const auto legacyUserBody = parsed(legacyUser.json.c_str());
    assert(legacyUser.disposition == "message" && tessera::json::text(legacyUserBody, "role") == "user");
    assert(tessera::json::integer(legacyUserBody, "unparsedContentCount") == 0);
    assert(tessera::json::get(legacyUserBody, "blocks").get_array().value().size() == 5);
    assert(tessera::json::text(legacyUserBody, "timestamp") == "synthetic-time");
    const auto emptyLegacy = tessera::normalize("codex", parsed(R"({"type":"event_msg","payload":{"type":"agent_message","message":""}})"), false);
    assert(emptyLegacy.disposition == "metadata" && !emptyLegacy.visible);
    for (const auto invalid : {
        R"({"type":"event_msg","payload":{"type":"user_message","message":42}})",
        R"({"type":"event_msg","payload":{"type":"user_message","message":"valid","images":[42]}})",
        R"({"type":"event_msg","payload":{"type":"user_message","message":"valid","local_images":null}})",
        R"({"type":"event_msg","payload":{"type":"agent_message","message":"","new_content":"must not disappear"}})",
        R"({"type":"event_msg","payload":{"type":"agent_message","message":"valid","phase":"future"}})"
    }) {
        const auto value = tessera::normalize("codex", parsed(invalid), false);
        assert(tessera::json::integer(parsed(value.json.c_str()), "unparsedContentCount") > 0);
    }
    const auto ordered = tessera::normalizeCodexItem(parsed(R"({"type":"mcpToolCall","id":"synthetic","tool":"fixture","arguments":{"z":[{"b":2,"a":1}],"a":true}})"), "turn").json;
    const auto reordered = tessera::normalizeCodexItem(parsed(R"({"type":"mcpToolCall","id":"synthetic","tool":"fixture","arguments":{"a":true,"z":[{"a":1,"b":2}]}})"), "turn").json;
    assert(ordered == reordered);
    const std::string largeArgument(20000, 'x');
    const auto arguments = std::string(R"({"type":"mcpToolCall","id":"synthetic","tool":"fixture","arguments":{"z":0,"a":")") + largeArgument + R"("}})";
    const auto clipped = tessera::normalizeCodexItem(parsed(arguments.c_str()), "turn").json;
    assert(tessera::json::boolean(parsed(clipped.c_str()), "truncated"));
    assert(tessera::codexQuoteArgument("") == "''");
    assert(tessera::codexQuoteArgument("x=y") == "'x=y'");
    assert(tessera::codexQuoteArgument("a,b") == "'a,b'");
    assert(tessera::codexQuoteArgument("]") == "]");
    assert(tessera::codexQuoteArgument("a'b") == "\"a'b\"");
    assert(tessera::codexQuoteArgument("a^b") == "a'^b'");
    assert(tessera::codexQuoteArgument("\\") == "\"\\\\\"");
    assert(tessera::codexQuoteArgument("é") == "'é'");
    assert(tessera::codexReviewTrim("\xc2\xa0\xe2\x80\x89 text \xe3\x80\x80") == "text");
    assert(tessera::codexReviewTrim("\xe2\x80\x8btext\xe2\x80\x8b") == "\xe2\x80\x8btext\xe2\x80\x8b");
    const auto review = tessera::codexReviewDisplay(parsed(R"({"findings":[{"title":"Fix","body":"one\r\ntwo\n","confidence_score":0.8,"priority":1,"code_location":{"absolute_file_path":"/fixture/a","line_range":{"start":2,"end":3}}}],"overall_correctness":"incorrect","overall_explanation":"  Summary  ","overall_confidence_score":0.8})"));
    assert(review && *review == "Summary\n\nReview comment:\n\n- Fix — /fixture/a:2-3\n  one\n  two");
    assert(!tessera::codexReviewDisplay(parsed(R"({"findings":[],"overall_correctness":"correct","overall_explanation":"text","overall_confidence_score":true})")));
    const auto completedEnvelope = tessera::normalize("codex", parsed(R"({"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn","item":{"type":"AgentMessage","id":"fixture","content":[{"type":"Text","text":"canonical"}]}}})"), false);
    assert(completedEnvelope.disposition == "message");
    assert(completedEnvelope.sourceType == "event_msg/item_completed");
    assert(completedEnvelope.json == tessera::normalizeCodexCoreItem(parsed(R"({"type":"AgentMessage","id":"fixture","content":[{"type":"Text","text":"canonical"}]})"), "turn").json);
    for (const auto& unit : {std::string("x"), std::string("é"), std::string("\"\n\\")}) {
        std::string objective;
        while (objective.size() < 10000) objective += unit;
        const auto source = std::string(R"({"type":"event_msg","payload":{"type":"thread_goal_updated","threadId":"thread","goal":{"threadId":"thread","objective":)") +
            tessera::json::quote(objective, objective.size()) + R"(,"status":"active","tokensUsed":0,"timeUsedSeconds":0,"createdAt":0,"updatedAt":0}}})";
        const auto normalized = tessera::normalize("codex", parsed(source.c_str()), false);
        const auto output = parsed(normalized.json.c_str());
        assert(tessera::json::boolean(output, "truncated"));
        const auto display = "Goal active: " + objective;
        const auto retained = tessera::json::text(output, "text");
        assert(retained.size() <= 8192 && retained.size() >= 8189);
        assert(display.compare(0, retained.size(), retained) == 0);
    }
    for (const auto raw : {
        R"({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn","model_context_window":null}})",
        R"({"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn","reason":"interrupted"}})",
        R"({"type":"world_state","payload":{"full":true,"state":{"type":"opaque-not-a-message","private":"must not flatten"}}})",
        R"({"type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}})",
        R"({"type":"event_msg","payload":{"type":"thread_goal_updated","threadId":"thread","goal":{"threadId":"thread","objective":"fixture","status":"active","tokensUsed":0,"timeUsedSeconds":0,"createdAt":0,"updatedAt":0}}})",
        // codex-cli 0.156 resume rows carry two arrays the pinned protocol lacks; they stay metadata.
        R"({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"thread","thread_settings":{"model":"m","cwd":"/private-root","model_provider_id":"openai","approval_policy":"on-request","approvals_reviewer":"user","permission_profile":{},"collaboration_mode":{},"runtime_workspace_roots":["/private-root must not flatten"],"disabled_plugin_ids":[]}}})",
        R"({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"thread","thread_settings":{"model":"m","cwd":"/x","model_provider_id":"openai","approval_policy":"on-request","approvals_reviewer":"user","permission_profile":{},"collaboration_mode":{},"runtime_workspace_roots":null,"disabled_plugin_ids":null}}})"
    }) {
        const auto value = tessera::normalize("codex", parsed(raw), false);
        assert(value.disposition != "unclassified");
        assert(value.json.find("must not flatten") == std::string::npos);
    }
    for (const auto raw : {
        R"({"type":"event_msg","payload":{"type":"task_started","turn_id":42}})",
        R"({"type":"task_started","payload":{"type":"task_started","turn_id":"turn"}})",
        R"({"type":"event_msg","payload":{"type":"turn_aborted","reason":"future_reason"}})",
        R"({"type":"world_state","payload":{"full":true,"state":{},"future":{}}})",
        R"({"type":"inter_agent_communication_metadata","payload":{"trigger_turn":true,"trigger_turn":false}})",
        R"({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":42}}})",
        R"({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"thread","thread_settings":{"model":"m","cwd":"/x","model_provider_id":"openai","approval_policy":"on-request","approvals_reviewer":"user","permission_profile":{},"collaboration_mode":{},"runtime_workspace_roots":"/x"}}})",
        R"({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"thread","thread_settings":{"model":"m","cwd":"/x","model_provider_id":"openai","approval_policy":"on-request","approvals_reviewer":"user","permission_profile":{},"collaboration_mode":{},"future_setting":[]}}})",
        R"({"type":"event_msg","payload":{"type":"item_completed","thread_id":42,"turn_id":"turn","item":{"type":"AgentMessage","id":"fixture","content":[]}}})",
        R"({"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn","completed_at_ms":null,"item":{"type":"AgentMessage","id":"fixture","content":[]}}})",
        R"({"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn","started_at_ms":"bad","item":{"type":"AgentMessage","id":"fixture","content":[]}}})",
        R"({"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn","item":{"type":"FutureItem","id":"fixture"}}})"
    }) assert(tessera::normalize("codex", parsed(raw), false).disposition == "unclassified");
    for (const auto& pair : std::initializer_list<std::pair<const char*, const char*>>{
        {R"({"type":"UserMessage","id":"fixture","content":[{"type":"text","text":"hello"},{"type":"local_image","path":"/fixture.png"}]})",
         R"({"type":"userMessage","id":"fixture","content":[{"type":"text","text":"hello"},{"type":"localImage","path":"/fixture.png"}]})"},
        {R"({"type":"AgentMessage","id":"fixture","content":[{"type":"Text","text":"one"},{"type":"Text","text":"two"}]})",
         R"({"type":"agentMessage","id":"fixture","text":"onetwo"})"},
        {R"({"type":"Reasoning","id":"fixture","summary_text":["summary"],"raw_content":["detail"]})",
         R"({"type":"reasoning","id":"fixture","summary":["summary"],"content":["detail"]})"},
        {R"({"type":"CommandExecution","id":"fixture","command":["echo","hello world","a'b"],"aggregated_output":"output","status":"completed"})",
         R"({"type":"commandExecution","id":"fixture","command":"echo 'hello world' \"a'b\"","aggregatedOutput":"output","status":"completed"})"},
        {R"({"type":"FileChange","id":"fixture","changes":{"z":{"type":"add","content":"new"},"a":{"type":"update","unified_diff":"diff","move_path":"b"}}})",
         R"({"type":"fileChange","id":"fixture","changes":[{"path":"a","diff":"diff\n\nMoved to: b"},{"path":"z","diff":"new"}]})"},
        {R"({"type":"McpToolCall","id":"fixture","tool":"tool","arguments":{"type":"arbitrary"},"result":{"content":[{"type":"text","text":"done"}]},"status":"completed"})",
         R"({"type":"mcpToolCall","id":"fixture","tool":"tool","arguments":{"type":"arbitrary"},"result":{"content":[{"type":"text","text":"done"}]},"status":"completed"})"},
        {R"({"type":"CollabAgentToolCall","id":"fixture","tool":"send_input","prompt":"hello","agents_states":{},"status":"in_progress"})",
         R"({"type":"collabAgentToolCall","id":"fixture","tool":"sendInput","prompt":"hello","agentsStates":{},"status":"inProgress"})"},
        {R"({"type":"SubAgentActivity","id":"fixture","agent_path":"/root/child","kind":"started"})",
         R"({"type":"subAgentActivity","id":"fixture","agentPath":"/root/child","kind":"started"})"},
        {R"({"type":"ContextCompaction","id":"fixture"})", R"({"type":"contextCompaction","id":"fixture"})"},
        {R"({"type":"ExitedReviewMode","id":"fixture","review_output":null})",
         R"({"type":"exitedReviewMode","id":"fixture","review":"Reviewer failed to output a response."})"},
        {R"({"type":"ExitedReviewMode","id":"fixture","review_output":{"findings":[],"overall_correctness":"correct","overall_explanation":"  Done  ","overall_confidence_score":1}})",
         R"({"type":"exitedReviewMode","id":"fixture","review":"Done"})"},
        {R"({"type":"ImageView","id":"fixture","path":"file:///fixture/a%20b%252F.png"})",
         R"({"type":"imageView","id":"fixture","path":"/fixture/a b%2F.png"})"},
        {R"({"type":"ImageView","id":"fixture","path":"file:///C:/fixture/a%20b.png"})",
         R"({"type":"imageView","id":"fixture","path":"C:\\fixture\\a b.png"})"},
        {R"({"type":"ImageView","id":"fixture","path":"file://server/share/a.png"})",
         R"({"type":"imageView","id":"fixture","path":"\\\\server\\share\\a.png"})"},
        {R"({"type":"ImageView","id":"fixture","path":"file:///%00/bad/path/YQ"})",
         R"({"type":"imageView","id":"fixture","path":"file:///%00/bad/path/YQ"})"},
        {R"({"type":"Extension","kind":"clock.sleep","id":"fixture","durationMs":1000,"status":"completed"})",
         R"({"type":"sleep","id":"fixture","durationMs":1000,"status":"completed"})"},
        {R"({"type":"Extension","kind":"web.search","id":"fixture","query":"fixture","results":[]})",
         R"({"type":"webSearch","id":"fixture","query":"fixture","results":[]})"},
        {R"({"type":"DynamicToolCall","id":"fixture","tool":"fixture","arguments":{},"content_items":[{"type":"input_text","text":"done"}]})",
         R"({"type":"dynamicToolCall","id":"fixture","tool":"fixture","arguments":{},"contentItems":[{"type":"input_text","text":"done"}]})"}
    }) {
        const auto core = tessera::normalizeCodexCoreItem(parsed(pair.first), "turn");
        const auto native = tessera::normalizeCodexItem(parsed(pair.second), "turn");
        assert(core.disposition != "unclassified");
        assert(core.json == native.json);
    }
    for (const auto raw : {
        R"({"type":"UserMessage","id":"fixture","content":[{"text":"must not flatten"}]})",
        R"({"type":"UserMessage","id":"fixture","content":[{"type":42,"text":"must not flatten"}]})",
        R"({"type":"DynamicToolCall","id":"fixture","tool":"mock","content_items":"must not flatten"})",
        R"({"type":"DynamicToolCall","id":"fixture","tool":"mock","error":{"type":"future","text":"must not flatten"}})",
        R"({"type":"AgentMessage","id":"fixture","content":[{"type":"FutureText","text":"must not flatten"}]})",
        R"({"type":"CommandExecution","id":"fixture","command":[42]})",
        R"({"type":"FileChange","id":"fixture","changes":{"a":{"type":"future","content":"must not flatten"}}})",
        R"({"type":"Extension","kind":"future.item","id":"fixture"})",
        R"({"type":"Reasoning","id":"fixture","summary_text":[42]})"
        ,R"({"type":"CommandExecution","id":"fixture","command":[],"aggregated_output":42})"
        ,R"({"type":"McpToolCall","id":"fixture","result":42})"
        ,R"({"type":"Extension","kind":"clock.sleep","id":"fixture","durationMs":"invalid"})"
        ,R"({"type":"HookPrompt","id":"fixture","fragments":[{"type":"futureFragment","text":"must not flatten"}]})"
        ,R"({"type":"AgentMessage","id":"fixture","content":[{"type":"Text","text":"must not flatten"}],"type":"FutureItem"})"
    }) {
        const auto value = tessera::normalizeCodexCoreItem(parsed(raw), "turn");
        assert(value.disposition == "unclassified");
        assert(value.json.find("must not flatten") == std::string::npos);
    }
    const auto future = tessera::normalizeCodexItem(parsed(R"({"type":"futureItem","id":"synthetic"})"), "turn", false);
    assert(future.disposition == "unclassified");
    assert(future.json.find("Unsupported Codex item:") == std::string::npos);
    auto output = parsed(future.json.c_str());
    assert(tessera::json::integer(output, "unparsedContentCount") == 1);
    assert(tessera::json::text(tessera::json::get(output, "blocks").at(0).value(), "type") == "unknown");
    for (const auto raw : {
        R"({"type":"userMessage","id":"synthetic","content":[{"text":"must not flatten"}]})",
        R"({"type":"commandExecution","id":"synthetic","command":"fixture","status":"future_status"})",
        R"({"type":"collabAgentToolCall","id":"synthetic","tool":"future_tool","agentsStates":42})",
        R"({"type":"mcpToolCall","id":"synthetic","tool":"mock","result":{"content":[{"type":"resource","resource":42}]}})",
        R"({"type":"mcpToolCall","id":"synthetic","tool":"mock","result":{"content":[{"type":"image"}]}})",
        R"({"type":"dynamicToolCall","id":"synthetic","tool":"mock","contentItems":"must not flatten"})",
        R"({"type":"agentMessage","id":"synthetic","text":42})",
        R"({"type":"plan","id":"synthetic"})",
        R"({"type":"userMessage","id":"synthetic","content":null})",
        R"({"type":"userMessage","id":"synthetic","content":[{"type":"image","url":null}]})",
        R"({"type":"functionCallOutput","id":"synthetic","output":null})",
        R"({"type":"functionCallOutput","id":"synthetic","output":[{"type":"input_image","image_url":42}]})",
        R"({"type":"fileChange","id":"synthetic","changes":42})",
        R"({"type":"commandExecution","id":"synthetic","command":42})",
        R"({"type":"commandExecution","id":"synthetic","command":"fixture","aggregatedOutput":42})",
        R"({"type":"mcpToolCall","id":"synthetic","result":42})",
        R"({"type":"sleep","id":"synthetic","durationMs":"invalid"})",
        R"({"type":"hookPrompt","id":"synthetic","fragments":[{"type":"futureFragment","text":"must not flatten"}]})",
        R"({"type":"functionCallOutput","id":"synthetic","output":{"type":"future_tool_content","text":"must not flatten"}})",
        R"({"type":"functionCallOutput","id":"synthetic","output":42})",
        R"({"type":"functionCallOutput","id":"synthetic","output":[{"type":"text","text":42}]})",
        R"({"type":"mcpToolCall","id":"synthetic","tool":"mock","result":{"content":[{"type":"text","text":42}]}})",
        R"({"type":"dynamicToolCall","id":"synthetic","tool":"mock","contentItems":[{"type":"future_content","text":"must not flatten"}]})"
    }) {
        const auto result = tessera::normalizeCodexItem(parsed(raw), "turn", false);
        assert(tessera::json::integer(parsed(result.json.c_str()), "unparsedContentCount") > 0);
        assert(result.json.find("must not flatten") == std::string::npos);
    }
    const auto encrypted = tessera::normalizeCodexItem(parsed(R"({"type":"functionCallOutput","id":"synthetic","output":[{"type":"encrypted_content","encrypted_content":"opaque-private-data"}]})"), "turn", false);
    assert(tessera::json::integer(parsed(encrypted.json.c_str()), "unparsedContentCount") == 0);
    assert(encrypted.json.find("opaque-private-data") == std::string::npos);
    assert(encrypted.json.find("Encrypted content") != std::string::npos);
    // Claude usage stays on its authored message; no guessed context window.
    auto claudeUsage = [&](const std::string& usage, const std::string& flags = "") {
        const auto raw = R"({"type":"assistant","uuid":"usage-main",)" + flags +
            R"("message":{"role":"assistant","content":"hello","usage":)" + usage + "}}";
        return tessera::normalize("claude", parsed(raw.c_str()), false);
    };
    for (const auto& sample : std::vector<std::pair<std::string, int64_t>>{
        {R"({"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":40})", 640},
        {R"({"input_tokens":100,"output_tokens":40})", 140},
        {R"({"cache_read_input_tokens":84})", 84},
        {R"({"input_tokens":9007199254740991})", 9007199254740991LL}}) {
        const auto result = claudeUsage(sample.first);
        const auto record = parsed(result.json.c_str());
        assert(tessera::json::integer(record, "used_tokens") == sample.second);
        assert(tessera::json::get(record, "max_tokens").is_null());
        assert(tessera::json::text(record, "type") == "message");
        assert(result.visible && result.disposition == "message" && result.chainMain);
    }
    for (const auto& flags : {R"("isSidechain":true,)", R"("isMeta":true,)",
        R"("teamName":"team",)", R"("isSubagent":true,)"}) {
        const auto result = claudeUsage(R"({"input_tokens":123})", flags);
        assert(tessera::json::get(parsed(result.json.c_str()), "used_tokens").is_null());
    }
    // Zero usage (API errors, interrupts) must not erase the last occupancy.
    for (const auto& usage : {"{}", R"({"input_tokens":0,"output_tokens":0})"}) {
        assert(tessera::json::get(parsed(claudeUsage(usage).json.c_str()), "used_tokens").is_null());
    }
    const auto synthetic = tessera::normalize("claude", parsed(R"({"type":"assistant","uuid":"usage-synthetic","message":{"role":"assistant","model":"<synthetic>","content":"hello","usage":{"input_tokens":5}}})"), false);
    assert(tessera::json::get(parsed(synthetic.json.c_str()), "used_tokens").is_null());
    for (const auto& usage : {R"("invalid")", "null", "[]", R"({"input_tokens":"123"})",
        R"({"input_tokens":-1})", R"({"input_tokens":1.5})", R"({"input_tokens":true})",
        R"({"input_tokens":null})", R"({"input_tokens":100,"cache_read_input_tokens":-1})",
        R"({"input_tokens":9007199254740992})", R"({"input_tokens":9007199254740991,"output_tokens":1})",
        R"({"input_tokens":18446744073709551615})"}) {
        const auto result = claudeUsage(usage);
        assert(tessera::json::get(parsed(result.json.c_str()), "used_tokens").is_null());
        assert(result.visible && result.disposition == "message");
    }
    const auto absentMaximum = tessera::normalize("codex", parsed(R"({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":42}}}})"), false);
    assert(tessera::json::get(parsed(absentMaximum.json.c_str()), "max_tokens").is_null());
    for (const auto raw : {
        R"({"type":"assistant","message":{"content":null}})",
        R"({"type":"user","message":{"role":42,"content":"synthetic"}})",
        R"({"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":42}]}]}})",
        R"({"type":"user","message":{"content":[{"type":"tool_result","content":42}]}})",
        R"({"type":"assistant","message":{"content":[{"type":"thinking"}]}})",
        R"({"type":"assistant","message":{"content":[{"type":"advisor_tool_result","content":{"type":"advisor_result","text":42}}]}})"
    }) {
        const auto result = tessera::normalize("claude", parsed(raw), false);
        assert(tessera::json::integer(parsed(result.json.c_str()), "unparsedContentCount") > 0);
    }
    std::cout << "Unknown items and malformed known blocks remain diagnostic\n";
}
