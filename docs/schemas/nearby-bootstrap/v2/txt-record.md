# Bonjour TXT record — nearby bootstrap v2

Service type: `_tessera-bootstrap._tcp` (never changes except as a deliberate
epoch break; it is the discovery boundary between "same app" and "invisible").

The advertising origin publishes one TXT key:

| Key | Value | Example |
|-----|-------|---------|
| `v` | Comma-separated ascending supported protocol versions | `2` |

Rules (see `NearbyCompatibilityAdvertisement`):

- Cleartext LAN broadcast: protocol integers only — never the app marketing
  version (fingerprinting), never anything trust-bearing.
- A **missing or unparsable** TXT record means *unknown*, never
  *incompatible*: every pre-TXT build advertises nothing and must stay fully
  connectable.
- A peer is badged incompatible only when the TXT is present and its version
  set provably excludes every locally supported version; the direction of the
  "update" hint follows the max-version comparison.
- Parsers ignore malformed segments; a list with more than 8 entries is
  rejected as a whole, mapping the peer to *unknown*.
- The TXT verdict is **advisory pre-connect UX only** — a badge and subtitle,
  never a connection gate. TXT is unauthenticated and spoofable by anyone on
  the LAN, so every peer row stays tappable and the handshake's version check
  remains the sole authoritative refusal.
