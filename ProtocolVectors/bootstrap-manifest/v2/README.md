# Bootstrap manifest v2

The manifest version is owned by `BootstrapManifestProtocol`, independently of
legacy nearby-bootstrap v2 and pairing transaction versions. The released
`canonical.json` remains frozen and omits `settings.agentCenterEnabled`.

`settings.agentCenterEnabled` is an optional Boolean extension: true and false
are explicit choices; absence preserves the recipient's local choice. Senders
may include it only after the recipient declared support: the authenticated
nearby `manifestExtensions` declaration or negotiated QR bootstrap transaction
v2. Older or unknown recipients receive the released field set. All other
unknown fields remain strictly rejected.

The additional `agent-center-*.json` vectors cover true, false, absence, and
non-Boolean rejection without changing frozen vectors. Portable tests also pin
resource limits, graph validation, and explicit opt-in for free-text and
trusted-host material.
