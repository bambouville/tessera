# Pairing v1 wire contract

Pairing v1 uses canonical sorted-key UTF-8 JSON for the offer, recipient
commitment, both role-labelled hellos, and the generic encrypted envelope.
Unknown root fields, non-canonical encodings, and messages over their declared
limits are rejected.

The JSON contracts are frozen in `offer.schema.json`,
`commitment.schema.json`, `hello.schema.json`, and `envelope.schema.json`.
The `purpose-bound-optical.json` vector pins a deterministic handshake and an
encrypted transaction frame. `frame-layout.json` is the machine-readable
binary layout for that frame; every multibyte integer is unsigned big-endian.

The authenticated frame layout is:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `TPF1` (`54 50 46 31`) |
| 4 | 1 | frame version (`1`) |
| 5 | 1 | direction (`1` origin-to-recipient, `2` recipient-to-origin) |
| 6 | 8 | sequence |
| 14 | 4 | sealed-payload byte length |
| 18 | variable | ChaCha20-Poly1305 combined nonce, ciphertext, and tag |

The 18-byte header and handshake transcript hash are authenticated as AAD.
The transmitted 12-byte nonce must equal the direction-specific base nonce
with the sequence XORed into its final eight bytes. The complete frame is at
most 65,536 bytes and the sealed payload is at least 28 bytes (nonce plus tag).

Any wire change requires a new version and vector directory. Pairing v1 must
not reinterpret the released legacy nearby-bootstrap v2 bytes.
