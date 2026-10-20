# Nearby bootstrap v2 optional manifest extensions

The released v2 schemas remain immutable. Their lenient authenticated
`recipientPublicKey` payload permits receiver declarations before the origin
exports the strict manifest. This is an explicit exception to the version-bump
rule for receiver-declared, optional extensions; it does not change v2
handshake negotiation, key derivation, SAS, authentication, or frame limits.

A recipient may add `manifestExtensions`, an optional list of unique,
nonempty printable ASCII strings (at most 16 entries, 128 UTF-8 bytes each),
to the public-key payload. Absence means no extensions. Invalid declarations
fail closed. Unknown well-formed identifiers grant no recognized capability.
Declarations are consumed only after decrypting/authenticating the ordered
recipient key frame, after mutual SAS confirmation. Never infer support from
Bonjour, app version, or a cleartext handshake hint.

An origin may use an extension only if this recipient declared its exact
identifier. A released origin ignores the extra key using its ordinary
`EnrollmentPublicKeyV1` decoder. It validates/fingerprints the SSH key blob,
not the payload bytes, and performs no canonical re-encoding comparison.
A released recipient sends no declaration and therefore never receives an
extended manifest. Keep the key payload within the released 65,536-byte frame
cap, including envelope/base64/authentication overhead.

## `settings.agentCenterEnabled`

New recipients declare `"settings.agentCenterEnabled"`. Only then may an
origin include the optional boolean `settings.agentCenterEnabled` in its
manifest. Both true and false follow the source; absence preserves local
state. Other unknown manifest settings remain errors. Notification permission
is device-local: importing records whether Agent Center was enabled, and UI
requests permission after protocol completion, while showing the receipt.

QR setup uses separately negotiated bootstrap transaction v2; this declaration
is exclusive to legacy nearby v2 and does not alter strict pairing v1 messages.
