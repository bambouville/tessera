#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace tessera {
// A constant-size, worker-owned SHA-256 observation. This is a content
// fingerprint, not authorization or a claim of an atomic provider snapshot.
class SourceDigest {
public:
    void append(std::string_view bytes);
    std::array<uint8_t, 32> finish() const;
#ifdef TESSERA_SOURCE_DIGEST_TESTING
    // Only built for the native test target; release artifacts omit this hook.
    static void forcePortableForTesting(bool force);
    static const char* backendNameForTesting();
#endif
private:
    void transformBlocks(const uint8_t* blocks, size_t count, const uint8_t* firstBlock = nullptr);
    std::array<uint32_t, 8> words_{{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}};
    std::array<uint8_t, 64> tail_{};
    uint64_t bytes_ = 0;
    size_t used_ = 0;
};
}
