#include "SourceDigest.h"
#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <type_traits>

using tessera::SourceDigest;
static_assert(sizeof(SourceDigest) <= 128 && std::is_copy_constructible_v<SourceDigest>);

static std::string hex(const std::array<uint8_t, 32>& digest) {
    std::ostringstream out;
    for (const auto byte : digest)
        out << std::hex << std::setw(2) << std::setfill('0') << unsigned(byte);
    return out.str();
}

static uint32_t next(uint32_t& seed) {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

static std::string makeData(size_t length) {
    std::string data(length, '\0');
    uint32_t seed = 0x9e3779b9U ^ static_cast<uint32_t>(length);
    for (auto& byte : data) byte = static_cast<char>(next(seed));
    return data;
}

static std::array<uint8_t, 32> hash(std::string_view value, bool portable) {
    SourceDigest::forcePortableForTesting(portable);
    SourceDigest digest;
    digest.append(value);
    const auto copy = digest;
    assert(digest.finish() == copy.finish());
    return digest.finish();
}

static void knownAnswer(std::string_view value, const char* expected) {
    for (const bool portable : {false, true}) assert(hex(hash(value, portable)) == expected);
}

static void splitCheck(std::string_view data, unsigned pattern) {
    std::array<uint8_t, 32> results[2];
    std::array<uint8_t, 32> prefixes[2];
    for (int backend = 0; backend < 2; ++backend) {
        SourceDigest::forcePortableForTesting(backend != 0);
        SourceDigest digest;
        uint32_t seed = 0x12345678U ^ static_cast<uint32_t>(data.size() * 37 + pattern);
        size_t offset = 0;
        bool checkedPrefix = false;
        while (offset < data.size()) {
            size_t chunk = data.size() - offset;
            switch (pattern) {
            case 0: break;
            case 1: chunk = 1; break;
            case 2: chunk = 63 + next(seed) % 3; break;
            case 3: chunk = 1 + next(seed) % 257; break;
            default: chunk = 1 + next(seed) % 4096; break;
            }
            if (chunk > data.size() - offset) chunk = data.size() - offset;
            digest.append(data.substr(offset, chunk));
            offset += chunk;
            if (!checkedPrefix && offset >= data.size() / 2) {
                const auto copy = digest;
                prefixes[backend] = copy.finish();
                assert(copy.finish() == digest.finish());
                assert(prefixes[backend] == hash(data.substr(0, offset), backend != 0));
                checkedPrefix = true;
            }
        }
        if (!checkedPrefix) prefixes[backend] = digest.finish();
        const auto copy = digest;
        results[backend] = digest.finish();
        assert(copy.finish() == results[backend]);
        assert(digest.finish() == results[backend]);
        digest.append("more");
        assert(digest.finish() == hash(std::string(data) + "more", backend != 0));
    }
    assert(results[0] == results[1]);
    assert(prefixes[0] == prefixes[1]);
}

static void benchmark(bool portable) {
    SourceDigest::forcePortableForTesting(portable);
    const std::string chunk = makeData(1 << 20);
    SourceDigest digest;
    const auto start = std::chrono::steady_clock::now();
    for (size_t i = 0; i < 256; ++i) digest.append(chunk);
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::cout << SourceDigest::backendNameForTesting() << ": " << 256.0 / elapsed
              << " MiB/s (256 MiB, " << elapsed << " s), digest " << hex(digest.finish()) << '\n';
}

int main() {
    SourceDigest::forcePortableForTesting(false);
    std::cout << "Detected backend: " << SourceDigest::backendNameForTesting() << '\n';
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
    // Every Apple arm64 CPU has SHA2. A kernel failing its startup self-check
    // must fail here instead of silently validating at portable speed.
    assert(std::string(SourceDigest::backendNameForTesting()) == "ARMv8 SHA2");
#endif
    knownAnswer("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    knownAnswer("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    knownAnswer("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    knownAnswer("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
                "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1");
    knownAnswer(std::string(1000000, 'a'),
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    std::string bytes(256, '\0');
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<char>(i);
    knownAnswer(bytes, "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880");
    for (const auto length : {size_t(4097), size_t(20000)}) {
        std::string value(length, '\0');
        for (size_t i = 0; i < length; ++i)
            value[i] = static_cast<char>(length == 4097 ? (i * 37 + 11) & 255 : (i * i + 17 * i + 3) & 255);
        knownAnswer(value, length == 4097
            ? "042a02b55ba342cdd30322331816b6e4bca073f33bdb80149dc74a6f949802f4"
            : "a02094efdc5a2100dad76588831e9f5dff6c5e1d4f54f1ed7c2ccdcd5eaa4f2c");
    }
    for (size_t length = 0; length <= 20000; ++length) {
        const auto data = makeData(length);
        assert(hash(data, false) == hash(data, true));
        if (length <= 256 || length % 53 == 0 ||
            length == 63 || length == 64 || length == 65 ||
            length == 127 || length == 128 || length == 129)
            for (unsigned pattern = 0; pattern < 5; ++pattern) splitCheck(data, pattern);
    }
    benchmark(true);
    benchmark(false);
    SourceDigest::forcePortableForTesting(false);
}
