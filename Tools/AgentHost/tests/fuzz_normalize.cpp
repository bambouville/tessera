#include "Normalize.h"
#include <cstdint>
#include <cstddef>
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size > 262144) return 0;
    simdjson::dom::parser parser;
    simdjson::dom::element value;
    if (parser.parse(reinterpret_cast<const char*>(data), size).get(value)) return 0;
    try {
        for (const auto* provider : {"claude", "codex", "pi", "opencode"})
            (void)tessera::normalize(provider, value, false);
        (void)tessera::normalizeKimi(value, false);
        (void)tessera::normalizeCodexItem(value, "fuzz");
        (void)tessera::normalizeCodexCoreItem(value, "fuzz");
    } catch (const simdjson::simdjson_error&) {}
    return 0;
}
