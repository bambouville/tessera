# Bootstrap transaction v2

Delta from v1: every bootstrap transaction envelope carries `version: 2`;
the manifest may additionally contain the optional boolean
`settings.agentCenterEnabled`. Bodies, message kinds, strict field allowlists,
canonical encoding, size limits, authorization, receipts, and state ordering
are otherwise identical. Manifest schema version remains 2. A v1-selected
transaction must neither send nor accept the setting, including a null field.

Pairing v1 wire messages are unchanged. Peers advertise `[1, 2]` for bootstrap
and setup-and-continue; the existing authenticated highest-common selection
chooses the transaction profile. Other purposes advertise `[1]`. In the
combined setup-and-continue v2 profile, continuation messages remain strictly
v1; only the bootstrap leg uses v2. Exact offer, commitment, and hello bytes
remain transcript-bound, so stripping a version desynchronizes authentication.

`receipts.json` mirrors v1's no-extension lifecycle, with only the envelope
version changed, to pin that byte-level delta. The Swift full lifecycle test
produces these bytes. Swift also covers extension true/false round trips,
v1 rejection, malformed/noncanonical v2 messages, and the negotiation matrix.
The independent Kotlin consumer loads both versions and checks their delta.
`rejections.json` and `optional-transfer-rejections.json` retain the v1 failure
contracts for both state machines.
