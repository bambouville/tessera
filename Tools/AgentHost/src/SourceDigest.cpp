#include "SourceDigest.h"
#include <algorithm>
#include <cstring>
#ifdef TESSERA_SOURCE_DIGEST_TESTING
#include <atomic>
#endif

#if defined(__aarch64__) || defined(__arm64__)
#include <arm_neon.h>
#if defined(__linux__)
#include <sys/auxv.h>
#if __has_include(<asm/hwcap.h>)
#include <asm/hwcap.h>
#endif
#ifndef HWCAP_SHA2
#define HWCAP_SHA2 (1UL << 6)
#endif
#endif
#elif defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#endif

namespace tessera {
namespace {
constexpr std::array<uint32_t, 64> constants{{
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}};
uint32_t rotate(uint32_t value, unsigned bits) { return value >> bits | value << (32 - bits); }

void transformPortable(uint32_t* words, const uint8_t* block) {
    std::array<uint32_t, 64> schedule{};
    for (size_t i = 0; i < 16; ++i)
        schedule[i] = uint32_t(block[4*i]) << 24 | uint32_t(block[4*i+1]) << 16 |
                      uint32_t(block[4*i+2]) << 8 | block[4*i+3];
    for (size_t i = 16; i < schedule.size(); ++i) {
        const auto a = schedule[i-15], b = schedule[i-2];
        schedule[i] = schedule[i-16] + (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) +
                      schedule[i-7] + (rotate(b,17) ^ rotate(b,19) ^ (b >> 10));
    }
    auto a=words[0], b=words[1], c=words[2], d=words[3];
    auto e=words[4], f=words[5], g=words[6], h=words[7];
    for (size_t i = 0; i < schedule.size(); ++i) {
        const auto first = h + (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) +
                           ((e & f) ^ (~e & g)) + constants[i] + schedule[i];
        const auto second = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
        h=g; g=f; f=e; e=d+first; d=c; c=b; b=a; a=first+second;
    }
    words[0]+=a; words[1]+=b; words[2]+=c; words[3]+=d;
    words[4]+=e; words[5]+=f; words[6]+=g; words[7]+=h;
}

enum class Backend { portable, armSha2, x86ShaNi };

#if defined(__aarch64__) || defined(__arm64__)
// GCC 12 gates these intrinsics on +crypto and rejects "sha2"; clang takes both.
__attribute__((target("+crypto")))
void transformArmSha2(uint32_t* state, const uint8_t* blocks, size_t count, const uint8_t* firstBlock) {
    auto abcd = vld1q_u32(state);
    auto efgh = vld1q_u32(state + 4);
    for (size_t block = 0; block < count + (firstBlock != nullptr); ++block) {
        const auto* data = firstBlock && block == 0 ? firstBlock :
            blocks + (block - (firstBlock != nullptr)) * 64;
        const auto savedAbcd = abcd, savedEfgh = efgh;
        uint32x4_t schedule[4];
        for (size_t i = 0; i < 4; ++i)
            schedule[i] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + i * 16)));
        for (size_t group = 0; group < 16; ++group) {
            const auto index = group & 3;
            const auto wk = vaddq_u32(schedule[index], vld1q_u32(constants.data() + group * 4));
            const auto oldAbcd = abcd;
            abcd = vsha256hq_u32(abcd, efgh, wk);
            efgh = vsha256h2q_u32(efgh, oldAbcd, wk);
            if (group < 12)
                schedule[index] = vsha256su1q_u32(
                    vsha256su0q_u32(schedule[index], schedule[(index + 1) & 3]),
                    schedule[(index + 2) & 3], schedule[(index + 3) & 3]);
        }
        abcd = vaddq_u32(abcd, savedAbcd);
        efgh = vaddq_u32(efgh, savedEfgh);
    }
    vst1q_u32(state, abcd);
    vst1q_u32(state + 4, efgh);
}
#endif

#if defined(__x86_64__)
__attribute__((target("sha,sse4.1,ssse3")))
void transformX86ShaNi(uint32_t* state, const uint8_t* blocks, size_t count, const uint8_t* firstBlock) {
    // SHA-NI uses ABEF/CDGH, rather than the scalar ABCD/EFGH layout.
    auto tmp = _mm_shuffle_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(state)), 0xb1);
    auto cdgh = _mm_shuffle_epi32(_mm_loadu_si128(reinterpret_cast<const __m128i*>(state + 4)), 0x1b);
    auto abef = _mm_alignr_epi8(tmp, cdgh, 8);
    cdgh = _mm_blend_epi16(cdgh, tmp, 0xf0);
    const auto byteSwap = _mm_set_epi64x(0x0c0d0e0f08090a0bULL, 0x0405060700010203ULL);
    for (size_t block = 0; block < count + (firstBlock != nullptr); ++block) {
        const auto* data = firstBlock && block == 0 ? firstBlock :
            blocks + (block - (firstBlock != nullptr)) * 64;
        const auto savedAbef = abef, savedCdgh = cdgh;
        __m128i schedule[4];
        for (size_t i = 0; i < 4; ++i)
            schedule[i] = _mm_shuffle_epi8(
                _mm_loadu_si128(reinterpret_cast<const __m128i*>(data + i * 16)), byteSwap);
        for (size_t group = 0; group < 16; ++group) {
            const auto index = group & 3;
            auto message = _mm_add_epi32(schedule[index],
                _mm_loadu_si128(reinterpret_cast<const __m128i*>(constants.data() + group * 4)));
            cdgh = _mm_sha256rnds2_epu32(cdgh, abef, message);
            message = _mm_shuffle_epi32(message, 0x0e);
            abef = _mm_sha256rnds2_epu32(abef, cdgh, message);
            if (group >= 3 && group <= 14) {
                const auto target = (group - 3) & 3;
                const auto aligned = _mm_alignr_epi8(schedule[index], schedule[(index + 3) & 3], 4);
                schedule[target] = _mm_sha256msg2_epu32(
                    _mm_add_epi32(schedule[target], aligned), schedule[index]);
            }
            if (group <= 12)
                schedule[index] = _mm_sha256msg1_epu32(schedule[index], schedule[(index + 1) & 3]);
        }
        abef = _mm_add_epi32(abef, savedAbef);
        cdgh = _mm_add_epi32(cdgh, savedCdgh);
    }
    tmp = _mm_shuffle_epi32(abef, 0x1b);
    cdgh = _mm_shuffle_epi32(cdgh, 0xb1);
    abef = _mm_blend_epi16(tmp, cdgh, 0xf0);
    cdgh = _mm_alignr_epi8(cdgh, tmp, 8);
    _mm_storeu_si128(reinterpret_cast<__m128i*>(state), abef);
    _mm_storeu_si128(reinterpret_cast<__m128i*>(state + 4), cdgh);
}
#endif

Backend detectBackend() {
#if defined(__aarch64__) || defined(__arm64__)
#if defined(__APPLE__)
    return Backend::armSha2;
#elif defined(__linux__)
    return (getauxval(AT_HWCAP) & HWCAP_SHA2) ? Backend::armSha2 : Backend::portable;
#endif
#elif defined(__x86_64__)
    unsigned eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx) ||
        (ecx & ((1U << 9) | (1U << 19))) != ((1U << 9) | (1U << 19)))
        return Backend::portable;
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx) || !(ebx & (1U << 29)))
        return Backend::portable;
    return Backend::x86ShaNi;
#endif
    return Backend::portable;
}

void transformWith(Backend backend, uint32_t* words, const uint8_t* blocks, size_t count, const uint8_t* firstBlock) {
    switch (backend) {
#if defined(__aarch64__) || defined(__arm64__)
    case Backend::armSha2:
        transformArmSha2(words, blocks, count, firstBlock);
        return;
#elif defined(__x86_64__)
    case Backend::x86ShaNi:
        transformX86ShaNi(words, blocks, count, firstBlock);
        return;
#endif
    default:
        if (firstBlock) transformPortable(words, firstBlock);
        for (size_t i = 0; i < count; ++i) transformPortable(words, blocks + i * 64);
    }
}

// An accelerated kernel must reproduce the portable one before any source is
// validated with it; the SHA-NI kernel runs on x86 hosts tests cannot reach.
Backend verified(Backend backend) {
    if (backend == Backend::portable) return backend;
    std::array<uint8_t, 64 * 3> data{};
    uint32_t seed = 0x6d2b79f5U;
    for (auto& byte : data) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; byte = uint8_t(seed); }
    std::array<uint32_t, 8> expected{{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}};
    auto actual = expected;
    transformWith(Backend::portable, expected.data(), data.data() + 64, 2, data.data());
    transformWith(backend, actual.data(), data.data() + 64, 2, data.data());
    return actual == expected ? backend : Backend::portable;
}

Backend selectedBackend() {
    static const Backend backend = verified(detectBackend());
    return backend;
}

#ifdef TESSERA_SOURCE_DIGEST_TESTING
std::atomic<bool> forcePortable{false};
#endif
}

void SourceDigest::transformBlocks(const uint8_t* blocks, size_t count, const uint8_t* firstBlock) {
    if (!count && !firstBlock) return;
    auto backend = selectedBackend();
#ifdef TESSERA_SOURCE_DIGEST_TESTING
    if (forcePortable.load(std::memory_order_relaxed)) backend = Backend::portable;
#endif
    transformWith(backend, words_.data(), blocks, count, firstBlock);
}

#ifdef TESSERA_SOURCE_DIGEST_TESTING
void SourceDigest::forcePortableForTesting(bool force) {
    forcePortable.store(force, std::memory_order_relaxed);
}

const char* SourceDigest::backendNameForTesting() {
    if (forcePortable.load(std::memory_order_relaxed)) return "portable (forced)";
    switch (selectedBackend()) {
    case Backend::armSha2: return "ARMv8 SHA2";
    case Backend::x86ShaNi: return "x86 SHA-NI";
    default: return "portable";
    }
}
#endif

void SourceDigest::append(std::string_view bytes) {
    if (bytes.empty()) return;
    bytes_ += bytes.size();
    const uint8_t* firstBlock = nullptr;
    if (used_) {
        const auto count = std::min(bytes.size(), tail_.size() - used_);
        std::memcpy(tail_.data() + used_, bytes.data(), count);
        used_ += count; bytes.remove_prefix(count);
        if (used_ == tail_.size()) { firstBlock = tail_.data(); used_ = 0; }
    }
    const auto fullBlocks = bytes.size() / tail_.size();
    transformBlocks(reinterpret_cast<const uint8_t*>(bytes.data()), fullBlocks, firstBlock);
    bytes.remove_prefix(fullBlocks * tail_.size());
    if (!bytes.empty()) { std::memcpy(tail_.data(), bytes.data(), bytes.size()); used_ = bytes.size(); }
}

std::array<uint8_t, 32> SourceDigest::finish() const {
    auto copy = *this;
    const auto bits = bytes_ * 8;
    copy.tail_[copy.used_++] = 0x80;
    if (copy.used_ > 56) {
        std::fill(copy.tail_.begin() + copy.used_, copy.tail_.end(), 0);
        copy.transformBlocks(copy.tail_.data(), 1); copy.used_ = 0;
    }
    std::fill(copy.tail_.begin() + copy.used_, copy.tail_.begin() + 56, 0);
    for (size_t i = 0; i < 8; ++i) copy.tail_[63-i] = static_cast<uint8_t>(bits >> (8*i));
    copy.transformBlocks(copy.tail_.data(), 1);
    std::array<uint8_t, 32> result{};
    for (size_t i = 0; i < result.size(); ++i) result[i] = static_cast<uint8_t>(copy.words_[i/4] >> (24 - 8*(i%4)));
    return result;
}
}
