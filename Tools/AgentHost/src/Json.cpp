#include "Json.h"
#include "PlainASCII.h"
#include <algorithm>
#include <stdexcept>

namespace tessera::json {
static std::string decodeReference(std::string_view reference) {
    if (reference.empty() || reference.size() > 4096) throw std::runtime_error("sourceNotAuthorized");
    if (reference[0] == '/') return std::string(reference);
    // Existing lifecycle OSC carries a URL-safe, unpadded path locator. This
    // is discovery input, not filesystem authority; Catalog still validates
    // the decoded path against fixed provider roots and secure openat walks.
    constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string result;
    unsigned bits = 0, value = 0;
    for (char c : reference) {
        const auto digit = alphabet.find(c);
        if (digit == std::string_view::npos) throw std::runtime_error("sourceNotAuthorized");
        value = (value << 6) | static_cast<unsigned>(digit); bits += 6;
        if (bits >= 8) { bits -= 8; result += static_cast<char>((value >> bits) & 255); }
        if (result.size() > 2048) throw std::runtime_error("sourceNotAuthorized");
    }
    if (bits == 6 || (bits && (value & ((1u << bits) - 1))) || result.empty())
        throw std::runtime_error("sourceNotAuthorized");
    return result;
}
std::string transcriptPath(std::string_view reference) {
    auto result = decodeReference(reference);
    if (result[0] != '/') throw std::runtime_error("sourceNotAuthorized");
    return result;
}
std::string openCodeSessionLocator(std::string_view reference) {
    const auto result = decodeReference(reference);
    if (result.rfind("opencode:", 0) != 0) throw std::runtime_error("sourceNotAuthorized");
    return result.substr(9);
}
std::string quote(std::string_view value, size_t limit) {
    size_t end = std::min(limit, value.size());
    while (end && end < value.size() && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) --end;
    if (end) {
        size_t start = end - 1;
        while (start && (static_cast<unsigned char>(value[start]) & 0xc0) == 0x80) --start;
        const auto lead = static_cast<unsigned char>(value[start]);
        const size_t width = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        if (start + width > end) end = start;
    }
    std::string output = "\"";
    output.reserve(end + 2);
    for (size_t offset = 0; offset < end;) {
        const auto length = detail::plainASCII(value.substr(offset, end - offset));
        if (length) { output.append(value.substr(offset, length)); offset += length; continue; }
        const auto c = static_cast<unsigned char>(value[offset++]);
        if (c == '"' || c == '\\') { output += '\\'; output += static_cast<char>(c); }
        else if (c < 0x20) {
            output += "\\u00";
            output += "0123456789abcdef"[c >> 4]; output += "0123456789abcdef"[c & 15];
        } else output += static_cast<char>(c);
    }
    return output + '"';
}
simdjson::dom::element get(simdjson::dom::element value, const char* field) {
    struct NullValue {
        simdjson::dom::parser parser;
        simdjson::dom::element value;
        NullValue() { (void)parser.parse("null", 4).get(value); }
    };
    static NullValue null;
    simdjson::dom::element result;
    if (value[field].get(result)) return null.value;
    return result;
}
std::string text(simdjson::dom::element value, const char* field) {
    std::string_view result;
    if (value[field].get_string().get(result)) return {};
    return std::string(result);
}
bool boolean(simdjson::dom::element value, const char* field) {
    bool result = false;
    return !value[field].get_bool().get(result) && result;
}
int64_t integer(simdjson::dom::element value, const char* field) {
    int64_t result = 0;
    (void)value[field].get_int64().get(result);
    return result;
}
void Object::raw(std::string_view key, std::string_view value) {
    if (!keys.emplace(key).second) return;
    if (data.size() > 1) data += ',';
    data += quote(key); data += ':'; data += value;
}
std::string displayText(std::string_view value, size_t maximum) {
    std::string result;
    result.reserve(std::min(value.size(), maximum));
    for (size_t index = 0; index < value.size();) {
        const auto byte = static_cast<unsigned char>(value[index]);
        const size_t length = byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
        if (index + length > value.size()) break;
        uint32_t code = byte & (length == 1 ? 0x7f : length == 2 ? 0x1f : length == 3 ? 0x0f : 0x07);
        for (size_t n = 1; n < length; ++n) code = (code << 6) | (static_cast<unsigned char>(value[index + n]) & 0x3f);
        const bool unsafe = (code < 32 && code != 9 && code != 10) || (code >= 0x7f && code <= 0x9f) ||
            code == 0x061c || code == 0x200e || code == 0x200f || (code >= 0x202a && code <= 0x202e) ||
            (code >= 0x2066 && code <= 0x2069) || code == 0xfeff;
        if (!unsafe) {
            if (result.size() + length > maximum) break;
            result.append(value.substr(index, length));
        }
        index += length;
    }
    return result;
}
void Object::string(std::string_view key, std::string_view value, size_t limit) {
    const bool display = key == "text" || key == "title" || key == "detail" || key == "summary" ||
        key == "preview" || key == "label" || key == "name" || key == "model" || key == "branch" ||
        key == "objective" || key == "agentType";
    raw(key, quote(display ? displayText(value, limit) : std::string(value), limit));
}
void Object::optional(std::string_view key, std::string_view value, size_t limit) { if (!value.empty()) string(key, value, limit); }
void Object::boolean(std::string_view key, bool value) { raw(key, value ? "true" : "false"); }
void Object::number(std::string_view key, uint64_t value) { raw(key, std::to_string(value)); }
std::string array(const std::vector<std::string>& values) {
    std::string result = "[";
    for (const auto& value : values) { if (result.size() > 1) result += ','; result += value; }
    return result + "]";
}
}
