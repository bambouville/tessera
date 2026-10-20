#ifndef MOSH_CORE_PROBE_H
#define MOSH_CORE_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

// Minimal C-ABI probe so ObjC++ can call into MoshCore without having to
// import any C++ headers from the bridge side. Returns 42 on success;
// anything else means the toolchain wiring is broken.
int mosh_core_probe(void);

// Exercise mosh's Crypto::Session (AES-OCB through the selected backend)
// end-to-end — encrypt a known plaintext, prepend the 8-byte wire nonce,
// decrypt, and check the round-tripped text matches. Returns 42 on match,
// negative values on specific failure modes. Proves upstream mosh crypto
// compiles, links, and runs correctly on the target platform.
int mosh_crypto_probe(void);

// Apple-only AES-128 ECB primitive probe using CommonCrypto directly.
// Validates the block cipher underneath mosh's OCB Apple path before we
// trust the OCB layer. Returns 42 on match and -200 on non-Apple targets.
int mosh_ccrypto_primitive_probe(void);

// Exercise a reclaimed client UDP socket, immediate port hop, and receive
// recovery through real loopback Network::Connection instances. Returns 42
// on success or a distinct negative code for each failed step.
int mosh_reclaimed_socket_probe(void);

// Host-free logical-state probe for fresh repaint fence admission. Exercises
// the same predicate as MoshClient without constructing a UDP transport.
int mosh_full_repaint_fence_probe(void);

#ifdef __cplusplus
}
#endif

#endif
