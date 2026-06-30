#include "include/MoshCoreProbe.h"

#include <array>
#include <cctype>
#include <cstdint>
#include <string>
#include <vector>
#include <cstring>
#include <CommonCrypto/CommonCryptor.h>

#include <google/protobuf/stubs/strutil.h>
#include "crypto.h"

namespace {

bool hex_to_bytes(const char *hex, unsigned char *out, size_t out_len) {
    static const char *kDigits = "0123456789abcdef";

    for (size_t i = 0; i < out_len; ++i) {
        const char hi = hex[i * 2];
        const char lo = hex[i * 2 + 1];
        const char *hi_ptr = std::strchr(
            kDigits, std::tolower(static_cast<unsigned char>(hi)));
        const char *lo_ptr = std::strchr(
            kDigits, std::tolower(static_cast<unsigned char>(lo)));
        if (hi_ptr == nullptr || lo_ptr == nullptr) {
            return false;
        }
        out[i] = static_cast<unsigned char>(((hi_ptr - kDigits) << 4) | (lo_ptr - kDigits));
    }
    return true;
}

int aes_ecb_encrypt_create(const unsigned char *key,
                           const unsigned char *pt,
                           unsigned char *ct) {
    CCCryptorRef ref = nullptr;
    size_t moved = 0;
    const CCCryptorStatus status = CCCryptorCreate(
        kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode,
        key, kCCKeySizeAES128, nullptr, &ref);
    if (status != kCCSuccess) {
        return -1;
    }

    const CCCryptorStatus update = CCCryptorUpdate(
        ref, pt, kCCBlockSizeAES128, ct, kCCBlockSizeAES128, &moved);
    CCCryptorRelease(ref);
    if (update != kCCSuccess || moved != kCCBlockSizeAES128) {
        return -2;
    }
    return 0;
}

int aes_ecb_encrypt_from_data(const unsigned char *key,
                              const unsigned char *pt,
                              unsigned char *ct,
                              bool in_place) {
    struct WrapperKey {
        CCCryptorRef ref;
        unsigned char storage[4096];
    };

    WrapperKey wrapper{};
    size_t moved = 0;
    const CCCryptorStatus status = CCCryptorCreateFromData(
        kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode,
        key, kCCKeySizeAES128, nullptr,
        wrapper.storage, sizeof(wrapper.storage), &wrapper.ref, nullptr);
    if (status != kCCSuccess) {
        return -1;
    }

    std::array<unsigned char, kCCBlockSizeAES128> scratch{};
    if (in_place) {
        std::memcpy(scratch.data(), pt, scratch.size());
        const CCCryptorStatus update = CCCryptorUpdate(
            wrapper.ref,
            scratch.data(), scratch.size(),
            scratch.data(), scratch.size(),
            &moved);
        CCCryptorRelease(wrapper.ref);
        if (update != kCCSuccess || moved != scratch.size()) {
            return -2;
        }
        std::memcpy(ct, scratch.data(), scratch.size());
        return 0;
    }

    const CCCryptorStatus update = CCCryptorUpdate(
        wrapper.ref, pt, kCCBlockSizeAES128, ct, kCCBlockSizeAES128, &moved);
    CCCryptorRelease(wrapper.ref);
    if (update != kCCSuccess || moved != kCCBlockSizeAES128) {
        return -3;
    }
    return 0;
}

int aes_ecb_decrypt_create(const unsigned char *key,
                           const unsigned char *ct,
                           unsigned char *pt) {
    CCCryptorRef ref = nullptr;
    size_t moved = 0;
    const CCCryptorStatus status = CCCryptorCreate(
        kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode,
        key, kCCKeySizeAES128, nullptr, &ref);
    if (status != kCCSuccess) {
        return -1;
    }

    const CCCryptorStatus update = CCCryptorUpdate(
        ref, ct, kCCBlockSizeAES128, pt, kCCBlockSizeAES128, &moved);
    CCCryptorRelease(ref);
    if (update != kCCSuccess || moved != kCCBlockSizeAES128) {
        return -2;
    }
    return 0;
}

int direct_ae_roundtrip() {
    const std::string kTestKey = "AAECAwQFBgcICQoLDA0ODw";
    const std::string plaintext = "hello mosh";

    try {
        Crypto::Base64Key key(kTestKey);
        Crypto::AlignedBuffer ctx_buf(ae_ctx_sizeof());
        if ((reinterpret_cast<std::uintptr_t>(ctx_buf.data()) & 0xF) != 0) {
            return -101;
        }

        auto *ctx = reinterpret_cast<ae_ctx *>(ctx_buf.data());
        if (ae_init(ctx, key.data(), 16, 12, 16) != AE_SUCCESS) {
            return -102;
        }

        Crypto::Nonce nonce(1);
        std::array<char, 256> ciphertext{};
        std::array<char, 256> decrypted{};

        const int ct_len = ae_encrypt(
            ctx,
            nonce.data(),
            plaintext.data(),
            static_cast<int>(plaintext.size()),
            nullptr,
            0,
            ciphertext.data(),
            nullptr,
            AE_FINALIZE);
        if (ct_len != static_cast<int>(plaintext.size()) + 16) {
            ae_clear(ctx);
            return -103;
        }

        const int pt_len = ae_decrypt(
            ctx,
            nonce.data(),
            ciphertext.data(),
            ct_len,
            nullptr,
            0,
            decrypted.data(),
            nullptr,
            AE_FINALIZE);
        if (pt_len != static_cast<int>(plaintext.size())) {
            ae_clear(ctx);
            return -104;
        }
        if (std::memcmp(decrypted.data(), plaintext.data(), plaintext.size()) != 0) {
            ae_clear(ctx);
            return -105;
        }

        if (ae_clear(ctx) != AE_SUCCESS) {
            return -106;
        }
        return 42;
    } catch (const Crypto::CryptoException &) {
        return -107;
    } catch (...) {
        return -108;
    }
}

// Exercise a small amount of C++17 (string/vector, structured bindings)
// AND one real protobuf symbol (CEscape from stubs/strutil.cc). If this
// both compiles and links, the SPM C++ + protobuf-runtime path is viable.
int probe_internal() {
    std::vector<std::pair<std::string, int>> items;
    items.emplace_back("answer", 42);
    auto [_, value] = items.front();

    // CEscape("A\n") returns "A\\n" — length 3. Fail loudly if not.
    const std::string escaped = google::protobuf::CEscape(std::string("A\n"));
    if (escaped.size() != 3) {
        return -static_cast<int>(escaped.size());
    }
    return value;
}

int crypto_roundtrip() {
    const int ae_probe = direct_ae_roundtrip();
    if (ae_probe != 42) {
        return ae_probe;
    }

    try {
        const std::string kTestKey = "AAECAwQFBgcICQoLDA0ODw";
        Crypto::Base64Key key(kTestKey);
        if (key.printable_key() != kTestKey) return -10;

        Crypto::Session session(key);
        const std::string plaintext = "hello mosh";
        const Crypto::Nonce nonce(1);
        const std::string nonce_prefix = nonce.cc_str();
        // Upstream Session::encrypt already returns the full wire payload:
        // 8-byte nonce prefix + ciphertext + 16-byte tag.
        const std::string wire = session.encrypt(Crypto::Message(nonce, plaintext));
        if (wire.size() != nonce_prefix.size() + plaintext.size() + 16) return -30;
        if (std::memcmp(wire.data(), nonce_prefix.data(), nonce_prefix.size()) != 0) return -31;

        Crypto::Message decoded = session.decrypt(wire);
        if (decoded.nonce.val() != nonce.val()) return -40;
        if (decoded.text != plaintext) return -41;
        return 42;
    } catch (const Crypto::CryptoException &error) {
        if (std::string(error.what()) == "Packet failed integrity check.") {
            return -50;
        }
        return -20;
    } catch (...) {
        return -21;
    }
}

}

extern "C" int mosh_core_probe(void) {
    return probe_internal();
}

// Independent AES-128 ECB roundtrip using CommonCrypto directly. This is
// the primitive underneath mosh's OCB Apple path. If the single-block
// roundtrip here works but mosh_crypto_probe returns -50 (decrypt failed),
// the bug is in OCB wiring; if this also fails, the primitive is broken.
extern "C" int mosh_ccrypto_primitive_probe(void) {
    unsigned char key[16] = {0};
    unsigned char pt[16] = {0};
    unsigned char expected_ct[16] = {0};
    unsigned char actual_ct[16] = {0};
    unsigned char roundtrip_pt[16] = {0};
    unsigned char wrapped_ct[16] = {0};
    unsigned char wrapped_ct_in_place[16] = {0};

    if (!hex_to_bytes("2b7e151628aed2a6abf7158809cf4f3c", key, sizeof(key))) return -11;
    if (!hex_to_bytes("6bc1bee22e409f96e93d7e117393172a", pt, sizeof(pt))) return -12;
    if (!hex_to_bytes("3ad77bb40d7a3660a89ecaf32466ef97", expected_ct, sizeof(expected_ct))) return -13;

    if (aes_ecb_encrypt_create(key, pt, actual_ct) != 0) return -14;
    if (std::memcmp(actual_ct, expected_ct, sizeof(actual_ct)) != 0) return -15;

    if (aes_ecb_decrypt_create(key, actual_ct, roundtrip_pt) != 0) return -16;
    if (std::memcmp(roundtrip_pt, pt, sizeof(pt)) != 0) return -17;

    if (aes_ecb_encrypt_from_data(key, pt, wrapped_ct, false) != 0) return -18;
    if (std::memcmp(wrapped_ct, expected_ct, sizeof(wrapped_ct)) != 0) return -19;

    if (aes_ecb_encrypt_from_data(key, pt, wrapped_ct_in_place, true) != 0) return -20;
    if (std::memcmp(wrapped_ct_in_place, expected_ct, sizeof(wrapped_ct_in_place)) != 0) return -21;

    return 42;
}

extern "C" int mosh_crypto_probe(void) {
    return crypto_roundtrip();
}
