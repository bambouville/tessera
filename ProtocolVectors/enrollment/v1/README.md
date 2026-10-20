# Enrollment v1 vectors

All JSON files except `invalid-unsupported-version.json` are canonical
sorted-key payloads. A stream frame is the four-byte unsigned big-endian JSON
length followed by the payload bytes. The strict success order is:

1. `request`
2. `installed`, only after authorized_keys mutation, read-back, and durable audit intent
3. `recorded`, only after requester identity and ledger persistence
4. `completed`, the origin's final acknowledgement

Reject, cancel, and failure are terminal. Version 2 must be rejected by the v1
decoder rather than treated as a compatible extension.

`pairing-transaction.json` fixes the enrollment-purpose Pairing v1 authority
binding. It is not an EnrollmentMessage payload: it records the exact negotiated
pairing/transaction versions and 32-byte transcript hash required before the
shared enrollment state machine can be constructed, plus a deterministic
authenticated PairingFrame carrying the canonical `cancelled` Enrollment v1
message.
