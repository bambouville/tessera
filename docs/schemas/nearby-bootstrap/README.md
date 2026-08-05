# Nearby-bootstrap wire schemas

One folder per shipped nearby-bootstrap protocol version. Each folder freezes
the exact wire shape of that version's messages as JSON Schema (draft
2020-12): the cleartext handshake messages (`hello`, `commitment`), the
encrypted envelope and every JSON payload it carries (`manifest`,
`recipient-public-key`, `import-acceptance`, `grant-receipt`,
`completion-acknowledgement`), the non-JSON payload formats (`payloads.md`),
and the Bonjour TXT-record contract (`txt-record.md`).

**Freeze rule: files under a shipped version's folder are immutable.** Any
wire change — adding, renaming, or removing a key on any message — requires:

1. bumping `NearbyBootstrapProtocol.version`
   (`Tessera/Bootstrap/NearbyBootstrapCompatibility.swift`, the canonical
   compatibility contract),
2. creating a new `v<N+1>/` folder with the new schemas,
3. leaving the old folder untouched — it is the historical record a future
   implementation reads when writing its downgrade path to older peers,
4. updating the fixtures in `TesseraTests/BootstrapWireSchemaTests.swift`,
   which pins the live encoders against the current version's folder. That
   test failing is the intended tripwire for accidental wire drift.

Schema conventions:

- `additionalProperties: false` on the manifest mirrors the strict in-code
  allowlist (`BootstrapManifestSchema`): an unknown field is a hard reject.
- `additionalProperties: true` on handshake messages mirrors their lenient
  decoders: unknown keys are ignored, which is what makes same-version
  additive fields (and the version-first probe) work.
- Types reflect Swift `JSONEncoder` defaults: `Data` → base64 string,
  `UUID` → string, `Date` → number (seconds since the reference date),
  optional properties are simply absent when nil.
