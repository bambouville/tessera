#ifndef MOSH_CORE_PROBE_H
#define MOSH_CORE_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

// Minimal C-ABI probe so ObjC++ can call into MoshCore without having to
// import any C++ headers from the bridge side. Returns 42 on success;
// anything else means the toolchain wiring is broken.
int mosh_core_probe(void);

// Spike 2 probe: exercise mosh's Crypto::Session (AES-OCB via CommonCrypto)
// end-to-end — encrypt a known plaintext, prepend the 8-byte wire nonce,
// decrypt, and check the round-tripped text matches. Returns 42 on match,
// negative values on specific failure modes. Proves upstream mosh crypto
// compiles, links with Apple CommonCrypto, and runs correctly on iOS.
int mosh_crypto_probe(void);

// Independent AES-128 ECB primitive probe using CommonCrypto directly.
// Validates the block cipher underneath mosh's OCB Apple path before we
// trust the OCB layer. Returns 42 on match.
int mosh_ccrypto_primitive_probe(void);

#ifdef __cplusplus
}
#endif

#endif
