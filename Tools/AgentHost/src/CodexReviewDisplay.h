#pragma once
#include "Json.h"
#include <optional>
#include <limits>

namespace tessera {
// Display contract from Codex protocol/review_format.rs. Rust str::trim uses
// Unicode White_Space, not the current C locale; review bodies use str::lines.
inline std::string codexReviewTrim(std::string value) {
    static const std::vector<std::string> spaces = {"\t", "\n", "\v", "\f", "\r", " ",
        "\xc2\x85", "\xc2\xa0", "\xe1\x9a\x80", "\xe2\x80\x80", "\xe2\x80\x81",
        "\xe2\x80\x82", "\xe2\x80\x83", "\xe2\x80\x84", "\xe2\x80\x85",
        "\xe2\x80\x86", "\xe2\x80\x87", "\xe2\x80\x88", "\xe2\x80\x89",
        "\xe2\x80\x8a", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xe2\x80\xaf",
        "\xe2\x81\x9f", "\xe3\x80\x80"};
    size_t begin = 0, end = value.size();
    bool matched = true;
    while (matched && begin < end) {
        matched = false;
        for (const auto& space : spaces) if (end - begin >= space.size() && value.compare(begin, space.size(), space) == 0) {
            begin += space.size(); matched = true; break;
        }
    }
    matched = true;
    while (matched && begin < end) {
        matched = false;
        for (const auto& space : spaces) if (end - begin >= space.size() && value.compare(end - space.size(), space.size(), space) == 0) {
            end -= space.size(); matched = true; break;
        }
    }
    return value.substr(begin, end - begin);
}

inline std::optional<std::string> codexReviewDisplay(simdjson::dom::element review) {
    constexpr const char* fallback = "Reviewer failed to output a response.";
    if (review.is_null()) return std::string(fallback);
    auto object = [](simdjson::dom::element value, std::initializer_list<const char*> names) {
        if (!value.is_object()) return false;
        std::set<std::string_view> found;
        for (const auto field : simdjson::dom::object(value.get_object().value())) if (!found.insert(field.key).second) return false;
        for (const auto name : names) if (!found.count(name)) return false;
        return found.size() == names.size();
    };
    if (!object(review, {"findings", "overall_correctness", "overall_explanation", "overall_confidence_score"}) ||
        !json::get(review, "findings").is_array() || !json::get(review, "overall_correctness").is_string() ||
        !json::get(review, "overall_explanation").is_string() || !json::get(review, "overall_confidence_score").is_number()) return {};
    auto result = codexReviewTrim(json::text(review, "overall_explanation"));
    const auto findings = json::get(review, "findings").get_array().value();
    std::string comments;
    if (findings.size()) comments = findings.size() > 1 ? "Full review comments:" : "Review comment:";
    for (const auto finding : findings) {
        if (!object(finding, {"title", "body", "confidence_score", "priority", "code_location"}) ||
            !json::get(finding, "title").is_string() || !json::get(finding, "body").is_string() ||
            !json::get(finding, "confidence_score").is_number() || !json::get(finding, "priority").is_int64() ||
            json::integer(finding, "priority") < INT32_MIN || json::integer(finding, "priority") > INT32_MAX) return {};
        const auto location = json::get(finding, "code_location"), range = json::get(location, "line_range");
        if (!object(location, {"absolute_file_path", "line_range"}) || !json::get(location, "absolute_file_path").is_string() ||
            !object(range, {"start", "end"})) return {};
        for (const auto key : {"start", "end"}) {
            uint64_t number;
            if (json::get(range, key).get_uint64().get(number) || number > UINT32_MAX) return {};
        }
        comments += "\n\n- " + json::text(finding, "title") + " — " + json::text(location, "absolute_file_path") + ":" +
            std::to_string(json::integer(range, "start")) + "-" + std::to_string(json::integer(range, "end"));
        const auto body = json::text(finding, "body");
        size_t position = 0;
        while (position < body.size()) {
            auto end = body.find('\n', position);
            const auto next = end == std::string::npos ? body.size() : end + 1;
            if (end == std::string::npos) end = body.size();
            else if (end > position && body[end - 1] == '\r') --end;
            comments += "\n  " + body.substr(position, end - position);
            position = next;
        }
    }
    comments = codexReviewTrim(comments);
    if (!comments.empty()) { if (!result.empty()) result += "\n\n"; result += comments; }
    return result.empty() ? std::string(fallback) : result;
}
}
