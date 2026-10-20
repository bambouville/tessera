#pragma once
#include <cstdint>
#include <cstring>
#include <string_view>

namespace tessera::detail {
inline size_t plainASCII(std::string_view bytes) {
    // Eight ordinary JSON string bytes at a time, without alignment or endian
    // assumptions. Any control, high bit, quote or backslash returns to the
    // caller's scalar handling. Borrow can stop this test early, never admit
    // a special byte as plain text.
    constexpr uint64_t high = 0x8080808080808080ULL, ones = 0x0101010101010101ULL;
    auto zero = [&](uint64_t word) { return (word - ones) & ~word & high; };
    size_t length = 0;
    while (bytes.size() - length >= sizeof(uint64_t)) {
        uint64_t word; std::memcpy(&word, bytes.data() + length, sizeof(word));
        if ((word & high) || ((word - 0x2020202020202020ULL) & ~word & high) ||
            zero(word ^ 0x2222222222222222ULL) || zero(word ^ 0x5c5c5c5c5c5c5c5cULL)) break;
        length += sizeof(word);
    }
    while (length < bytes.size()) {
        const auto c = static_cast<unsigned char>(bytes[length]);
        if (c < 0x20 || c >= 0x80 || c == '"' || c == '\\') break;
        ++length;
    }
    return length;
}
}
