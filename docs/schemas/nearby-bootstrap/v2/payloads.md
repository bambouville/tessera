# Encrypted-envelope payloads — nearby bootstrap v2

Each encrypted frame's plaintext is the envelope in
`encrypted-envelope.schema.json`; this page freezes the per-kind payload
formats. JSON payloads have their own schema files; two kinds are not JSON:

| kind | payload |
|------|---------|
| `sasDecision` | exactly one byte: `0x01` = codes match, `0x00` = rejected |
| `originAuthorization` | empty (zero bytes) — the authenticated frame itself is the proof |
| `recipientPublicKey` | `recipient-public-key.schema.json` |
| `manifest` | `manifest.schema.json` |
| `importAcceptance` | `import-acceptance.schema.json` |
| `grantReceipt` | `grant-receipt.schema.json` |
| `completionAcknowledgement` | `completion-acknowledgement.schema.json` |

Hash contracts (frozen): `manifestHash` and `grantReceiptHash` are SHA-256
over the **canonical encoding** — `JSONEncoder` with
`[.sortedKeys, .withoutEscapingSlashes]` — of the manifest and receipt
respectively. Canonical byte-stable re-encoding is therefore part of the v2
wire contract, not an implementation detail.
