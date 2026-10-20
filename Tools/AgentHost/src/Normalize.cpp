#include "Normalize.h"
#include "PlainASCII.h"
#include "Json.h"
#include "CodexShellDisplay.h"
#include "CodexReviewDisplay.h"
#include "CodexAuxiliary.h"
#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <map>
#include <set>

namespace tessera {
namespace {
using Element = simdjson::dom::element;
using json::get;
using json::text;
std::string first(Element value, std::initializer_list<const char*> fields) {
    for (auto field : fields) { auto result = text(value, field); if (!result.empty()) return result; }
    return {};
}
using json::displayText;
std::string contentText(Element value, size_t depth = 0) {
    if (depth > 16) return {};
    std::string_view string;
    // Filter display controls before the retained-text budget. Cutting raw
    // bytes first could discard real text after a control-heavy prefix, then
    // appear untruncated because the sanitized result was below the UI cap.
    if (!value.get_string().get(string)) return displayText(string, 16384);
    if (value.is_array()) {
        std::string result;
        for (auto entry : simdjson::dom::array(value.get_array().value())) {
            auto part = contentText(entry, depth + 1);
            if (!part.empty()) { if (!result.empty()) result += '\n'; result += part; }
            if (result.size() >= 16384) { result.resize(16384); break; }
        }
        return result;
    }
    if (value.is_object()) {
        for (auto key : {"text", "thinking", "content"}) {
            auto part = contentText(get(value, key), depth + 1);
            if (!part.empty()) return part;
        }
    }
    return {};
}
Element firstValue(Element source, std::initializer_list<const char*> fields) {
    for (auto field : fields) { auto value = get(source, field); if (!value.is_null()) return value; }
    return get(source, "__tessera_missing__");
}
void appendPreview(Element value, std::string& output) {
    constexpr size_t limit = 16385; // one overflow byte preserves the cut flag
    auto append = [&](std::string_view text) { output.append(text.substr(0, limit - output.size())); };
    if (output.size() >= limit) return;
    if (value.is_object()) {
        // Object insertion order is not authored content. Core JSONL and the
        // App Server's serde_json map can serialize it in different orders;
        // sort before clipping so both paths retain the same useful prefix.
        std::vector<std::pair<std::string_view, Element>> fields;
        for (const auto field : simdjson::dom::object(value.get_object().value())) fields.emplace_back(field.key, field.value);
        std::stable_sort(fields.begin(), fields.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        append("{"); bool first = true;
        for (const auto& field : fields) {
            if (output.size() >= limit) break;
            if (!first) append(","); first = false;
            append(json::quote(field.first, field.first.size())); append(":");
            appendPreview(field.second, output);
        }
        append("}");
    } else if (value.is_array()) {
        append("["); bool first = true;
        for (const auto part : simdjson::dom::array(value.get_array().value())) {
            if (output.size() >= limit) break;
            if (!first) append(","); first = false;
            appendPreview(part, output);
        }
        append("]");
    } else append(simdjson::minify(value));
}
std::string preview(Element value) {
    if (value.is_null()) return {};
    if (value.is_string()) return contentText(value);
    std::string raw; raw.reserve(16385);
    appendPreview(value, raw);
    return raw;
}
bool starts(const std::string& text, const char* prefix) {
    const auto start = text.find_first_not_of(" \t\r\n");
    return start != std::string::npos && text.compare(start, std::char_traits<char>::length(prefix), prefix) == 0;
}
std::string basename(std::string path) {
    while (!path.empty() && path.back() == '/') path.pop_back();
    return path.substr(path.find_last_of('/') == std::string::npos ? 0 : path.find_last_of('/') + 1);
}

std::string codexDisplayPath(const std::string& uri) {
    // Display-only counterpart to PathUri::inferred_native_path_string. Never
    // resolve/open this path or use it as attachment/file-read authority.
    if (uri.rfind("file://", 0) != 0 || uri.find_first_of("?#") != std::string::npos) return uri;
    const auto slash = uri.find('/', 7);
    if (slash == std::string::npos) return uri;
    const auto host = uri.substr(7, slash - 7);
    std::vector<std::string> segments;
    auto hex = [](char c) -> int { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; };
    for (size_t start = slash + 1; start <= uri.size();) {
        auto end = uri.find('/', start); if (end == std::string::npos) end = uri.size();
        std::string value;
        for (size_t i = start; i < end; ++i) {
            if (uri[i] == '%' && i + 2 < end && hex(uri[i + 1]) >= 0 && hex(uri[i + 2]) >= 0) {
                value += static_cast<char>(hex(uri[i + 1]) * 16 + hex(uri[i + 2])); i += 2;
            } else value += uri[i];
        }
        // Preserve opaque/non-UTF8 URI spellings instead of inventing a path.
        if (value.find('\0') != std::string::npos || !simdjson::validate_utf8(value.data(), value.size())) return uri;
        segments.push_back(std::move(value));
        if (end == uri.size()) break;
        start = end + 1;
    }
    const bool drive = !segments.empty() && segments[0].size() == 2 && segments[0][1] == ':' &&
        ((segments[0][0] >= 'a' && segments[0][0] <= 'z') || (segments[0][0] >= 'A' && segments[0][0] <= 'Z'));
    if (!host.empty() && (segments.empty() || segments[0].empty())) return uri;
    std::string path;
    if (!host.empty()) path = "\\\\" + host;
    for (size_t i = 0; i < segments.size(); ++i) {
        if (!host.empty() || !drive || i) path += !host.empty() || drive ? '\\' : '/';
        path += segments[i];
    }
    if (drive && path.size() == 2) path += '\\';
    return path;
}

bool claudeBookkeeping(Element source, const std::string& type) {
    // Pinned SDK transcript selection excludes these non-message envelopes.
    // Validate the observed schema before omitting their private resume/cache
    // payloads. Unknown fields or malformed known fields are NOT ignored.
    struct Field { const char* name; char kind; bool optional = false; };
    std::vector<Field> fields;
    if (type == "file-history-snapshot") fields = {{"messageId", 's'}, {"snapshot", 'o'}, {"isSnapshotUpdate", 'b'}};
    else if (type == "file-history-delta") fields = {{"messageId", 's'}, {"snapshotMessageId", 's'}, {"trackingPath", 's'}, {"backup", 'o'}, {"timestamp", 's'}};
    else if (type == "last-prompt") fields = {{"leafUuid", 's'}, {"sessionId", 's'}, {"lastPrompt", 's', true}};
    else if (type == "atis-latch") fields = {{"atis", 's'}, {"sessionId", 's'}};
    else if (type == "bridge-session") fields = {{"sessionId", 's'}, {"bridgeSessionId", 's'}, {"lastSequenceNum", 'n'}, {"ownerAccountUuid", 's'}, {"ownerOrganizationUuid", 's'}};
    else if (type == "relocated") fields = {{"sessionId", 's'}, {"relocatedCwd", 's'}};
    else if (type == "worktree-state") fields = {{"sessionId", 's'}, {"worktreeSession", '?'}};
    else if (type == "pr-link") fields = {{"sessionId", 's'}, {"prNumber", 'n'}, {"prUrl", 's'}, {"prRepository", 's'}, {"timestamp", 's'}};
    else if (type == "fork-context-ref") fields = {{"agentId", 's'}, {"parentSessionId", 's'}, {"parentLastUuid", 's'}, {"contextLength", 'n'}};
    else return false;
    for (const auto& field : fields) {
        if (source.at_key(field.name).error() == simdjson::NO_SUCH_FIELD) {
            if (field.optional) continue;
            return false;
        }
        const auto value = get(source, field.name);
        const bool valid = field.kind == 's' ? value.is_string() : field.kind == 'o' ? value.is_object() :
            field.kind == '?' ? value.is_object() || value.is_null() : field.kind == 'b' ? value.is_bool() :
            (value.is_uint64() || (value.is_int64() && value.get_int64().value() >= 0));
        if (!valid) return false;
    }
    std::set<std::string_view> seen;
    for (const auto field : simdjson::dom::object(source.get_object().value())) {
        // DOM lookups return the first occurrence; other decoders may use the
        // last. Ambiguous envelopes must never qualify for silent omission.
        if (!seen.insert(field.key).second) return false;
        if (field.key == "type") continue;
        if (std::none_of(fields.begin(), fields.end(), [&](const auto& known) { return field.key == known.name; })) return false;
    }
    return true;
}

// Claude's signed thinking blocks carry a protobuf block_kind at 2/1/8.
// Walk every field so a malformed suffix cannot validate an earlier match;
// repeated fields use the last occurrence, as in Claude's display filter.
bool claudeNarrationSignature(std::string_view signature) {
    // An oversized record keeps only a 16 KiB prefix of each string, and a
    // clipped signature must not classify by its prefix. Real narration
    // signatures are under 2 KiB.
    if (signature.empty() || signature.size() >= 16384) return false;
    std::string bytes;
    bytes.reserve(signature.size() * 3 / 4);
    uint32_t bits = 0;
    int count = 0;
    bool padding = false;
    size_t digits = 0, pads = 0;
    for (unsigned char c : signature) {
        // atob's ASCII whitespace; it rejects a vertical tab.
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') continue;
        if (c == '=') { padding = true; ++pads; continue; }
        if (padding) return false;
        int value = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 :
            c >= '0' && c <= '9' ? c - '0' + 52 : c == '+' ? 62 : c == '/' ? 63 : -1;
        if (value < 0) return false;
        ++digits; bits = (bits << 6) | static_cast<uint32_t>(value); count += 6;
        if (count >= 8) { count -= 8; bytes.push_back(static_cast<char>((bits >> count) & 255)); }
    }
    if (digits % 4 == 1 || pads > 2 || (pads && (digits + pads) % 4 != 0) ||
        (pads == 1 && digits % 4 != 3) || (pads == 2 && digits % 4 != 2)) return false;
    auto last = [](std::string_view data, uint64_t wanted, std::string_view& found) {
        size_t pos = 0;
        found = {};
        auto varint = [&](uint64_t& value) {
            value = 0;
            for (int i = 0; i < 10; ++i) {
                if (pos >= data.size()) return false;
                const auto byte = static_cast<unsigned char>(data[pos++]);
                if (i == 9 && (byte & 0xfe)) return false;
                value |= uint64_t(byte & 127) << (7 * i);
                if (!(byte & 128)) return true;
            }
            return false;
        };
        while (pos < data.size()) {
            uint64_t key, length;
            if (!varint(key)) return false;
            const auto wire = key & 7;
            if (wire == 0) { if (!varint(length)) return false; }
            else if (wire == 1 || wire == 5) {
                const size_t width = wire == 1 ? 8 : 4;
                if (width > data.size() - pos) return false;
                pos += width;
            } else if (wire == 2) {
                if (!varint(length) || length > data.size() - pos) return false;
                if (key >> 3 == wanted) found = data.substr(pos, static_cast<size_t>(length));
                pos += static_cast<size_t>(length);
            } else return false;
        }
        return true;
    };
    std::string_view second, first, kind;
    return last(bytes, 2, second) && !second.empty() && last(second, 1, first) && !first.empty() &&
        last(first, 8, kind) && kind == "narration";
}

bool claudeBlank(std::string_view body) {
    // JavaScript String.trim whitespace, including BOM but excluding NEL.
    static constexpr std::string_view spaces[] = {" ", "\t", "\n", "\v", "\f", "\r", "\xc2\xa0", "\xe1\x9a\x80",
        "\xe2\x80\x80", "\xe2\x80\x81", "\xe2\x80\x82", "\xe2\x80\x83", "\xe2\x80\x84", "\xe2\x80\x85",
        "\xe2\x80\x86", "\xe2\x80\x87", "\xe2\x80\x88", "\xe2\x80\x89", "\xe2\x80\x8a", "\xe2\x80\xa8",
        "\xe2\x80\xa9", "\xe2\x80\xaf", "\xe2\x81\x9f", "\xe3\x80\x80", "\xef\xbb\xbf"};
    while (!body.empty()) {
        bool removed = false;
        for (const auto space : spaces) if (body.substr(0, space.size()) == space) {
            body.remove_prefix(space.size()); removed = true; break;
        }
        if (!removed) return false;
    }
    return true;
}

struct Blocks {
    explicit Blocks(bool claude = false) : claude(claude) {}
    bool claude;
    std::vector<std::string> values;
    std::vector<bool> prose;
    size_t bytes = 0;
    bool truncated = false;
    bool allResults = true;
    uint64_t unparsedContent = 0;
    void notice(const std::string& raw) {
        const auto body = displayText(raw, 2049);
        json::Object block; block.string("type", "system-event"); block.string("text", body, 2048);
        const auto value = block.finish();
        while (!values.empty() && (values.size() >= 64 || bytes + value.size() > 45000)) {
            truncated = true; bytes -= values.back().size(); values.pop_back(); prose.pop_back();
        }
        truncated |= body.size() > 2048;
        bytes += value.size(); values.push_back(value); prose.push_back(false);
    }
    void unsupported(const std::string& type) {
        ++unparsedContent;
        json::Object block; block.string("type", "unknown"); block.string("sourceType", type, 128);
        const auto value = block.finish();
        if (values.size() >= 64 || bytes + value.size() > 45000) { truncated = true; return; }
        bytes += value.size(); values.push_back(value); prose.push_back(false);
    }
    std::string reasoningText(Element value, size_t depth = 0) {
        if (depth > 16) { ++unparsedContent; return {}; }
        if (value.is_null()) return {};
        if (value.is_string()) return contentText(value);
        if (value.is_array()) {
            std::string result;
            for (auto part : simdjson::dom::array(value.get_array().value())) {
                auto body = reasoningText(part, depth + 1);
                if (!body.empty() && result.size() < 16384) {
                    if (!result.empty()) result += '\n';
                    result += body.substr(0, 16384 - result.size());
                }
            }
            return result;
        }
        const auto type = text(value, "type");
        if (type == "text" || type == "reasoning_text" || type == "summary_text" || type == "thinking") {
            const auto body = type == "thinking" ? firstValue(value, {"thinking", "text"}) : get(value, "text");
            if (body.is_string()) return contentText(body);
        }
        ++unparsedContent;
        return {};
    }
    void add(Element item, bool compact = false, size_t depth = 0, const std::string& resultID = {}) {
        if (depth > 16) { ++unparsedContent; truncated = true; return; }
        if (!item.is_object() && !item.is_string()) { ++unparsedContent; return; }
        auto type = text(item, "type");
        if (item.is_string()) type = "text";
        if (type.empty()) type = "text";
        allResults &= type == "tool_result" || type == "function_call_output" || type == "custom_tool_call_output";
        bool humanText = type == "text" || type == "input_text" || type == "output_text";
        json::Object block;
        block.optional("toolCallID", resultID, 256);
        std::string body;
        bool bodyTruncated = false;
        auto writeBody = [&](const char* field) {
            body = displayText(body);
            size_t retained = std::min<size_t>(body.size(), 8192);
            // Bound encoded bytes too: a control character can expand 6x.
            while (retained && json::quote(body, retained).size() > 24000) retained /= 2;
            bodyTruncated = body.size() > retained;
            block.string(field, body, retained);
        };
        if (type == "text" || type == "input_text" || type == "output_text") {
            if (!item.is_string() && !get(item, "text").is_string()) {
                ++unparsedContent; block.string("type", "unknown"); block.string("sourceType", "invalid-text");
            } else {
                block.string("type", compact ? "compact-summary" : "text");
                body = item.is_string() ? contentText(item) : text(item, "text");
                writeBody("text");
            }
        } else if (type == "thinking" || type == "reasoning" || type == "summary_text" || type == "reasoning_text") {
            if (type != "reasoning" && !firstValue(item, {"thinking", "text"}).is_string()) {
                unsupported("invalid-" + type); return;
            }
            body = reasoningText(firstValue(item, {"thinking", "text", "summary"}));
            if (type == "reasoning") {
                auto details = reasoningText(get(item, "content"));
                if (!details.empty()) body += (body.empty() ? "" : "\n") + details;
            }
            // Empty/redacted reasoning does not create an empty visible card.
            if (body.empty()) return;
            bool narration = false;
            std::string_view thought;
            const auto signature = get(item, "signature");
            if (claude && type == "thinking" && !get(item, "thinking").get_string().get(thought) && signature.is_string()) {
                std::string_view raw;
                if (!signature.get_string().get(raw)) narration = claudeNarrationSignature(raw);
            }
            if (narration) {
                // Claude trims the source text, not this bounded preview.
                if (claudeBlank(thought)) return;
                humanText = true;
            }
            block.string("type", narration ? "text" : "thinking");
            writeBody("text");
        } else if (type == "tool_use" || type == "server_tool_use" || type == "function_call" || type == "custom_tool_call" ||
                   type == "tool_search_call" || type == "web_search_call") {
            block.string("type", "tool_call");
            block.string("name", type == "tool_search_call" ? "Tool search" : type == "web_search_call" ? "Web search" :
                text(item, "name").empty() ? "Tool" : text(item, "name"), 256);
            block.optional("toolCallID", first(item, {"call_id", "id"}), 256);
            body = preview(firstValue(item, {"input", "arguments", "action"}));
            writeBody("preview");
        } else if (type == "tool_search_output") {
            block.string("type", "tool_result"); block.optional("toolCallID", first(item, {"call_id", "id"}), 256);
            body = preview(get(item, "tools")); writeBody("preview");
        } else if (type == "tool_result" || type == "function_call_output" || type == "custom_tool_call_output") {
            const auto content = firstValue(item, {"content", "output"});
            const auto identifier = first(item, {"tool_use_id", "call_id"});
            if (!content.is_null() && !content.is_string() && !content.is_object() && !content.is_array()) {
                unsupported("invalid-tool-result-content"); return;
            }
            if (content.is_object()) {
                const auto kind = text(content, "type");
                const bool textual = kind == "text" || kind == "input_text" || kind == "output_text";
                if (!textual || !get(content, "text").is_string()) {
                    const auto resultsOnly = allResults;
                    add(content, false, depth + 1, identifier);
                    allResults = resultsOnly;
                    return;
                }
            }
            if (content.is_array()) {
                bool mixed = false;
                for (auto part : simdjson::dom::array(content.get_array().value())) {
                    const auto kind = text(part, "type");
                    if (!part.is_string() && ((kind != "text" && kind != "input_text" && kind != "output_text") ||
                        !get(part, "text").is_string())) mixed = true;
                }
                if (mixed) {
                    // Preserve non-text tool output in source order instead
                    // of flattening images/references/future blocks to "".
                    const auto resultsOnly = allResults;
                    simdjson::dom::parser parser;
                    for (auto part : simdjson::dom::array(content.get_array().value())) {
                        const auto kind = text(part, "type");
                        if (part.is_string() || kind == "text" || kind == "input_text" || kind == "output_text") {
                            json::Object result; result.string("type", "tool_result"); result.string("tool_use_id", identifier, 256);
                            result.raw("content", simdjson::minify(part));
                            Element value;
                            if (parser.parse(result.finish()).get(value)) { ++unparsedContent; continue; }
                            add(value, false, depth + 1);
                        } else add(part, false, depth + 1, identifier);
                    }
                    allResults = resultsOnly;
                    return;
                }
            }
            block.string("type", "tool_result");
            block.optional("toolCallID", identifier, 256);
            body = contentText(content);
            writeBody("preview");
        } else if (type == "advisor_tool_result") {
            // Claude's documented result union includes plaintext, encrypted
            // output, and errors. A future variant must not become empty text.
            const auto content = get(item, "content");
            const auto variant = text(content, "type");
            if ((variant == "advisor_result" && !get(content, "text").is_string()) ||
                (variant == "advisor_tool_result_error" && !get(content, "error_code").is_string())) {
                unsupported("invalid-" + variant); return;
            }
            if (variant == "advisor_result" || variant == "advisor_redacted_result" || variant == "advisor_tool_result_error") {
                block.string("type", "tool_result"); block.optional("toolCallID", text(item, "tool_use_id"), 256);
                body = variant == "advisor_result" ? text(content, "text") :
                    variant == "advisor_redacted_result" ? "Advisor result is encrypted" : "Advisor error: " + text(content, "error_code");
                writeBody("preview");
            } else {
                ++unparsedContent;
                block.string("type", "unknown"); block.string("sourceType", "advisor_tool_result/" + variant, 128);
            }
        } else if (type == "tessera-provider-note") {
            if (!get(item, "text").is_string()) { unsupported("invalid-provider-note"); return; }
            block.string("type", "system-event"); body = text(item, "text"); writeBody("text");
        } else if (type == "fallback") {
            block.string("type", "system-event");
            body = "Model fallback: " + text(get(item, "from"), "model") + " → " + text(get(item, "to"), "model");
            writeBody("text");
        } else if (type == "encrypted_content") {
            // Pinned Codex AgentMessageInputContent union: opaque data has no
            // plaintext representation. Retain its position, never the blob.
            block.string("type", "attachment"); block.string("name", "Encrypted content"); block.string("mediaType", "encrypted");
        } else if (type == "tool_reference") {
            block.string("type", "attachment"); block.string("name", text(item, "tool_name"), 256);
            block.string("mediaType", "tool-reference");
        } else if (type == "edit") {
            block.string("type", "edit"); block.string("path", text(item, "path"), 512);
            body = text(item, "diff"); writeBody("diff");
        } else if (type == "attachment" || type == "image" || type == "input_image" || type == "localImage" ||
                   type == "audio" || type == "localAudio" || type == "skill" || type == "mention") {
            const auto url = text(item, "image_url");
            const bool embedded = starts(url, "data:image/") && url.find(";base64,") < 128;
            if (type == "input_image" && !embedded && url != "tessera:image") {
                ++unparsedContent;
                block.string("type", "unknown"); block.string("sourceType", type);
            } else {
                block.string("type", "attachment");
                const bool audio = type == "audio" || type == "localAudio";
                const bool named = type == "attachment" || type == "skill" || type == "mention";
                block.string("name", named ? first(item, {"name", "filename", "path"}) : audio ? "Audio" : "Image", 512);
                block.string("mediaType", type == "attachment" ? first(item, {"media_type", "mime_type"}) :
                    audio ? "audio" : named ? type : "image", 128);
            }
        } else {
            ++unparsedContent;
            block.string("type", "unknown"); block.string("sourceType", type, 128);
        }
        block.boolean("truncated", bodyTruncated);
        auto result = block.finish();
        while (values.size() >= 64 || bytes + result.size() > 45000) {
            truncated = true;
            // Large tool batches cannot hide later human-visible prose. Keep
            // role classification independent of which bounded previews fit.
            if (!humanText) return;
            auto victim = std::find(prose.begin(), prose.end(), false);
            const auto index = victim == prose.end() ? size_t(0) : static_cast<size_t>(victim - prose.begin());
            if (values.empty()) return;
            bytes -= values[index].size(); values.erase(values.begin() + index); prose.erase(prose.begin() + index);
        }
        truncated |= bodyTruncated;
        bytes += result.size(); values.push_back(std::move(result)); prose.push_back(humanText);
    }
    void content(Element value, bool compact = false, const std::vector<bool>* selected = nullptr) {
        if (value.is_array()) {
            // Responses input_text arrays may be token-sized fragments of
            // one user input. Join exactly, with no invented separators,
            // before applying a display-block limit. Other content is a hard
            // boundary, and accumulation stays bounded even for giant input.
            std::string input;
            bool hasInput = false;
            auto flushInput = [&] {
                if (!hasInput) return;
                simdjson::dom::parser parser;
                json::Object item; item.string("type", "text"); item.string("text", input, input.size());
                Element parsed;
                if (parser.parse(item.finish()).get(parsed)) unsupported("invalid-input-fragments");
                else add(parsed, compact);
                input.clear(); hasInput = false;
            };
            size_t index = 0;
            for (auto item : simdjson::dom::array(value.get_array().value())) {
                if (selected && !(*selected)[index++]) { flushInput(); continue; }
                if (text(item, "type") == "input_text" && get(item, "text").is_string()) {
                    hasInput = true;
                    const auto part = displayText(text(item, "text"));
                    const auto keep = std::min<size_t>(part.size(), 16384 - input.size());
                    input.append(part, 0, keep);
                    truncated |= keep != part.size();
                } else { flushInput(); add(item, compact); }
            }
            flushInput();
        } else if (!value.is_null()) add(value, compact);
    }
};
}

NormalizedRecord normalize(const std::string& provider, Element source, bool cut, const std::string& fallbackID) {
    if (provider == "kimi") return normalizeKimi(source, cut, fallbackID);
    NormalizedRecord result;
    json::Object out;
    out.string("provider", provider);
    const auto type = text(source, "type");
    auto payload = get(source, "payload");
    auto payloadType = text(payload, "type");
    result.sourceType = type + (payloadType.empty() ? "" : "/" + payloadType);
    if (provider == "codex" && type == "event_msg" && (payloadType == "user_message" || payloadType == "agent_message")) {
        const bool user = payloadType == "user_message";
        bool valid = payload.is_object() && get(payload, "message").is_string();
        const std::set<std::string_view> fields = user ? std::set<std::string_view>{"type", "client_id", "message", "images", "image_details", "local_images", "local_image_details", "audio", "local_audio", "text_elements"} :
            std::set<std::string_view>{"type", "message", "phase", "memory_citation", "questions", "delivery"};
        std::set<std::string_view> seen;
        if (payload.is_object()) for (const auto field : simdjson::dom::object(payload.get_object().value()))
            if (!fields.count(field.key) || !seen.insert(field.key).second) valid = false;
        json::Object item;
        if (user) {
            const auto client = get(payload, "client_id");
            valid &= client.is_null() || client.is_string();
            for (const auto key : {"image_details", "local_image_details", "text_elements"}) {
                const auto value = get(payload, key);
                if (payload.at_key(key).error() != simdjson::NO_SUCH_FIELD && !value.is_array()) valid = false;
            }
            std::vector<std::string> content;
            const auto body = text(payload, "message");
            if (!codexReviewTrim(body).empty()) {
                json::Object part; part.string("type", "text"); part.string("text", body, body.size()); content.push_back(part.finish());
            }
            for (const auto& pair : std::initializer_list<std::pair<const char*, const char*>>{
                {"images", "image"}, {"local_images", "localImage"}, {"audio", "audio"}, {"local_audio", "localAudio"}}) {
                const auto values = get(payload, pair.first);
                if (values.is_null() && (std::string_view(pair.first) == "images" || std::string_view(pair.first) == "audio" || payload.at_key(pair.first).error() == simdjson::NO_SUCH_FIELD)) continue;
                if (!values.is_array()) { valid = false; continue; }
                for (const auto value : simdjson::dom::array(values.get_array().value())) {
                    if (!value.is_string()) { valid = false; continue; }
                    const auto body = value.get_string().value();
                    json::Object part; part.string("type", pair.second);
                    part.string(std::string_view(pair.second).substr(0, 5) == "local" ? "path" : "url", body, body.size());
                    content.push_back(part.finish());
                }
            }
            item.raw("content", json::array(content));
        } else {
            item.string("text", text(payload, "message"), text(payload, "message").size());
            if (!get(payload, "questions").is_null()) item.raw("questions", simdjson::minify(get(payload, "questions")));
            const auto phase = get(payload, "phase");
            if (!phase.is_null() && (!phase.is_string() || (text(payload, "phase") != "commentary" && text(payload, "phase") != "final_answer"))) valid = false;
            if (!get(payload, "memory_citation").is_null() && !get(payload, "memory_citation").is_object()) valid = false;
        }
        if (!user && valid && text(payload, "message").empty() && get(payload, "questions").is_null()) {
            // The upstream legacy reducer does not create an authored item
            // for an empty assistant event. Preserve its typed bookkeeping.
            out.string("type", "system"); out.string("event", "empty-agent-message");
            result.json = out.finish(); result.disposition = "metadata"; return result;
        }
        item.string("type", valid ? user ? "userMessage" : "agentMessage" : "invalidLegacyMessage");
        simdjson::dom::parser parser;
        auto decoded = normalizeCodexItem(parser.parse(item.finish()).value(), "", cut);
        decoded.sourceType = result.sourceType;
        // Keep physical event time without altering the authored text.
        json::Object timed;
        for (const auto field : simdjson::dom::object(parser.parse(decoded.json).value().get_object().value())) timed.raw(field.key, simdjson::minify(field.value));
        timed.optional("timestamp", text(source, "timestamp"), 128); decoded.json = timed.finish();
        return decoded;
    }
    if (provider == "codex" && type == "event_msg" && payloadType == "item_completed") {
        auto unique = [](Element value) {
            if (!value.is_object()) return false;
            std::set<std::string_view> keys;
            for (const auto field : simdjson::dom::object(value.get_object().value())) if (!keys.insert(field.key).second) return false;
            return true;
        };
        bool valid = unique(source) && unique(payload);
        for (const auto key : {"thread_id", "turn_id"})
            valid &= get(payload, key).is_string() && !text(payload, key).empty() && text(payload, key).size() <= 256;
        valid &= get(payload, "started_at_ms").is_null() || get(payload, "started_at_ms").is_int64();
        valid &= payload.at_key("completed_at_ms").error() == simdjson::NO_SUCH_FIELD ||
            get(payload, "completed_at_ms").is_int64();
        valid &= get(source, "ordinal").is_null() || get(source, "ordinal").is_uint64();
        if (valid) {
            auto completed = normalizeCodexCoreItem(get(payload, "item"), text(payload, "turn_id"), cut);
            completed.sourceType = result.sourceType;
            return completed;
        }
        out.string("type", "unknown"); out.string("sourceType", "invalid-item-completed-envelope");
        out.number("unparsedContentCount", 1); out.boolean("truncated", cut);
        result.json = out.finish(); result.disposition = "unclassified"; result.visible = true;
        return result;
    }
    result.providerID = first(source, {"uuid", "id"});
    result.parentID = first(source, {"parentUuid", "parentId"});
    if (result.sourceType.size() > 256) result.sourceType = "source-type-too-large";
    if (result.providerID.size() > 256 || result.parentID.size() > 256) {
        result.providerID.clear(); result.parentID.clear(); cut = true;
    }
    const auto origin = firstValue(payload, {"source"});
    const bool child = json::boolean(source, "isSidechain") || json::boolean(source, "isSubagent") ||
        json::boolean(payload, "isSidechain") || (origin.is_object() && !get(origin, "subagent").is_null());
    bool known = true;
    Blocks blocks(provider == "claude");
    auto message = [&](std::string role, Element content, bool compact = false) {
        out.string("type", "message");
        blocks.content(content, compact);
        if (role == "user" && !blocks.values.empty() && blocks.allResults) role = "tool";
        out.string("role", role);
        out.raw("blocks", json::array(blocks.values));
        result.visible = role != "system" && role != "developer";
        result.disposition = result.visible ? "message" : "system";
    };
    auto metadata = [&](Element from) {
        if (child) return;
        out.optional("model", text(from, "model"), 256);
        out.optional("branch", first(from, {"gitBranch", "branch"}), 512);
        out.optional("project", basename(text(from, "cwd")), 256);
        out.optional("permissionMode", first(from, {"permission_mode", "permissionMode", "approval_policy"}), 256);
    };

    if (provider == "opencode") {
        const auto info = get(source, "message");
        const bool modern = type == "native-message";
        const bool header = type == "native-header";
        const auto part = modern ? info : get(source, "part");
        const auto kind = modern ? text(source, "messageType") : text(part, "type");
        result.sourceType = std::string(modern ? "sqlite-message/" : "sqlite-part/") + kind;
        out.optional("sessionID", text(source, "sessionID"), 256);
        bool malformed = !info.is_object() || (!header && (!part.is_object() || kind.empty())) || result.providerID.empty();
        simdjson::dom::parser convertedParser;
        auto add = [&](const json::Object& block, bool compact = false) { blocks.add(convertedParser.parse(block.finish()).value(), compact); };
        auto prose = [&](const std::string& blockType, Element value) {
            if (!value.is_string()) { malformed = true; return; }
            json::Object block; block.string("type", blockType == "compact-summary" ? "text" : blockType);
            block.raw("text", simdjson::minify(value)); add(block, blockType == "compact-summary");
        };
        auto attachment = [&](Element item, bool legacy = false) {
            if (!item.is_object() || !get(item, "mime").is_string()) { malformed = true; return; }
            json::Object block; block.string("type", "attachment");
            block.string("name", first(item, legacy ? std::initializer_list<const char*>{"filename", "name"} :
                std::initializer_list<const char*>{"name", "filename"}), 256);
            block.string("mime_type", text(item, "mime"), 128); add(block);
            // URI/source fields are presentation metadata, never read authority.
        };
        auto attachments = [&](Element items, bool legacy = false) {
            if (items.is_null()) return;
            if (!items.is_array()) { malformed = true; return; }
            for (const auto item : simdjson::dom::array(items.get_array().value())) attachment(item, legacy);
        };
        auto tool = [&](Element item) {
            const auto state = get(item, "state"); const auto status = text(state, "status");
            const auto name = modern ? text(item, "name") : text(item, "tool");
            const auto id = modern ? text(item, "id") : text(item, "callID");
            if (!state.is_object() || name.empty() || id.empty() ||
                (status != "pending" && status != "running" && status != "completed" && status != "error")) { malformed = true; return; }
            json::Object call; call.string("type", "function_call"); call.string("name", name, 256); call.string("call_id", id, 256);
            call.raw("arguments", simdjson::minify(get(state, "input"))); add(call);
            if (status == "completed" || status == "error" || (modern && status == "running")) {
                json::Object output; output.string("type", "tool_result"); output.string("tool_use_id", id, 256);
                output.boolean("is_error", status == "error");
                if (status == "error") output.string("output", modern ? text(get(state, "error"), "message") : text(state, "error"), 16384);
                else if (!modern) output.raw("output", simdjson::minify(get(state, "output")));
                if (!modern || status == "error") add(output);
                if (modern) {
                    const auto content = get(state, "content");
                    if (!content.is_array()) malformed = true;
                    else for (const auto child : simdjson::dom::array(content.get_array().value())) {
                        const auto childType = text(child, "type");
                        if (childType == "text" && get(child, "text").is_string()) {
                            json::Object result; result.string("type", "tool_result"); result.string("tool_use_id", id, 256);
                            result.raw("output", simdjson::minify(get(child, "text"))); add(result);
                        } else if (childType == "file") attachment(child);
                        else blocks.unsupported(childType.empty() ? "invalid-opencode-tool-content" : childType);
                    }
                }
                attachments(get(state, "attachments"), !modern);
            }
        };
        auto finishMessage = [&](const std::string& role) {
            out.string("type", "message"); out.string("role", role); out.raw("blocks", json::array(blocks.values));
            result.visible = role != "system"; result.disposition = result.visible ? "message" : "system";
        };
        if (header) {
            result.sourceType = "sqlite-message/legacy-header";
            if (text(info, "role") != "user" && text(info, "role") != "assistant") malformed = true;
            if (!get(info, "error").is_null()) {
                const auto error = get(info, "error"); const auto name = text(error, "name");
                if (name == "MessageOutputLengthError" && get(error, "data").is_object()) {
                    json::Object block; block.string("type", "text"); block.string("text", "Provider output length limit reached"); add(block);
                } else if (name == "ProviderAuthError" || name == "UnknownError" || name == "MessageAbortedError" ||
                    name == "StructuredOutputError" || name == "ContextOverflowError" || name == "ContentFilterError" || name == "APIError") {
                    prose("text", get(get(error, "data"), "message"));
                } else { blocks.unsupported("opencode-error/" + name); }
                finishMessage("assistant");
            } else { out.string("type", "metadata"); result.disposition = "metadata"; }
        } else if (modern) {
            if (kind == "user" || kind == "synthetic" || kind == "system") {
                prose("text", get(info, "text"));
                if (kind == "user") {
                    attachments(get(info, "files"));
                    const auto agents = get(info, "agents");
                    if (!agents.is_null() && !agents.is_array()) malformed = true;
                    else if (agents.is_array()) for (const auto agent : simdjson::dom::array(agents.get_array().value())) {
                        if (!get(agent, "name").is_string()) { malformed = true; continue; }
                        json::Object mention; mention.string("type", "mention"); mention.string("name", text(agent, "name"), 256); add(mention);
                    }
                }
                // Synthetic and system context must not seed authored prose.
                finishMessage(kind == "user" ? "user" : "system");
            } else if (kind == "assistant") {
                const auto content = get(info, "content");
                if (!content.is_array()) malformed = true;
                else for (const auto item : simdjson::dom::array(content.get_array().value())) {
                    const auto itemType = text(item, "type");
                    if (itemType == "text" || itemType == "reasoning") prose(itemType == "text" ? "text" : "thinking", get(item, "text"));
                    else if (itemType == "tool") tool(item);
                    else { blocks.unsupported(itemType); }
                }
                if (!get(info, "error").is_null()) prose("text", get(get(info, "error"), "message"));
                finishMessage("assistant");
            } else if (kind == "shell") {
                if (text(info, "callID").empty() || !get(info, "command").is_string() || !get(info, "output").is_string()) malformed = true;
                json::Object call; call.string("type", "function_call"); call.string("name", "Shell");
                call.string("call_id", text(info, "callID"), 256); call.raw("arguments", simdjson::minify(get(info, "command"))); add(call);
                json::Object output; output.string("type", "tool_result"); output.string("tool_use_id", text(info, "callID"), 256);
                output.raw("output", simdjson::minify(get(info, "output"))); add(output); finishMessage("tool");
            } else if (kind == "compaction") {
                prose("compact-summary", get(info, "summary")); out.boolean("isCompactSummary", true); finishMessage("system"); result.visible = true;
            } else if (kind == "model-switched" || kind == "agent-switched") {
                out.string("type", "metadata"); result.disposition = "metadata";
                if (kind == "model-switched") {
                    if (text(get(info, "model"), "id").empty() || text(get(info, "model"), "providerID").empty()) malformed = true;
                    out.optional("model", text(get(info, "model"), "id"), 256);
                } else if (text(info, "agent").empty()) malformed = true;
            } else known = false;
        } else {
            const auto role = text(info, "role");
            if (role != "user" && role != "assistant") malformed = true;
            if (kind == "text" || kind == "reasoning") {
                prose(kind == "text" ? "text" : "thinking", get(part, "text"));
                finishMessage(json::boolean(part, "synthetic") || json::boolean(part, "ignored") ? "system" : role);
            } else if (kind == "tool") { tool(part); finishMessage("tool"); }
            else if (kind == "file") {
                attachment(part, true); finishMessage(role);
            } else if (kind == "subtask") { prose("text", get(part, "prompt")); finishMessage("assistant"); out.boolean("isSidechain", true); }
            else if (kind == "step-finish") {
                out.string("type", "completion"); out.string("summary", text(part, "reason"), 256); result.disposition = "status";
            } else if (kind == "compaction") {
                json::Object block; block.string("type", "text"); block.string("text", "Context compacted"); add(block, true);
                out.boolean("isCompactSummary", true); finishMessage("system"); result.visible = true;
            } else if (kind == "retry") {
                prose("text", get(get(get(part, "error"), "data"), "message")); finishMessage("assistant");
            } else if (kind == "agent") {
                if (text(part, "name").empty()) malformed = true;
                json::Object mention; mention.string("type", "mention"); mention.string("name", text(part, "name"), 256); add(mention); finishMessage(role);
            } else if (kind == "step-start" || kind == "snapshot" || kind == "patch") {
                out.string("type", "metadata"); result.disposition = "metadata";
            } else known = false;
        }
        if (!known || malformed) {
            out = json::Object{}; out.string("provider", "opencode"); out.string("type", "unknown");
            out.string("sourceType", result.sourceType, 128); out.boolean("malformed", malformed);
            out.number("unparsedContentCount", 1); known = false; result.visible = true;
        }
    } else if (provider == "pi") {
        auto unique = [](Element value) {
            if (!value.is_object()) return false;
            std::set<std::string_view> keys;
            for (const auto field : simdjson::dom::object(value.get_object().value())) if (!keys.insert(field.key).second) return false;
            return true;
        };
        auto validID = [](Element value, const char* key) {
            return get(value, key).is_string() && !text(value, key).empty() && text(value, key).size() <= 256;
        };
        auto optionalBool = [](Element value, const char* key) {
            return value.at_key(key).error() == simdjson::NO_SUCH_FIELD || get(value, key).is_bool();
        };
        auto validContent = [&](Element value) {
            if (value.is_string()) return true;
            if (!value.is_array()) return false;
            for (const auto part : simdjson::dom::array(value.get_array().value())) if (!unique(part)) return false;
            return true;
        };
        // Pi's identity is id, never Claude's uuid. Offset fallback is only
        // display identity for v1 records; the index separately proves version
        // and rejects missing structural IDs in v2/v3.
        result.providerID = text(source, "id");
        if (result.providerID.empty() && type != "session") result.providerID = fallbackID;
        result.chainID = text(source, "id"); result.chainParentID = text(source, "parentId");
        result.parentField = source.at_key("parentId").error() != simdjson::NO_SUCH_FIELD;
        result.chainEntry = type != "session" && get(source, "id").is_string();
        result.chainUnproven = !unique(source) || result.chainID.size() > 256 || result.chainParentID.size() > 256 ||
            (type == "session" && !validID(source, "id")) ||
            (result.parentField && !get(source, "parentId").is_null() && !get(source, "parentId").is_string());
        const auto entry = get(source, "message"); const auto role = text(entry, "role");
        bool valid = true;
        if (type == "message") {
            valid = unique(entry) && get(entry, "role").is_string();
            if (role == "user" || role == "assistant") {
                valid &= validContent(get(entry, "content"));
                for (const auto key : {"stopReason", "errorMessage"})
                    valid &= entry.at_key(key).error() == simdjson::NO_SUCH_FIELD || get(entry, key).is_string();
            } else if (role == "toolResult") {
                valid &= validID(entry, "toolCallId") && validContent(get(entry, "content")) && optionalBool(entry, "isError");
            } else if (role == "bashExecution") {
                valid &= get(entry, "command").is_string() && get(entry, "output").is_string() &&
                    optionalBool(entry, "cancelled") && optionalBool(entry, "truncated");
                valid &= get(entry, "exitCode").is_null() || get(entry, "exitCode").is_int64();
            } else if (role == "custom" || role == "hookMessage") {
                valid &= get(entry, "display").is_bool() && validContent(get(entry, "content"));
            } else if (role == "branchSummary" || role == "compactionSummary") valid &= get(entry, "summary").is_string();
        } else if (type == "custom_message") {
            valid = get(source, "display").is_bool() && validContent(get(source, "content"));
        } else if (type == "compaction" || type == "branch_summary") valid = get(source, "summary").is_string();
        if (!valid) {
            out.string("type", "unknown"); out.string("sourceType", "invalid-pi/" + type + "/" + role, 256);
            out.number("unparsedContentCount", 1); out.boolean("truncated", cut);
            result.json = out.finish(); result.disposition = "unclassified"; result.visible = true;
            return result;
        }
        out.optional("timestamp", text(source, "timestamp"), 128);
        auto addWrapped = [&](const std::string& raw) {
            simdjson::dom::parser parser;
            blocks.add(parser.parse(raw).value());
        };
        auto piContent = [&](Element content) {
            if (!content.is_array()) { blocks.content(content); return; }
            for (const auto part : simdjson::dom::array(content.get_array().value())) {
                if (text(part, "type") == "toolCall") {
                    if (!validID(part, "id") || !validID(part, "name") || !get(part, "arguments").is_object()) {
                        blocks.unsupported("invalid-pi-toolCall"); continue;
                    }
                    json::Object call; call.string("type", "function_call");
                    call.string("call_id", text(part, "id"), 256); call.string("name", text(part, "name"), 256);
                    call.raw("arguments", simdjson::minify(get(part, "arguments")));
                    addWrapped(call.finish());
                } else if (text(part, "type") == "thinking" && json::boolean(part, "redacted") &&
                           !get(part, "thinking").is_string()) {
                    // Intentionally unavailable reasoning is not an unknown
                    // message and must not expose opaque reasoning signatures.
                } else blocks.add(part);
            }
        };
        auto piMessage = [&](const std::string& role, Element content, bool compact = false, const std::string& notice = "") {
            piContent(content);
            if (!notice.empty()) blocks.notice(notice);
            out.string("type", "message"); out.string("role", role);
            out.raw("blocks", json::array(blocks.values));
            if (compact) out.boolean("isCompactSummary", true);
            if (role == "system" && !compact) out.boolean("providerSystemMessage", true);
            result.visible = !blocks.values.empty(); result.disposition = role == "system" ? "system" : "message";
        };
        auto opaqueMetadata = [&](const std::string& reason) {
            out.string("type", "metadata"); out.string("classificationReason", reason, 128);
            result.disposition = "metadata";
        };
        if (type == "session") {
            out.string("type", "session_meta"); out.optional("sessionID", text(source, "id"), 256);
            const auto version = source.at_key("version").error() == simdjson::NO_SUCH_FIELD ? 1 : json::integer(source, "version");
            out.number("sessionVersion", version > 0 ? static_cast<uint64_t>(version) : 0);
            metadata(source); result.disposition = "metadata";
        } else if (type == "message") {
            const auto entry = get(source, "message"); const auto role = text(entry, "role");
            if (role == "user" || role == "assistant") {
                std::string notice;
                if (role == "assistant") {
                    const auto stop = text(entry, "stopReason");
                    notice = text(entry, "errorMessage");
                    if (notice.empty() && stop == "error") notice = "Provider request failed";
                    if (notice.empty() && stop == "aborted") notice = "Response aborted";
                    if (notice.empty() && stop == "length") notice = "Response reached the output limit";
                    out.optional("stopReason", stop, 128);
                }
                piMessage(role, get(entry, "content"), false, notice);
            }
            else if (role == "toolResult") {
                json::Object output; output.string("type", "function_call_output");
                output.string("call_id", text(entry, "toolCallId"), 256);
                output.raw("output", simdjson::minify(get(entry, "content")));
                addWrapped(output.finish());
                if (json::boolean(entry, "isError")) blocks.notice("Tool execution failed");
                out.string("toolStatus", json::boolean(entry, "isError") ? "failed" : "completed");
                out.string("type", "message"); out.string("role", "tool"); out.raw("blocks", json::array(blocks.values));
                result.visible = true; result.disposition = "message";
            } else if (role == "bashExecution") {
                const auto id = result.providerID + "/bash";
                json::Object call; call.string("type", "custom_tool_call"); call.string("call_id", id, 256);
                const auto command = text(entry, "command");
                call.string("name", "bash"); call.string("input", command, command.size()); addWrapped(call.finish());
                json::Object output; output.string("type", "function_call_output"); output.string("call_id", id, 256);
                const auto outputText = text(entry, "output");
                output.string("output", outputText, outputText.size()); addWrapped(output.finish());
                if (!get(entry, "exitCode").is_null()) out.raw("exitCode", simdjson::minify(get(entry, "exitCode")));
                out.string("toolStatus", json::boolean(entry, "cancelled") ? "cancelled" :
                    json::integer(entry, "exitCode") != 0 ? "failed" : "completed");
                if (json::boolean(entry, "cancelled")) blocks.notice("Bash execution cancelled");
                else if (!get(entry, "exitCode").is_null() && json::integer(entry, "exitCode") != 0)
                    blocks.notice("Bash exited with code " + std::to_string(json::integer(entry, "exitCode")));
                out.string("type", "message"); out.string("role", "tool"); out.raw("blocks", json::array(blocks.values));
                cut |= json::boolean(entry, "truncated"); result.visible = true; result.disposition = "message";
            } else if (role == "custom" || role == "hookMessage") {
                if (json::boolean(entry, "display")) piMessage("system", get(entry, "content"));
                else opaqueMetadata("pi-hidden-extension-context");
            } else if (role == "branchSummary" || role == "compactionSummary") {
                piMessage("system", get(entry, "summary"), true);
            } else { out.string("type", "unknown"); out.string("sourceType", "pi-message/" + role, 128); known = false; }
        } else if (type == "compaction" || type == "branch_summary") {
            // Historical display preserves original branch messages. The
            // retainedTail/firstKeptEntryId fields describe MODEL context and
            // are deliberately not replayed as extra authored conversation.
            const auto summaryText = text(source, "summary");
            json::Object part; part.string("type", "text"); part.string("text", summaryText, summaryText.size());
            simdjson::dom::parser parser; const auto summary = parser.parse(part.finish()).value();
            blocks.add(summary, true);
            out.string("type", "message"); out.string("role", "system"); out.boolean("isCompactSummary", true);
            out.raw("blocks", json::array(blocks.values)); result.visible = true; result.disposition = "system";
        } else if (type == "custom_message") {
            if (json::boolean(source, "display")) piMessage("system", get(source, "content"));
            else opaqueMetadata("pi-hidden-extension-context");
        } else if (type == "model_change") {
            opaqueMetadata("pi-model-change"); out.optional("model", text(source, "modelId"), 256);
        } else if (type == "thinking_level_change" || type == "label" || type == "session_info" || type == "custom") {
            opaqueMetadata("pi-" + type);
        } else { out.string("type", "unknown"); out.string("sourceType", "pi/" + type, 128); known = false; result.visible = true; }
    } else if (provider == "claude") {
        result.parentField = source.at_key("parentUuid").error() != simdjson::NO_SUCH_FIELD;
        result.chainID = text(source, "uuid"); result.chainParentID = text(source, "parentUuid");
        result.chainUnproven = result.chainID.size() > 256 || result.chainParentID.size() > 256;
        // These fields select authored membership and ancestry. Unlike an
        // unknown display block, an ambiguous or ill-typed structural field
        // cannot be treated as false/empty without choosing another history.
        const std::set<std::string_view> structural{"type", "uuid", "parentUuid", "isSidechain", "isMeta", "teamName"};
        std::set<std::string_view> seen;
        size_t subtypeFields = 0, logicalFields = 0;
        if (source.is_object()) for (const auto field : simdjson::dom::object(source.get_object().value())) {
            if (structural.count(field.key) && !seen.insert(field.key).second) result.chainUnproven = true;
            subtypeFields += field.key == "subtype"; logicalFields += field.key == "logicalParentUuid";
        }
        if (source.at_key("uuid").error() != simdjson::NO_SUCH_FIELD &&
            (!get(source, "uuid").is_string() || result.chainID.empty())) result.chainUnproven = true;
        if (result.parentField && !get(source, "parentUuid").is_null() && !get(source, "parentUuid").is_string())
            result.chainUnproven = true;
        for (const auto key : {"isSidechain", "isMeta"})
            if (source.at_key(key).error() != simdjson::NO_SUCH_FIELD && !get(source, key).is_bool()) result.chainUnproven = true;
        if (!get(source, "teamName").is_null() && !get(source, "teamName").is_string()) result.chainUnproven = true;
        result.chainEntry = get(source, "uuid").is_string() && (type == "user" || type == "assistant" ||
            type == "progress" || type == "system" || type == "attachment");
        result.chainMessage = type == "user" || type == "assistant";
        result.chainMain = result.chainMessage && !json::boolean(source, "isSidechain") && !json::boolean(source, "isMeta") && text(source, "teamName").empty();
        result.chainSidechain = json::boolean(source, "isSidechain") || !text(source, "teamName").empty();
        // Compaction writes a new root whose logicalParentUuid names the prior
        // history only advisorily (it can name a later record or nothing).
        // Boundary membership and the advisory link therefore never make a
        // transcript unproven: an ambiguous subtype keeps the old root
        // behaviour, and an ill-typed, overlong or duplicated logical link
        // is ignored so the index uses its positional fallback. Either way
        // the index accepts only an effective parent physically before the
        // boundary and stops the path rather than revisit a node, so neither
        // choice can make a readable transcript unproven.
        result.chainCompactBoundary = result.chainEntry && type == "system" && subtypeFields == 1 &&
            get(source, "subtype").is_string() && text(source, "subtype") == "compact_boundary" && result.chainParentID.empty();
        if (result.chainCompactBoundary && logicalFields == 1 && get(source, "logicalParentUuid").is_string()) {
            const auto logical = text(source, "logicalParentUuid");
            if (logical.size() <= 256) result.chainLogicalParentID = logical;
        }
        if (type == "user" || type == "assistant" || type == "system") {
            const auto msg = get(source, "message");
            auto content = get(msg, "content");
            if (content.is_null()) content = firstValue(source, {"content", "text"});
            if (type != "system" && content.is_null()) blocks.unsupported("missing-message-content");
            if (msg.is_object() && msg.at_key("role").error() != simdjson::NO_SUCH_FIELD && !get(msg, "role").is_string())
                blocks.unsupported("invalid-message-role");
            auto role = text(msg, "role");
            if (role.empty()) role = type;
            const bool meta = json::boolean(source, "isMeta");
            const bool compact = json::boolean(source, "isCompactSummary");
            const auto body = content.is_string() ? contentText(content) : "";
            if (meta || compact || starts(body, "<local-command-caveat>") || starts(body, "<command-name>") ||
                starts(body, "<local-command-stdout>") || starts(body, "<task-notification>")) role = "system";
            message(role, content, compact);
            out.boolean("isMeta", meta);
            if (compact) { out.boolean("isCompactSummary", true); result.visible = true; }
            if (!child) out.optional("model", text(msg, "model"), 256);
            // Claude reports occupancy, including both cache families, but
            // does not persist the context window (including the 1M beta).
            // Keep usage on the message without changing display/chain state.
            const auto usage = get(msg, "usage");
            if (type == "assistant" && result.chainMain && !result.chainUnproven && !child && usage.is_object()) {
                constexpr uint64_t maximum = (uint64_t(1) << 53) - 1;
                uint64_t tokens = 0;
                bool valid = true;
                for (const auto* key : {"input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"}) {
                    const auto field = usage.at_key(key);
                    if (field.error() == simdjson::NO_SUCH_FIELD) continue;
                    uint64_t count = 0;
                    if (field.get_uint64().get(count) || count > maximum - tokens) { valid = false; break; }
                    tokens += count;
                }
                // Synthetic placeholders (API errors, interrupts) carry zero
                // usage; reporting them would erase the real occupancy.
                if (valid && tokens > 0 && text(msg, "model") != "<synthetic>") out.number("used_tokens", tokens);
            }
        } else if (type == "ai-title" || type == "custom-title") {
            out.string("type", "ai-title");
            if (!child) out.optional("title", first(source, {"aiTitle", "customTitle", "title", "text"}), 512);
            result.disposition = "metadata";
        } else if (type == "attachment") {
            // Injected provider context, except a prompt the human typed while
            // a turn was running: Claude persists it as a queued_command, never
            // as a user record. Peer, task-notification and meta commands stay
            // context. Chain fields above keep their attachment classification.
            const auto attachment = get(source, "attachment");
            const auto origin = get(attachment, "origin");
            const auto prompt = get(attachment, "prompt");
            const bool queued = attachment.is_object() && text(attachment, "type") == "queued_command" &&
                (attachment.at_key("commandMode").error() == simdjson::NO_SUCH_FIELD || text(attachment, "commandMode") == "prompt") &&
                !json::boolean(attachment, "isMeta") &&
                (attachment.at_key("origin").error() == simdjson::NO_SUCH_FIELD ||
                    (origin.is_object() && text(origin, "kind") == "human")) &&
                (prompt.is_string() || prompt.is_array());
            if (queued) { message("user", prompt); out.boolean("isMeta", false); }
            else {
                out.string("type", "system"); out.string("text", "Provider context: " + text(attachment, "type"), 256);
                result.disposition = "system";
            }
        } else if (type == "permission-mode" || type == "mode" || type == "cost-state" || type == "queue-operation") {
            out.string("type", type); result.disposition = "metadata";
            if (!child) for (auto key : {"mode", "value", "pending", "count", "totalCostUSD", "totalDuration", "totalLinesAdded", "totalLinesRemoved", "used_tokens", "max_tokens", "context_percent"}) {
                auto value = get(source, key);
                if (value.is_string()) out.string(key, contentText(value), 256);
                else if (value.is_number() || value.is_bool()) out.raw(key, simdjson::minify(value));
            }
        } else if (claudeBookkeeping(source, type)) {
            out.string("type", "system");
            out.string("ignoreReason", "claude-sdk-non-message/" + type, 128);
            result.disposition = "ignored";
        } else {
            out.string("type", type.empty() ? "unknown" : type, 128);
            known = false;
        }
        metadata(source);
        out.optional("timestamp", text(source, "timestamp"), 128);
        out.optional("sessionID", first(source, {"sessionId", "session_id"}), 256);
        out.optional("turnID", result.providerID, 256);
    } else if (provider == "codex") {
        const auto auxiliary = type == "event_msg" ? payloadType : type;
        if (auxiliary == "task_started" || auxiliary == "turn_started" || auxiliary == "turn_aborted" ||
            auxiliary == "thread_settings_applied" || auxiliary == "thread_goal_updated" ||
            type == "world_state" || type == "inter_agent_communication_metadata" || type == "token_usage_record") {
            if (!codexAuxiliary(source, auxiliary)) {
                out.string("type", "unknown"); out.string("sourceType", auxiliary, 128); known = false;
            } else if (auxiliary == "thread_settings_applied") {
                out.string("type", "turn_context"); metadata(get(payload, "thread_settings")); result.disposition = "metadata";
            } else if (auxiliary == "task_started" || auxiliary == "turn_started" || auxiliary == "turn_aborted") {
                out.string("type", "system");
                out.string("text", auxiliary == "turn_aborted" ? "Turn interrupted: " + text(payload, "reason") : "Turn started");
                out.optional("turnID", text(payload, "turn_id"), 256); result.disposition = "status";
            } else if (auxiliary == "thread_goal_updated") {
                const auto goal = get(payload, "goal"); out.string("type", "system");
                const auto display = "Goal " + text(goal, "status") + ": " + text(goal, "objective");
                cut |= display.size() > 8192;
                out.string("text", display); result.disposition = "status";
            } else if (type == "token_usage_record") {
                // Request/turn/lifetime totals are NOT current context usage.
                // Preserve their distinct numeric families without inventing
                // used_tokens or a dollar cost for the client summary.
                out.string("type", "cost-state");
                for (const auto key : {"usage", "turn_token_usage", "thread_token_usage"}) out.raw(key, simdjson::minify(get(payload, key)));
                result.disposition = "metadata";
            } else {
                out.string("type", "metadata"); out.string("classificationReason", "codex-resume-state/" + type, 128);
                result.disposition = "metadata";
            }
        } else if (type == "response_item") {
            if (payloadType == "message" || payloadType == "user_message" || payloadType == "agent_message") {
                auto role = text(payload, "role");
                if (role.empty()) role = payloadType == "user_message" ? "user" : "assistant";
                auto content = firstValue(payload, {"content", "message", "text"});
                const auto annotation = get(payload, "internal_chat_message_metadata_passthrough");
                auto kinds = get(annotation, "content_item_kinds");
                const bool annotated = annotation.is_object() && annotation.at_key("content_item_kinds").error() != simdjson::NO_SUCH_FIELD;
                const bool invalidAnnotation = !annotation.is_null() && !annotation.is_object();
                bool validKinds = kinds.is_array() && content.is_array() &&
                    kinds.get_array().value().size() == content.get_array().value().size();
                if (validKinds) for (auto kind : simdjson::dom::array(kinds.get_array().value())) validKinds &= kind.is_string();
                if (role == "user" && (invalidAnnotation || (annotated && !validKinds))) {
                    // A broken positional annotation cannot authorize any
                    // particular fragment as human input. Keep an explicit
                    // diagnostic, not injected context mislabeled as a user.
                    blocks.unsupported("invalid-content-item-kinds");
                    role = "system"; content = get(payload, "__tessera_missing__");
                } else if (role == "user" && validKinds && kinds.get_array().value().size()) {
                    bool human = false;
                    for (auto kind : simdjson::dom::array(kinds.get_array().value())) { std::string_view name; if (!kind.get_string().get(name) && name.substr(0, 5) == "user.") human = true; }
                    if (!human) role = "system";
                    else if (content.is_array() && content.get_array().value().size() == kinds.get_array().value().size()) {
                        std::vector<bool> selected;
                        for (auto kind : simdjson::dom::array(kinds.get_array().value())) {
                            std::string_view label;
                            selected.push_back(!kind.get_string().get(label) && label.substr(0, 5) == "user.");
                        }
                        blocks.content(content, false, &selected);
                        out.string("type", "message"); out.string("role", role); out.raw("blocks", json::array(blocks.values));
                        result.visible = true; result.disposition = "message";
                    }
                }
                if (result.disposition.empty()) message(role, content);
            } else if (payloadType == "reasoning") {
                message("assistant", payload);
            } else if (payloadType == "function_call" || payloadType == "custom_tool_call" ||
                       payloadType == "function_call_output" || payloadType == "custom_tool_call_output" ||
                       payloadType == "tool_search_call" || payloadType == "tool_search_output" || payloadType == "web_search_call") message("tool", payload);
            else { out.string("type", "unknown"); out.string("sourceType", payloadType, 128); known = false; }
        } else if (type == "compacted" || (type == "event_msg" && payloadType == "context_compacted")) {
            json::Object block;
            block.string("type", "compact-summary");
            const auto summary = text(payload, "message");
            block.string("text", summary.empty() ? "Context compacted" : summary);
            out.string("type", "message"); out.string("role", "system"); out.boolean("isCompactSummary", true);
            out.raw("blocks", "[" + block.finish() + "]"); result.visible = true; result.disposition = "system";
        } else if (type == "event_msg" && (payloadType == "task_complete" || payloadType == "task_completed")) {
            out.string("type", "completion"); out.string("summary", first(payload, {"last_agent_message", "message"})); result.disposition = "status";
        } else if (type == "event_msg" && payloadType == "token_count") {
            auto info = get(payload, "info"); if (!info.is_object()) info = payload;
            auto usage = firstValue(info, {"last_token_usage", "total_token_usage"}); if (!usage.is_object()) usage = info;
            out.string("type", "cost-state");
            if (!child) {
                out.optional("model", text(info, "model"), 256);
                const auto input = std::max<int64_t>(0, json::integer(usage, "input_tokens"));
                const auto output = std::max<int64_t>(0, json::integer(usage, "output_tokens"));
                out.number("used_tokens", static_cast<uint64_t>(input) + static_cast<uint64_t>(output));
                if (get(info, "model_context_window").is_number())
                    out.number("max_tokens", static_cast<uint64_t>(std::max<int64_t>(0, json::integer(info, "model_context_window"))));
            }
            result.disposition = "metadata";
        } else if (type == "session_meta" || type == "turn_context") {
            out.string("type", type); metadata(payload);
            if (!child && first(payload, {"gitBranch", "branch"}).empty()) out.optional("branch", text(get(payload, "git"), "branch"), 512);
            result.disposition = "metadata";
        } else { out.string("type", "unknown"); out.string("sourceType", payloadType.empty() ? type : payloadType, 128); known = false; }
        out.optional("timestamp", text(source, "timestamp"), 128);
    } else {
        out.string("type", "unknown"); out.string("sourceType", type, 128); known = false;
    }
    if (child) out.boolean("isSidechain", true);
    out.boolean("truncated", cut || blocks.truncated);
    // This survives preview eviction, so an unknown block cannot disappear
    // from diagnostics merely because it fell outside the bounded UI slice.
    if (blocks.unparsedContent) out.number("unparsedContentCount", blocks.unparsedContent);
    if (!known) result.disposition = "unclassified";
    result.json = out.finish();
    return result;
}

NormalizedRecord normalizeCodexCoreItem(Element item, const std::string& turnID, bool cut) {
    // Port of CoreTurnItem -> ThreadItem's display-field conversion, not an
    // alternative JSONL history reducer. See the pinned upstream conversion
    // reference in the implementation ledger. Never lowercase arbitrary tags.
    const auto kind = text(item, "type");
    std::string type;
    for (const auto& pair : std::initializer_list<std::pair<const char*, const char*>>{
        {"UserMessage", "userMessage"}, {"AgentMessage", "agentMessage"}, {"Reasoning", "reasoning"},
        {"Plan", "plan"}, {"CommandExecution", "commandExecution"}, {"FileChange", "fileChange"},
        {"McpToolCall", "mcpToolCall"}, {"DynamicToolCall", "dynamicToolCall"},
        {"CollabAgentToolCall", "collabAgentToolCall"}, {"SubAgentActivity", "subAgentActivity"},
        {"WebSearch", "webSearch"}, {"ImageView", "imageView"}, {"ImageGeneration", "imageGeneration"},
        {"ContextCompaction", "contextCompaction"}, {"HookPrompt", "hookPrompt"},
        {"EnteredReviewMode", "enteredReviewMode"}, {"ExitedReviewMode", "exitedReviewMode"}}) if (kind == pair.first) type = pair.second;
    if (kind == "Extension") {
        const auto extension = text(item, "kind");
        if (extension == "web.search") type = "webSearch";
        else if (extension == "clock.sleep") type = "sleep";
        else if (extension == "image_gen.generation") type = "imageGeneration";
    }
    auto uniqueObject = [](Element object) {
        if (!object.is_object()) return false;
        std::set<std::string_view> keys;
        for (const auto field : simdjson::dom::object(object.get_object().value())) if (!keys.insert(field.key).second) return false;
        return true;
    };
    bool invalid = type.empty() || !uniqueObject(item) || !get(item, "id").is_string() ||
        text(item, "id").empty() || text(item, "id").size() > 256;
    for (const auto key : {"text", "path", "query", "tool", "revisedPrompt", "savedPath", "revised_prompt", "saved_path",
                           "aggregated_output", "prompt", "agent_path", "kind", "user_facing_hint", "status"}) {
        const auto value = get(item, key);
        if (!value.is_null() && !value.is_string()) invalid = true;
    }
    if (type == "sleep" && !get(item, "durationMs").is_uint64()) invalid = true;
    for (const auto& required : std::initializer_list<std::pair<const char*, const char*>>{
        {"plan", "text"}, {"imageView", "path"}, {"webSearch", "query"}, {"subAgentActivity", "agent_path"},
        {"collabAgentToolCall", "tool"}, {"mcpToolCall", "tool"}, {"dynamicToolCall", "tool"},
        {"enteredReviewMode", "user_facing_hint"}})
        if (type == required.first && !get(item, required.second).is_string()) invalid = true;
    if (type == "mcpToolCall") {
        const auto value = get(item, "result"), error = get(item, "error");
        if (!value.is_null() && (!uniqueObject(value) || !get(value, "content").is_array())) invalid = true;
        if (!error.is_null() && (!uniqueObject(error) || !get(error, "message").is_string())) invalid = true;
    }
    if (type == "dynamicToolCall") {
        const auto content = get(item, "content_items"), error = get(item, "error");
        if (!content.is_null() && !content.is_array()) invalid = true;
        if (!error.is_null() && !error.is_string()) invalid = true;
    }
    if (type == "collabAgentToolCall" && !get(item, "agents_states").is_null() && !uniqueObject(get(item, "agents_states"))) invalid = true;
    if (type == "hookPrompt") {
        const auto fragments = get(item, "fragments");
        if (!fragments.is_array()) invalid = true;
        else for (const auto fragment : simdjson::dom::array(fragments.get_array().value())) {
            if (!uniqueObject(fragment) || !get(fragment, "text").is_string() || !get(fragment, "hookRunId").is_string()) invalid = true;
            if (fragment.is_object()) for (const auto field : simdjson::dom::object(fragment.get_object().value()))
                if (field.key != "text" && field.key != "hookRunId") invalid = true;
        }
    }
    json::Object converted;
    auto copy = [&](const char* from, const char* to) {
        const auto value = get(item, from);
        if (!value.is_null()) converted.raw(to, simdjson::minify(value));
    };
    auto camel = [](const std::string& value) {
        std::string result; bool upper = false;
        for (char byte : value) {
            if (byte == '_') { upper = true; continue; }
            result += upper && byte >= 'a' && byte <= 'z' ? byte - 'a' + 'A' : byte; upper = false;
        }
        return result;
    };
    copy("id", "id");
    if (type == "userMessage") {
        const auto content = get(item, "content");
        std::vector<std::string> parts;
        if (!content.is_array()) invalid = true;
        else for (const auto part : simdjson::dom::array(content.get_array().value())) {
            const auto tag = text(part, "type");
            if (!get(part, "type").is_string() ||
                (tag != "text" && tag != "image" && tag != "local_image" && tag != "audio" &&
                 tag != "local_audio" && tag != "skill" && tag != "mention")) {
                invalid = true; continue;
            }
            json::Object value;
            const auto convertedTag = tag == "local_image" ? "localImage" : tag == "local_audio" ? "localAudio" : tag;
            value.string("type", convertedTag, 128);
            if (!uniqueObject(part)) { invalid = true; continue; }
            for (const auto field : simdjson::dom::object(part.get_object().value())) {
                if (field.key == "type") continue;
                // Text-element byte spans do not change authored text. The
                // public renderer does not currently consume them.
                const auto key = field.key == "image_url" || field.key == "audio_url" ? std::string_view("url") : field.key;
                value.raw(key, simdjson::minify(field.value));
            }
            parts.push_back(value.finish());
        }
        converted.raw("content", json::array(parts));
    } else if (type == "agentMessage") {
        const auto content = get(item, "content");
        std::string body;
        if (!content.is_array()) invalid = true;
        else for (const auto part : simdjson::dom::array(content.get_array().value())) {
            if (!uniqueObject(part) || text(part, "type") != "Text" || !get(part, "text").is_string()) { invalid = true; continue; }
            body += text(part, "text");
        }
        // Fragments join with NO inserted separator, as in upstream.
        converted.string("text", body, body.size());
    } else if (type == "reasoning") {
        copy("summary_text", "summary"); copy("raw_content", "content");
        for (const auto key : {"summary_text", "raw_content"}) {
            const auto value = get(item, key);
            if (value.is_null() && std::string_view(key) == "raw_content") continue;
            if (!value.is_array()) invalid = true;
            else for (const auto part : simdjson::dom::array(value.get_array().value())) if (!part.is_string()) invalid = true;
        }
    } else if (type == "commandExecution") {
        const auto command = get(item, "command");
        std::string body;
        if (!command.is_array()) invalid = true;
        else for (const auto argument : simdjson::dom::array(command.get_array().value())) {
            if (!argument.is_string()) { invalid = true; continue; }
            const auto value = std::string(argument.get_string().value());
            if (!body.empty()) body += ' ';
            if (value.find('\0') != std::string::npos) { body = "<command included NUL byte>"; break; }
            body += codexQuoteArgument(value);
        }
        converted.string("command", body, body.size()); copy("aggregated_output", "aggregatedOutput");
    } else if (type == "fileChange") {
        const auto changes = get(item, "changes");
        std::map<std::string, std::string> sorted;
        if (!changes.is_object()) invalid = true;
        else for (const auto change : simdjson::dom::object(changes.get_object().value())) {
            if (!uniqueObject(change.value)) { invalid = true; continue; }
            const auto tag = text(change.value, "type");
            const auto field = tag == "add" || tag == "delete" ? "content" : tag == "update" ? "unified_diff" : nullptr;
            if (!field || !get(change.value, field).is_string()) { invalid = true; continue; }
            auto diff = text(change.value, field);
            const auto moved = get(change.value, "move_path");
            if (!moved.is_null() && !moved.is_string()) { invalid = true; continue; }
            if (moved.is_string()) diff += "\n\nMoved to: " + std::string(moved.get_string().value());
            json::Object value; value.string("path", change.key, change.key.size()); value.string("diff", diff, diff.size());
            if (!sorted.emplace(std::string(change.key), value.finish()).second) invalid = true;
        }
        std::vector<std::string> values; for (const auto& value : sorted) values.push_back(value.second);
        converted.raw("changes", json::array(values));
    } else if (type == "collabAgentToolCall") {
        converted.string("tool", camel(text(item, "tool")), 128);
        copy("prompt", "prompt"); copy("agents_states", "agentsStates");
    } else if (type == "subAgentActivity") {
        copy("agent_path", "agentPath"); copy("kind", "kind");
    } else if (type == "imageView") {
        const auto path = codexDisplayPath(text(item, "path")); converted.string("path", path, path.size());
    } else if (type == "imageGeneration" && kind != "Extension") {
        copy("revised_prompt", "revisedPrompt"); copy("saved_path", "savedPath");
    } else if (type == "enteredReviewMode") copy("user_facing_hint", "review");
    else if (type == "exitedReviewMode") {
        const auto review = codexReviewDisplay(get(item, "review_output"));
        if (!review) invalid = true;
        else { cut |= review->size() > 16384; converted.string("review", *review, 16384); }
    } else if (type == "dynamicToolCall") copy("content_items", "contentItems");
    // Already-public extension/MCP fields and shared display fields retain
    // exact JSON values. Arbitrary tool arguments are data, never tag maps.
    for (const auto key : {"text", "path", "query", "results", "tool", "arguments", "result", "error", "fragments",
                           "revisedPrompt", "savedPath", "failure", "durationMs", "questions"})
        if (!converted.keys.count(key)) copy(key, key);
    const auto status = text(item, "status");
    if (!status.empty()) converted.string("status", camel(status), 128);
    converted.string("type", invalid ? "invalidCoreTurnItem" : type, 128);
    simdjson::dom::parser parser;
    const auto raw = converted.finish();
    auto result = normalizeCodexItem(parser.parse(raw).value(), turnID, cut);
    result.sourceType = "core-item/" + kind;
    return result;
}

NormalizedRecord normalizeCodexItem(Element item, const std::string& turnID, bool cut) {
    NormalizedRecord result;
    const auto type = text(item, "type");
    result.sourceType = "app-server/" + type;
    result.providerID = text(item, "id");
    json::Object out;
    out.string("provider", "codex"); out.string("type", "message"); out.optional("turnID", turnID, 256);
    out.optional("providerItemID", result.providerID, 256); out.optional("toolStatus", text(item, "status"), 128);
    Blocks blocks;
    simdjson::dom::parser syntheticParser;
    auto add = [&](const std::string& raw) {
        Element value;
        if (!syntheticParser.parse(raw).get(value)) blocks.add(value);
    };
    auto textBlock = [&](const char* kind, const std::string& body) {
        cut |= body.size() > 16384;
        json::Object value; value.string("type", kind); value.string("text", body, 16384); add(value.finish());
    };
    auto tool = [&](const std::string& name, const std::string& arguments) {
        cut |= name.size() > 256 || arguments.size() > 16384;
        json::Object call; call.string("type", "function_call"); call.string("name", name, 256);
        call.string("call_id", result.providerID, 256); call.string("arguments", arguments, 16384); add(call.finish());
    };
    auto output = [&](const std::string& body) {
        if (body.empty()) return;
        cut |= body.size() > 16384;
        json::Object value; value.string("type", "function_call_output"); value.string("call_id", result.providerID, 256);
        value.string("output", body, 16384); add(value.finish());
    };
    auto toolContent = [&](Element content) {
        auto partContent = [&](Element part) {
            const auto kind = text(part, "type");
            if (kind == "text" || kind == "input_text" || kind == "inputText" || part.is_string()) {
                if (!part.is_string() && !get(part, "text").is_string()) blocks.unsupported("invalid-tool-text");
                else output(part.is_string() ? contentText(part) : text(part, "text"));
            } else if (kind == "image" || kind == "input_image" || kind == "inputImage" ||
                       kind == "audio" || kind == "input_audio" || kind == "inputAudio") {
                const auto urlKey = kind == "input_image" ? "image_url" : kind == "input_audio" ? "audio_url" :
                    kind == "inputImage" ? "imageUrl" : kind == "inputAudio" ? "audioUrl" : nullptr;
                if (urlKey && !get(part, urlKey).is_string()) { blocks.unsupported("invalid-" + kind); return; }
                if (!urlKey && (!get(part, "data").is_string() || !get(part, "mimeType").is_string())) {
                    blocks.unsupported("invalid-" + kind); return;
                }
                json::Object attachment;
                attachment.string("type", kind.find("udio") != std::string::npos ? "audio" : "image");
                add(attachment.finish());
            } else if (kind == "encrypted_content") {
                if (!get(part, "encrypted_content").is_string()) blocks.unsupported("invalid-encrypted-content");
                else blocks.add(part);
            } else if (kind == "resource" || kind == "resource_link") {
                json::Object attachment; attachment.string("type", "attachment");
                const auto resource = kind == "resource" ? get(part, "resource") : part;
                if (!resource.is_object() || !get(resource, "uri").is_string() ||
                    (kind == "resource" && !get(resource, "text").is_string() && !get(resource, "blob").is_string()) ||
                    (!get(resource, "mimeType").is_null() && !get(resource, "mimeType").is_string())) {
                    blocks.unsupported("invalid-" + kind); return;
                }
                attachment.string("name", first(resource, {"name", "uri"}), 512);
                attachment.string("media_type", text(resource, "mimeType"), 128); add(attachment.finish());
                output(text(resource, "text"));
            } else blocks.unsupported(kind.empty() ? "invalid-tool-content" : kind);
        };
        if (content.is_array()) for (const auto part : simdjson::dom::array(content.get_array().value())) partContent(part);
        else if (!content.is_null()) partContent(content);
    };
    std::string role = "assistant";
    bool known = true;
    auto enumField = [&](const char* key, std::initializer_list<const char*> values) {
        if (get(item, key).is_null()) return;
        const auto actual = text(item, key);
        if (std::none_of(values.begin(), values.end(), [&](const char* value) { return actual == value; }))
            blocks.unsupported(std::string("invalid-") + type + "-" + key);
    };
    if (type == "commandExecution") enumField("status", {"inProgress", "completed", "failed", "declined"});
    if (type == "mcpToolCall" || type == "dynamicToolCall") enumField("status", {"inProgress", "completed", "failed"});
    if (type == "collabAgentToolCall") {
        enumField("status", {"inProgress", "completed", "failed", "interrupted"});
        enumField("tool", {"spawnAgent", "sendInput", "resumeAgent", "wait", "closeAgent", "sendMessage", "followupTask", "interruptAgent", "listAgents"});
        if (!get(item, "agentsStates").is_null() && !get(item, "agentsStates").is_object()) blocks.unsupported("invalid-agents-states");
    }
    if (type == "subAgentActivity") enumField("kind", {"started", "interacted", "interrupted", "completed"});
    if (type == "userMessage") {
        role = "user";
        const auto content = get(item, "content");
        if (!content.is_array()) blocks.unsupported("invalid-user-content");
        else for (const auto part : simdjson::dom::array(content.get_array().value())) {
            const auto kind = text(part, "type");
            if (!get(part, "type").is_string() ||
                (kind != "text" && kind != "image" && kind != "localImage" && kind != "audio" &&
                 kind != "localAudio" && kind != "skill" && kind != "mention")) {
                blocks.unsupported("invalid-user-content-type"); continue;
            }
            const auto field = kind == "image" || kind == "audio" ? "url" :
                kind == "localImage" || kind == "localAudio" || kind == "skill" || kind == "mention" ? "path" : nullptr;
            if (field && !get(part, field).is_string()) blocks.unsupported("invalid-" + kind);
            else blocks.add(part);
        }
    }
    else if (type == "agentMessage" || type == "plan") {
        if (!get(item, "text").is_string()) blocks.unsupported("invalid-" + type + "-text");
        else textBlock("text", text(item, "text"));
        const auto questions = get(item, "questions");
        if (!questions.is_null() && !questions.is_array()) blocks.unsupported("invalid-questions");
        if (questions.is_array()) for (auto question : simdjson::dom::array(questions.get_array().value())) {
            // Observational display only. The helper never answers questions
            // or turns transcript content into a terminal/action capability.
            if (!get(question, "title").is_string()) { blocks.unsupported("invalid-question-title"); continue; }
            textBlock("text", text(question, "title"));
            const auto options = get(question, "options");
            if (!options.is_null() && !options.is_array()) blocks.unsupported("invalid-question-options");
            if (options.is_array()) for (auto option : simdjson::dom::array(options.get_array().value())) {
                if (!option.is_string() && !firstValue(option, {"label", "title"}).is_string()) {
                    blocks.unsupported("invalid-question-option"); continue;
                }
                textBlock("text", option.is_string() ? contentText(option) : first(option, {"label", "title"}));
            }
        }
    }
    else if (type == "reasoning") {
        auto body = blocks.reasoningText(get(item, "summary"));
        auto details = blocks.reasoningText(get(item, "content"));
        if (!details.empty()) body += (body.empty() ? "" : "\n") + details;
        textBlock("thinking", body);
    } else if (type == "commandExecution") {
        if (!get(item, "command").is_string()) blocks.unsupported("invalid-command");
        if (!get(item, "aggregatedOutput").is_null() && !get(item, "aggregatedOutput").is_string()) blocks.unsupported("invalid-command-output");
        role = "tool"; tool("Command", text(item, "command")); output(text(item, "aggregatedOutput"));
    } else if (type == "functionCallOutput") {
        role = "tool";
        const auto content = get(item, "output");
        if (!content.is_string() && !content.is_array()) blocks.unsupported("invalid-function-output");
        else toolContent(content);
    } else if (type == "fileChange") {
        role = "tool";
        const auto changes = get(item, "changes");
        if (!changes.is_array()) blocks.unsupported("invalid-file-changes");
        if (changes.is_array()) for (auto change : simdjson::dom::array(changes.get_array().value())) {
            if (!get(change, "path").is_string() || !get(change, "diff").is_string()) {
                blocks.unsupported("invalid-file-change"); continue;
            }
            json::Object value; value.string("type", "edit"); value.string("path", text(change, "path"), 512);
            value.string("diff", text(change, "diff"), 16384); add(value.finish());
        }
    } else if (type == "mcpToolCall" || type == "dynamicToolCall") {
        role = "tool"; tool(text(item, "tool"), preview(get(item, "arguments")));
        if (type == "mcpToolCall") {
            const auto value = get(item, "result");
            if (!value.is_null() && (!value.is_object() || !get(value, "content").is_array())) blocks.unsupported("invalid-mcp-result");
            else toolContent(get(value, "content"));
        }
        else {
            const auto content = get(item, "contentItems");
            if (!content.is_null() && !content.is_array()) blocks.unsupported("invalid-dynamic-content");
            else toolContent(content);
        }
        const auto error = get(item, "error");
        if (!error.is_null() && (type == "dynamicToolCall" ? !error.is_string() :
            !error.is_object() || !get(error, "message").is_string())) blocks.unsupported("invalid-tool-error");
        else output(preview(error));
    } else if (type == "collabAgentToolCall") {
        role = "tool"; tool(text(item, "tool"), text(item, "prompt")); output(preview(get(item, "agentsStates")));
    } else if (type == "webSearch") {
        role = "tool"; tool("Web search", text(item, "query")); output(preview(get(item, "results")));
    } else if (type == "imageView" || type == "imageGeneration") {
        role = "tool"; tool(type == "imageView" ? "View image" : "Generate image", first(item, {"path", "revisedPrompt", "savedPath"}));
        json::Object attachment; attachment.string("type", "image"); add(attachment.finish());
        output(preview(get(item, "failure")));
    } else if (type == "sleep") {
        role = "tool";
        if (!get(item, "durationMs").is_uint64()) blocks.unsupported("invalid-sleep-duration");
        else tool("Wait", std::to_string(get(item, "durationMs").get_uint64().value()) + " ms");
    }
    else if (type == "contextCompaction") {
        role = "system"; out.boolean("isCompactSummary", true);
        json::Object value; value.string("type", "text"); value.string("text", "Context compacted");
        Element block; if (!syntheticParser.parse(value.finish()).get(block)) blocks.add(block, true);
    } else if (type == "enteredReviewMode" || type == "exitedReviewMode") {
        role = "system"; textBlock("text", type + ": " + text(item, "review"));
    } else if (type == "subAgentActivity") {
        role = "system"; out.boolean("isSidechain", true);
        textBlock("text", "Subagent " + text(item, "agentPath") + ": " + text(item, "kind"));
    } else if (type == "hookPrompt") {
        role = "system"; out.boolean("isMeta", true);
        const auto fragments = get(item, "fragments");
        bool valid = fragments.is_array();
        if (fragments.is_array()) for (const auto fragment : simdjson::dom::array(fragments.get_array().value())) {
            if (!fragment.is_object() || !get(fragment, "text").is_string() || !get(fragment, "hookRunId").is_string()) valid = false;
            if (fragment.is_object()) {
                std::set<std::string_view> keys;
                for (const auto field : simdjson::dom::object(fragment.get_object().value()))
                    if (!keys.insert(field.key).second || (field.key != "text" && field.key != "hookRunId")) valid = false;
            }
        }
        if (!valid) blocks.unsupported("invalid-hook-fragments");
        else textBlock("text", contentText(fragments));
    } else { known = false; blocks.unsupported(type); }
    out.string("role", role); out.raw("blocks", json::array(blocks.values)); out.boolean("truncated", cut || blocks.truncated);
    if (blocks.unparsedContent) out.number("unparsedContentCount", blocks.unparsedContent);
    result.visible = role != "system" || type == "contextCompaction";
    result.disposition = known ? result.visible ? "message" : "system" : "unclassified";
    result.json = out.finish(); return result;
}
}
