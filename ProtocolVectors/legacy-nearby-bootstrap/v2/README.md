# Legacy nearby-bootstrap v2 vectors

`canonical.json` freezes the bytes emitted by the released Apple v2 nearby
bootstrap implementation. The fixture was generated with X25519 private-key
seeds `00...1f` (origin) and `20...3f` (recipient) and the Tessera 0.3.6
advisory app-version field.

The vector pins:

- sorted-key UTF-8 JSON for both cleartext hellos, the recipient commitment
  projection, and the first commitment message;
- deterministic X25519 public keys, the commitment digest, transcript bytes,
  transcript SHA-256, both directional HKDF keys and base nonces, HKDF-derived
  SAS bytes, and the six-digit SAS;
- both exact encrypted SAS-decision frame spellings emitted by the released
  encoder in each direction (sequence 0);
- both exact DEBUG test-envelope frame spellings in each direction (sequence 1), which
  makes direction, sequence, nonce derivation, AAD transcript binding,
  ChaCha20-Poly1305 ciphertext, and envelope encoding observable.
- canonical JSON for the recipient public key, manifest, import acceptance,
  truthful host-grant receipt, and completion acknowledgement, plus both exact
  encrypted-envelope spellings for the complete released transfer sequence.
  The empty origin-authorization proof frame is pinned as well.

The released encrypted-envelope encoder did not request sorted JSON keys, so
Foundation may emit its two fields as either `kind,payload` or `payload,kind`
depending on the process hash seed. Both exact ciphertexts are therefore part
of the frozen v2 compatibility set. The refactor must continue to emit one of
these released spellings; making the legacy encoder canonical now would itself
change the shipped implementation.

The `appVersion` field is an unauthenticated advisory hint and is intentionally
excluded from the commitment projection and transcript. The fixture retains
`0.3.6` to preserve the exact released JSON bytes; tests construct that value
explicitly, so a later marketing-version bump does not alter v2 cryptography.

This directory is immutable compatibility evidence. Pairing v1 uses a
distinct purpose-bound transcript and service epoch; it must never reinterpret
or widen these legacy v2 frames. Any intentional wire change requires a new
protocol version and a new vector directory.
