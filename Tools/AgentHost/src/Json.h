#pragma once
#include <simdjson.h>
#include <string>
#include <string_view>
#include <vector>
#include <set>

namespace tessera::json {
// C++17 range-for must own its dom::array/object copy. A range expression
// ending in get_array().value() references a destroyed simdjson_result.
std::string quote(std::string_view value, size_t limit = 8192);
std::string text(simdjson::dom::element value, const char* field);
simdjson::dom::element get(simdjson::dom::element value, const char* field);
bool boolean(simdjson::dom::element value, const char* field);
int64_t integer(simdjson::dom::element value, const char* field);
struct Object {
    std::string data = "{";
    std::set<std::string> keys;
    void raw(std::string_view key, std::string_view value);
    void string(std::string_view key, std::string_view value, size_t limit = 8192);
    void optional(std::string_view key, std::string_view value, size_t limit = 8192);
    void boolean(std::string_view key, bool value);
    void number(std::string_view key, uint64_t value);
    std::string finish() const { return data + "}"; }
};
std::string displayText(std::string_view value, size_t maximum = 16384);
std::string array(const std::vector<std::string>& values);
std::string transcriptPath(std::string_view reference);
std::string openCodeSessionLocator(std::string_view reference);
}
