#pragma once
#include "Json.h"
#include <set>
#include <vector>

namespace tessera {
// Consumed envelope contracts from protocol.rs at bb1af235ea. The historical
// token_usage_record contract is separately pinned by the private field-shape
// inventory (it is absent from that checkout's RolloutItem enum), as are the
// thread_settings arrays codex-cli 0.156 writes (runtime_workspace_roots,
// disabled_plugin_ids), which that checkout's ThreadSettingsSnapshot lacks.
// Resume-state payloads are opaque JSON data, not containers of transcript
// message types.
struct CodexField { const char* name; char type; bool optional = false; };
inline bool codexFields(simdjson::dom::element value, std::initializer_list<CodexField> schema) {
    if (!value.is_object()) return false;
    std::set<std::string_view> seen;
    for (const auto field : simdjson::dom::object(value.get_object().value())) {
        if (!seen.insert(field.key).second) return false;
        const CodexField* match = nullptr;
        for (const auto& spec : schema) if (field.key == spec.name) match = &spec;
        if (!match) return false;
        if (match->optional && field.value.is_null()) continue;
        const auto input = field.value;
        if (!(match->type == 'v' || (match->type == 's' && input.is_string()) ||
              (match->type == 'o' && input.is_object()) || (match->type == 'a' && input.is_array()) ||
              (match->type == 'b' && input.is_bool()) || (match->type == 'n' && input.is_int64()) ||
              (match->type == 'u' && input.is_uint64()) ||
              (match->type == 'p' && (input.is_string() || input.is_object())))) return false;
    }
    for (const auto& spec : schema) if (!spec.optional && !seen.count(spec.name)) return false;
    return true;
}
inline bool codexAuxiliary(simdjson::dom::element source, const std::string& kind) {
    const bool raw = kind == "world_state" || kind == "inter_agent_communication_metadata" || kind == "token_usage_record";
    if (json::text(source, "type") != (raw ? kind : "event_msg")) return false;
    if (!codexFields(source, {{"type", 's'}, {"payload", 'o'}, {"ordinal", 'u', true},
            {"timestamp", 's', true}, {"isSidechain", 'b', true}, {"isSubagent", 'b', true}})) return false;
    const auto payload = json::get(source, "payload");
    if (!raw && json::text(payload, "type") != kind) return false;
    if (kind == "task_started" || kind == "turn_started")
        return codexFields(payload, {{"type", 's'}, {"turn_id", 's'}, {"started_at", 'n', true},
            {"trace_id", 's', true}, {"model_context_window", 'n', true}, {"collaboration_mode_kind", 's', true}});
    if (kind == "turn_aborted") {
        const auto reason = json::text(payload, "reason");
        return (reason == "interrupted" || reason == "replaced" || reason == "review_ended" || reason == "budget_limited") &&
            codexFields(payload, {{"type", 's'}, {"turn_id", 's', true}, {"reason", 's'},
                {"started_at", 'n', true}, {"completed_at", 'n', true}, {"duration_ms", 'n', true}});
    }
    if (kind == "thread_settings_applied")
        return codexFields(payload, {{"type", 's'}, {"thread_id", 's', true}, {"thread_settings", 'o'}}) &&
            codexFields(json::get(payload, "thread_settings"), {{"model", 's'}, {"cwd", 's'}, {"model_provider_id", 's'},
                {"approval_policy", 'p'}, {"approvals_reviewer", 's'}, {"permission_profile", 'o'},
                {"collaboration_mode", 'o'}, {"personality", 's', true}, {"reasoning_effort", 's', true},
                {"service_tier", 's', true}, {"reasoning_summary", 's', true}, {"active_permission_profile", 'o', true},
                // codex-cli 0.156 writes these on every resume (observed, not in the pinned
                // protocol); they are settings, and normalization emits none of their values.
                {"runtime_workspace_roots", 'a', true}, {"disabled_plugin_ids", 'a', true}});
    if (kind == "inter_agent_communication_metadata") return codexFields(payload, {{"trigger_turn", 'b'}});
    if (kind == "world_state") return codexFields(payload, {{"full", 'b'}, {"state", 'v'}});
    if (kind == "token_usage_record") {
        if (!codexFields(payload, {{"response_id", 's'}, {"root_turn_id", 's'}, {"session_id", 's'},
                {"thread_id", 's'}, {"turn_id", 's'}, {"usage", 'o'}, {"turn_token_usage", 'o'}, {"thread_token_usage", 'o'}})) return false;
        for (const auto key : {"usage", "turn_token_usage", "thread_token_usage"})
            if (!codexFields(json::get(payload, key), {{"input_tokens", 'n'}, {"cached_input_tokens", 'n'},
                    {"cache_write_input_tokens", 'n'}, {"output_tokens", 'n'}, {"reasoning_output_tokens", 'n'}, {"total_tokens", 'n'}})) return false;
        return true;
    }
    if (kind == "thread_goal_updated") {
        const auto goal = json::get(payload, "goal"); const auto status = json::text(goal, "status");
        return codexFields(payload, {{"type", 's'}, {"threadId", 's'}, {"turnId", 's', true}, {"goal", 'o'}}) &&
            codexFields(goal, {{"threadId", 's'}, {"objective", 's'}, {"status", 's'}, {"tokensUsed", 'n'},
                {"timeUsedSeconds", 'n'}, {"createdAt", 'n'}, {"updatedAt", 'n'}, {"tokenBudget", 'n', true}}) &&
            (status == "active" || status == "paused" || status == "blocked" || status == "usageLimited" ||
             status == "budgetLimited" || status == "complete");
    }
    return false;
}
}
