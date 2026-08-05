# Nearby bootstrap — cross-version compatibility

**The canonical contract lives in code:** the header doc-comment of
`Tessera/Bootstrap/NearbyBootstrapCompatibility.swift`. This page is a
pointer plus the short version.

Current protocol version: **2** (`NearbyBootstrapProtocol.version` — single
bump point; handshake messages, `TBCH` channel framing, and the manifest
schema version together).

## The contract in one paragraph

Every versioned wire message (commitment, hello, manifest root) carries an
integer `version` key that is never renamed; receivers probe it leniently
(`NearbyVersionProbe`) *before* any strict decode, so an incompatible future
message always produces a clean, directional "update Tessera on …" error
instead of a decoding failure — and for the manifest, the version check runs
before the strict unknown-field allowlist. There is no in-band negotiation:
the origin's TXT record (`v` key) tells a future recipient what it may speak
before it commits, and the commitment's `version`/`supportedVersions` tell a
future origin whether a downgrade path exists before it disclosed anything.
v2 accepts exactly v2, so today every non-v2 peer fails closed; the advisory
fields (`appVersion`, `supportedVersions`) and the TXT verdict are
unauthenticated hints only — the TXT badge never gates connection. Because
those negotiation inputs are cleartext and MITM-rewritable, binding only the
version *in use* into the transcript cannot detect a forced downgrade once
two versions coexist: the first version that widens `supportedVersions` must
fold the raw negotiation inputs (the commitment bytes as received, and the
browse-time TXT `v` claim) into its transcript/SAS so tampering
desynchronizes the SAS. Size envelopes are part of the contract too: future commitments
and hellos must fit the 4096-byte receive cap shipped builds enforce before
the version probe can run
(`NearbyBootstrapProtocol.maximumHandshakeMessageSize`).

## Artifacts

- Contract + invariants (canonical): `Tessera/Bootstrap/NearbyBootstrapCompatibility.swift`
- Frozen per-version wire schemas: `docs/schemas/nearby-bootstrap/` (freeze
  rule in its README; `v2/` is current)
- Drift tripwire: `TesseraTests/BootstrapWireSchemaTests.swift` pins the live
  encoders against the frozen `v2/` schemas
- Version-mismatch behavior tests: `BootstrapNearbyHandshakeTests`,
  `BootstrapManifestTests`, `BootstrapCoordinatorTests`,
  `BootstrapNearbyTransferServiceTests`

## What a future version bump must do

1. Bump `NearbyBootstrapProtocol.version`, widen `supportedVersions` only
   with an implemented per-version compatibility path — and, the first time
   it widens past one entry, define the new transcript to fold in the raw
   negotiation inputs (received commitment bytes + browse-time TXT `v`
   claim) per invariant 3 of the canonical contract.
2. Add `docs/schemas/nearby-bootstrap/v<N>/`; never edit the old folder.
3. Keep the `version` probe key, the TXT `v` key, and the commitment's
   advisory fields decodable by every older shipped build.
4. Define a new commitment projection label; never extend the v2 projection.
5. Update the drift-test fixtures.
