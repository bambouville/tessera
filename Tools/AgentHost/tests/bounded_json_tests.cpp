#include "BoundedJson.h"
#include "Json.h"
#include <cassert>

int main() {
    for (const auto& fixture : std::vector<std::pair<std::string, std::string>>{
        {"x", "\\u0078"}, {"\n", "\\n"}, {"é", "\\u00e9"}, {"界", "\\u754c"},
        {"😀", "\\ud83d\\ude00"}, {"\\", "\\\\"}, {"/", "\\/"}}) {
        for (const size_t count : {size_t(8192), size_t(16384), size_t(16385)}) {
            std::string decoded, encoded;
            for (size_t i = 0; i < count; ++i) { decoded += fixture.first; encoded += fixture.second; }
            const std::string escaped = "{\"text\":\"" + encoded + "\"}";
            const std::string literal = "{\"text\":" + tessera::json::quote(decoded, decoded.size()) + "}";
            for (const size_t chunk : {size_t(1), size_t(7), size_t(65536)}) {
                tessera::BoundedJson a, b;
                for (size_t i = 0; i < escaped.size(); i += chunk) a.feed(std::string_view(escaped).substr(i, chunk));
                for (size_t i = 0; i < literal.size(); i += chunk) b.feed(std::string_view(literal).substr(i, chunk));
                assert(!a.malformed() && !b.malformed() && !a.unsupported() && !b.unsupported());
                simdjson::dom::parser parserA, parserB;
                const auto left = tessera::json::text(parserA.parse(a.json()).value(), "text");
                const auto right = tessera::json::text(parserB.parse(b.json()).value(), "text");
                assert(left == right);
                const auto bytes = std::min(decoded.size(), tessera::BoundedJson::maximumString);
                assert(left == decoded.substr(0, bytes - bytes % fixture.first.size()));
                assert(a.truncated() == (left != decoded) && b.truncated() == a.truncated());
            }
        }
    }
    for (const size_t size : {size_t(4096), size_t(16384), size_t(16385)}) {
        std::string encoded;
        for (size_t i = 0; i < size; ++i) encoded += "\\u0078";
        tessera::BoundedJson literalKey, escapedKey;
        literalKey.feed("{\"" + std::string(size, 'x') + "\":null}");
        escapedKey.feed("{\"" + encoded + "\":null}");
        assert(!literalKey.malformed() && !escapedKey.malformed());
        assert(literalKey.unsupported() == (size > tessera::BoundedJson::maximumString));
        assert(escapedKey.unsupported() == literalKey.unsupported());
    }
    tessera::BoundedJson malformed;
    malformed.feed("{\"text\":\"" + std::string(20000, 'x') + "\\ud800x\"}");
    assert(malformed.malformed());
    // Exercise every byte at every position around the bulk-word boundary,
    // both before and after preview clipping. One-byte feeds cannot use the
    // eight-byte fast path, providing a state-machine differential oracle.
    for (const size_t prefix : {size_t(0), size_t(16380), size_t(20000)}) {
        for (size_t position = 0; position < 16; ++position) for (unsigned byte = 0; byte <= 255; ++byte) {
            std::string source = "{\"text\":\"" + std::string(prefix + position, 'x');
            source += static_cast<char>(byte); source += std::string(32, 'A') + "\",\"after\":\"tail\"}";
            tessera::BoundedJson bulk, scalar;
            bulk.feed(source);
            for (const char& c : source) scalar.feed(std::string_view(&c, 1));
            assert(bulk.malformed() == scalar.malformed() && bulk.unsupported() == scalar.unsupported());
            assert(bulk.truncated() == scalar.truncated() && bulk.json() == scalar.json());
        }
    }
}
