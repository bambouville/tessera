#include "Normalize.h"
#include "Json.h"
#include <algorithm>
#include <map>
#include <set>

namespace tessera {
namespace {
using Element = simdjson::dom::element;
bool unique(Element value) {
    if (!value.is_object()) return false;
    std::set<std::string_view> fields;
    for (const auto field : simdjson::dom::object(value.get_object().value())) if (!fields.insert(field.key).second) return false;
    return true;
}
bool stringField(Element value, const char* key, bool nonempty = false) {
    return json::get(value, key).is_string() && (!nonempty || !json::text(value, key).empty());
}
bool counter(Element value, const char* key) {
    uint64_t count = 0; return !json::get(value, key).get_uint64().get(count) && count <= (uint64_t(1) << 53) - 1;
}
bool optionalBool(Element value, const char* key) { return json::get(value, key).is_null() || json::get(value, key).is_bool(); }
bool hasField(Element value, const char* key) { return value.is_object() && !value.at_key(key).error(); }
bool validOrigin(Element value) {
    if (value.is_null()) return true;
    if (!unique(value)) return false;
    const auto kind = json::text(value, "kind");
    if (kind == "user" || kind == "compaction_summary" || kind == "retry") return true;
    if (kind == "skill_activation") return stringField(value, "activationId", true) && stringField(value, "skillName", true) &&
        (json::text(value, "trigger") == "user-slash" || json::text(value, "trigger") == "model-tool" || json::text(value, "trigger") == "nested-skill");
    if (kind == "plugin_command") return stringField(value, "activationId", true) && stringField(value, "pluginId", true) &&
        stringField(value, "commandName", true) && json::text(value, "trigger") == "user-slash";
    if (kind == "injection") return stringField(value, "variant", true);
    if (kind == "shell_command") return (json::text(value, "phase") == "input" || json::text(value, "phase") == "output") && optionalBool(value, "isError");
    if (kind == "system_trigger") return stringField(value, "name", true);
    // Historical 1.4 transcripts use background_task; the official display
    // replay still explicitly supports that origin alongside current task.
    if (kind == "task" || kind == "background_task") return stringField(value, "taskId", true) && stringField(value, "status", true) && stringField(value, "notificationId", true);
    if (kind == "cron_job") return stringField(value, "jobId", true) && stringField(value, "cron", true) &&
        json::get(value, "recurring").is_bool() && json::get(value, "stale").is_bool() && counter(value, "coalescedCount");
    if (kind == "cron_missed") return counter(value, "count");
    if (kind == "hook_result") return stringField(value, "event", true) && optionalBool(value, "blocked");
    return false;
}
std::string part(Element value, bool& malformed) {
    const auto type = json::text(value, "type"); json::Object result;
    if (!unique(value)) malformed = true;
    if (type == "text" || type == "think") {
        const auto field = type == "text" ? "text" : "think";
        if (!stringField(value, field)) malformed = true;
        if (type == "think" && !json::get(value, "encrypted").is_null() && !stringField(value, "encrypted")) malformed = true;
        if (type == "think" && json::text(value, "think").empty() && stringField(value, "encrypted")) {
            result.string("type", "encrypted_content"); return result.finish();
        }
        result.string("type", type == "text" ? "text" : "thinking");
        result.raw(type == "text" ? "text" : "thinking", simdjson::minify(json::get(value, field)));
    } else if (type == "image_url" || type == "audio_url" || type == "video_url") {
        const auto field = type == "image_url" ? "imageUrl" : type == "audio_url" ? "audioUrl" : "videoUrl";
        if (!stringField(json::get(value, field), "url", true)) malformed = true;
        result.string("type", "attachment"); result.string("name", type == "image_url" ? "Image" : type == "audio_url" ? "Audio" : "Video");
        result.string("mime_type", type.substr(0, type.find('_')));
        // Blob IDs, file paths and URLs never become read authority.
    } else { result.string("type", "unrecognized-kimi-part/" + type, 128); }
    return result.finish();
}
std::vector<std::string> parts(Element value, bool& malformed) {
    std::vector<std::string> result;
    if (value.is_string()) { json::Object text; text.string("type", "text"); text.raw("text", simdjson::minify(value)); result.push_back(text.finish()); }
    else if (value.is_array()) for (const auto item : simdjson::dom::array(value.get_array().value())) result.push_back(part(item, malformed));
    else malformed = true;
    return result;
}
}

NormalizedRecord normalizeKimi(Element source, bool cut, const std::string& fallbackID) {
    const auto type = json::text(source, "type");
    NormalizedRecord result; result.sourceType = type; result.providerID = fallbackID;
    json::Object output; output.string("provider", "kimi");
    bool malformed = !unique(source), known = true, converted = false;
    auto emit = [&](const std::string& role, const std::vector<std::string>& content, bool compact = false) {
        json::Object message, envelope;
        message.string("role", role); message.raw("content", json::array(content));
        envelope.string("type", role == "user" ? "user" : "assistant"); envelope.raw("message", message.finish());
        if (compact) envelope.boolean("isCompactSummary", true);
        simdjson::dom::parser parser;
        result = normalize("claude", parser.parse(envelope.finish()).value(), cut, fallbackID);
        const auto canonical = parser.parse(result.json).value();
        for (const auto field : simdjson::dom::object(canonical.get_object().value())) if (field.key != "provider") output.raw(field.key, simdjson::minify(field.value));
        result.sourceType = type; result.providerID = fallbackID; converted = true;
    };
    auto prose = [&](const std::string& text, const std::string& role = "system") {
        json::Object block; block.string("type", "text"); block.string("text", text, 16384); emit(role, {block.finish()});
        if (role == "system") { output.boolean("providerSystemMessage", true); result.visible = true; }
    };
    auto metadata = [&] { output.string("type", "metadata"); result.disposition = "metadata"; };
    auto toolCall = [&](Element call, bool recorded) {
        const auto id = json::text(call, recorded ? "toolCallId" : "id");
        if (!unique(call) || id.empty() || id.size() > 256 || !stringField(call, "name", true)) malformed = true;
        if (!recorded && (json::text(call, "type") != "function" ||
            (!json::get(call, "arguments").is_null() && !json::get(call, "arguments").is_string()))) malformed = true;
        json::Object block; block.string("type", "function_call"); block.string("call_id", id, 256); block.string("name", json::text(call, "name"), 256);
        block.raw("arguments", simdjson::minify(json::get(call, recorded ? "args" : "arguments"))); return block.finish();
    };
    if (type == "metadata") {
        const auto version = json::text(source, "protocol_version");
        if (version != "1.4" && version != "1.5") malformed = true;
        metadata(); output.string("protocolVersion", version, 16);
    } else if (type == "context.append_message") {
        const auto message = json::get(source, "message"); const auto role = json::text(message, "role");
        if (!unique(message) || (role != "user" && role != "assistant" && role != "tool" && role != "system")) malformed = true;
        const auto origin = json::get(message, "origin"); const auto kind = json::text(origin, "kind");
        if (!validOrigin(origin) || !optionalBool(message, "isError")) malformed = true;
        const auto activations = json::get(origin, "skillActivations");
        size_t bundled = 0; std::vector<std::string> content;
        if (!activations.is_null()) {
            if (kind != "user" || !activations.is_array()) malformed = true;
            else for (const auto activation : simdjson::dom::array(activations.get_array().value())) {
                if (!unique(activation) || !stringField(activation, "activationId", true) || !stringField(activation, "skillName", true)) malformed = true;
                ++bundled;
            }
        }
        const auto body = json::get(message, "content");
        if (!body.is_array()) malformed = true;
        else {
            size_t at = 0;
            for (const auto item : simdjson::dom::array(body.get_array().value())) {
                if (json::text(item, "type") == "text" && at < bundled) {
                    ++at;
                    if (!stringField(item, "text")) malformed = true;
                    json::Object marker; marker.string("type", "tessera-provider-note"); marker.raw("text", simdjson::minify(json::get(item, "text")));
                    content.push_back(marker.finish());
                } else content.push_back(part(item, malformed));
            }
            if (at < bundled) malformed = true;
        }
        const auto attachments = json::get(origin, "attachments");
        if (!attachments.is_null()) {
            if ((kind != "user" && kind != "skill_activation") || !attachments.is_array()) malformed = true;
            else for (const auto attachment : simdjson::dom::array(attachments.get_array().value())) {
                if (!unique(attachment) || !stringField(attachment, "name") || !stringField(attachment, "mediaType") ||
                    !stringField(attachment, "path") || !counter(attachment, "size")) malformed = true;
                json::Object block; block.string("type", "attachment"); block.string("name", json::text(attachment, "name"), 256);
                block.string("mime_type", json::text(attachment, "mediaType"), 128); content.push_back(block.finish());
            }
        }
        const auto calls = json::get(message, "toolCalls");
        if (!calls.is_null() && !calls.is_array()) malformed = true;
        else if (calls.is_array()) for (const auto call : simdjson::dom::array(calls.get_array().value())) content.push_back(toolCall(call, false));
        const bool compact = kind == "compaction_summary";
        const bool hidden = role == "system" || kind == "injection" || kind == "retry" ||
            (kind == "system_trigger" && json::text(origin, "name") != "goal_continuation" && json::text(origin, "name") != "subagent");
        const bool marker = (kind == "skill_activation" || kind == "plugin_command") && json::text(origin, "trigger") != "user-slash";
        if (role == "tool") {
            if (!stringField(message, "toolCallId", true)) malformed = true;
            json::Object block; block.string("type", "tool_result"); block.string("tool_use_id", json::text(message, "toolCallId"), 256);
            block.raw("content", json::array(content)); block.boolean("is_error", json::boolean(message, "isError")); emit("tool", {block.finish()});
        } else emit(hidden || compact || marker ? "system" : role, content, compact);
        if (marker) { output.boolean("providerSystemMessage", true); result.visible = true; }
        if (hidden && !malformed) {
            simdjson::dom::parser parser; const auto canonical = parser.parse(result.json).value();
            if (json::integer(canonical, "unparsedContentCount") == 0) {
                output = json::Object{}; output.string("provider", "kimi"); metadata(); result.visible = false; converted = false;
            }
        }
    } else if (type == "context.append_loop_event") {
        const auto event = json::get(source, "event"); const auto kind = json::text(event, "type"); result.sourceType = type + "/" + kind;
        if (!unique(event)) malformed = true;
        if (kind == "content.part") {
            if (!stringField(event, "stepUuid", true)) malformed = true;
            emit("assistant", {part(json::get(event, "part"), malformed)});
        } else if (kind == "tool.call") {
            if (!stringField(event, "stepUuid", true)) malformed = true;
            emit("tool", {toolCall(event, true)});
        } else if (kind == "tool.result") {
            const auto value = json::get(event, "result");
            if (!unique(value) || !stringField(event, "toolCallId", true) || !optionalBool(value, "isError") ||
                (!json::get(value, "note").is_null() && !stringField(value, "note"))) malformed = true;
            json::Object block; block.string("type", "tool_result"); block.string("tool_use_id", json::text(event, "toolCallId"), 256);
            block.raw("content", json::array(parts(json::get(value, "output"), malformed))); block.boolean("is_error", json::boolean(value, "isError"));
            auto content = std::vector<std::string>{block.finish()};
            if (!json::get(value, "note").is_null()) { json::Object note; note.string("type", "text"); note.raw("text", simdjson::minify(json::get(value, "note"))); content.push_back(note.finish()); }
            emit("tool", content);
        } else if (kind == "step.begin" || kind == "step.end") {
            if (!stringField(event, "uuid", true)) malformed = true;
            metadata(); // usage.record is authoritative; do not double-count step.end.
        } else known = false;
        result.sourceType = type + "/" + kind;
    } else if (type == "context.apply_compaction") {
        auto summary = json::get(source, "summary"); if (summary.is_null()) summary = json::get(source, "contextSummary");
        if (summary.is_object()) summary = json::get(summary, "content");
        emit("system", parts(summary, malformed), true);
    } else if (type == "context.undo") {
        if (!counter(source, "count") || json::integer(source, "count") <= 0) malformed = true;
        metadata();
    } else if (type == "usage.record") {
        const auto usage = json::get(source, "usage"); uint64_t tokens = 0;
        for (const auto* key : {"inputOther", "inputCacheRead", "inputCacheCreation", "output"}) {
            if (!counter(usage, key)) malformed = true;
            else tokens += static_cast<uint64_t>(json::integer(usage, key));
        }
        if (tokens > (uint64_t(1) << 53) - 1) malformed = true;
        output.string("type", "cost-state"); output.number("used_tokens", tokens); output.optional("model", json::text(source, "model"), 256); result.disposition = "metadata";
    } else if (type == "config.update" || type == "profile.bind") {
        metadata(); output.optional("model", json::text(source, "modelAlias"), 256);
        if (!json::get(source, "modelAlias").is_null() && !stringField(source, "modelAlias")) malformed = true;
    } else if (type == "permission.set_mode") {
        const auto mode = json::text(source, "mode"); if (mode != "manual" && mode != "yolo" && mode != "auto") malformed = true;
        output.string("type", "permission-mode"); output.string("mode", mode, 64); result.disposition = "metadata";
    } else if (type == "turn.ended" || type == "turn.cancel" || type == "turn.step.interrupted" || type == "turn.step.retrying") {
        const auto error = json::get(source, "error");
        const auto body = type == "turn.step.retrying" ? json::text(source, "errorMessage") : !error.is_null() ? json::text(error, "message") : json::text(source, "message");
        if (!body.empty()) prose(body);
        else { output.string("type", "completion"); output.string("summary", type == "turn.cancel" ? "Cancelled" : json::text(source, "reason"), 256); result.disposition = "status"; }
        if (type != "turn.cancel" && !counter(source, "turnId")) malformed = true;
        if (!error.is_null() && !stringField(error, "message")) malformed = true;
    } else if (type == "interaction.request" || type == "interaction.resolved") {
        if (!stringField(source, "id", true)) malformed = true;
        const auto field = type == "interaction.request" ? "request" : "response";
        const auto value = json::get(source, field);
        if (!hasField(source, field)) malformed = true;
        const auto kind = json::text(source, "kind");
        if (type == "interaction.request" && kind != "approval" && kind != "question" && kind != "user_tool") malformed = true;
        prose((type == "interaction.request" ? "Interaction requested: " : "Interaction resolved: ") + simdjson::minify(value));
    } else if (type == "tools.update_store") {
        if (!stringField(source, "key", true) || json::get(source, "value").is_null()) malformed = true;
        prose("Provider state " + json::text(source, "key") + ": " + simdjson::minify(json::get(source, "value")));
    } else if (type == "goal.create" || type == "goal.update" || type == "goal.clear") {
        if (type == "goal.create" && (!stringField(source, "goalId", true) || !stringField(source, "objective"))) malformed = true;
        const auto status = json::text(source, "status");
        if (hasField(source, "status") && status != "active" && status != "paused" && status != "blocked" && status != "complete") malformed = true;
        prose(type == "goal.create" ? "Goal: " + json::text(source, "objective") : type == "goal.clear" ? "Goal cleared" : "Goal " + json::text(source, "status") + ": " + json::text(source, "reason"));
    } else if (type == "task.started" || type == "task.terminated") {
        const auto info = json::get(source, "info");
        if (!info.is_object() || !stringField(info, "taskId", true)) malformed = true;
        const auto kind = json::text(info, "kind"), status = json::text(info, "status");
        if (kind != "agent" && kind != "process") malformed = true;
        if (status != "running" && status != "completed" && status != "failed" && status != "timed_out" && status != "killed" && status != "lost") malformed = true;
        if (hasField(source, "outputTail") && !stringField(source, "outputTail")) malformed = true;
        prose(json::text(info, "description") + " (" + status + ")" + (json::text(source, "outputTail").empty() ? "" : "\n" + json::text(source, "outputTail")));
    } else if (type == "plan.revision") {
        if (!stringField(source, "id", true) || !counter(source, "version") || !stringField(source, "key", true)) malformed = true;
        prose("Plan revision " + std::to_string(json::integer(source, "version")) + ": " + json::text(source, "key"));
    } else {
        // Each disposition is explicit; no catch-all turns a future record
        // into successful empty content. Prompt envelopes are admission facts;
        // context.append_message is the persisted authored message authority.
        static const std::map<std::string, std::pair<const char*, char>> facts = {
            {"context.clear", {"", 'n'}}, {"cron.add", {"task", 'o'}}, {"cron.cursor", {"id", 's'}}, {"cron.delete", {"ids", 'a'}},
            {"file_history.checkpoint", {"entries", 'o'}}, {"file_history.tracked", {"entry", 'o'}}, {"forked", {"", 'n'}},
            {"full_compaction.begin", {"source", 's'}}, {"full_compaction.cancel", {"", 'n'}}, {"full_compaction.complete", {"", 'n'}},
            {"interruptionReminder.recorded", {"turnId", 'i'}}, {"llm.request", {"model", 's'}}, {"llm.tools_snapshot", {"tools", 'a'}},
            {"mcp.tools_discovered", {"tools", 'a'}}, {"permission.record_approval_result", {"toolCallId", 's'}},
            {"plan_mode.cancel", {"", 'n'}}, {"plan_mode.enter", {"id", 's'}}, {"plan_mode.exit", {"", 'n'}},
            {"plugin.session_start", {"", 'n'}}, {"prompt.aborted", {"promptId", 's'}}, {"prompt.accepted", {"promptId", 's'}},
            {"prompt.completed", {"promptId", 's'}}, {"prompt.steered", {"promptIds", 'a'}}, {"runtime.set_binding", {"runtimeId", 's'}},
            {"swarm_mode.enter", {"trigger", 's'}}, {"swarm_mode.exit", {"", 'n'}}, {"task.waitDelivered", {"keys", 'a'}},
            {"token_counting.measured", {"tokens", 'i'}}, {"token_counting.rebased", {"tokens", 'i'}}, {"token_counting.truncated", {"tokens", 'i'}},
            {"token_counting.turn_recorded", {"tokens", 'i'}}, {"tools.register_user_tool", {"name", 's'}}, {"tools.reset_active_tools", {"", 'n'}},
            {"tools.set_active_tools", {"names", 'a'}}, {"tools.unregister_user_tool", {"name", 's'}}, {"tower_mode.enter", {"", 'n'}},
            {"tower_mode.exit", {"", 'n'}}, {"turn.prompt", {"input", 'a'}}, {"turn.steer", {"input", 'a'}}
        };
        const auto found = facts.find(type);
        if (found == facts.end()) known = false;
        else {
            const auto field = json::get(source, found->second.first); const auto shape = found->second.second;
            malformed |= shape == 's' ? !field.is_string() : shape == 'a' ? !field.is_array() : shape == 'o' ? !field.is_object() : shape == 'i' ? !counter(source, found->second.first) : false;
            metadata();
        }
    }
    if (!known || malformed) {
        output = json::Object{}; output.string("provider", "kimi"); output.string("type", "unknown"); output.string("sourceType", result.sourceType, 256);
        output.boolean("malformed", malformed); output.number("unparsedContentCount", 1); output.boolean("truncated", cut);
        result.disposition = "unclassified"; result.visible = true;
    } else if (!converted) output.boolean("truncated", cut);
    const auto timestamp = json::get(source, "time");
    if (timestamp.is_string()) output.string("timestamp", json::text(source, "time"), 128);
    else if (timestamp.is_number()) output.raw("timestamp", simdjson::minify(timestamp));
    if (!json::text(source, "agentId").empty() && json::text(source, "agentId") != "main") output.boolean("isSidechain", true);
    result.json = output.finish(); return result;
}
}
