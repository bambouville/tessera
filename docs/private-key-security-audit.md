# Private-key security audit and remediation record

> **Published remediation record.** The original audit findings below are
> retained for accountability; all 15 findings were remediated before release.
>
> Audit date: 2026-07-10
> Scope: Tessera private-key generation, import, persistence, recovery, deletion,
> authentication use, UI exposure, SSH/Mosh/tmux side channels, diagnostics, and
> relevant dependency behavior.
> Status: All 15 findings remediated in the working tree. Automated verification
> completed on 2026-07-10; simulator handoff status is recorded below.

The evidence sections below preserve the original audit state. The remediation
ledger is authoritative for the current implementation; line numbers in the
historical evidence may have drifted.

## Executive summary

All findings are remediated in the working tree. Software Ed25519 keys now have
standard passphrase-encrypted OpenSSH recovery, truthful backup/missing-material
state, and migratable non-synchronizing Keychain storage. Secure Enclave keys
remain nonexportable. Deletion is confirmed, dependency-aware, compensating, and
can revoke tracked remote authorizations with an alternate credential.

Protected key use is enforced by Keychain/Secure Enclave access control and a
fresh, revocable connection policy. Secret-bearing import and Mosh bootstrap
surfaces are redacted, secret ownership is shortened, RSA/SHA-1 is disabled,
release raw-key fallback is removed, and SwiftNIO is upgraded to 2.100.0.

No Critical finding was identified. The original audit contained two High,
eight Medium, two Low, and three Informational findings; all 15 are closed by the
controls in the remediation ledger.

## Remediation order (completed)

1. **P0: Make software keys recoverable before they can be installed remotely.**
2. **P0: Make deletion confirmed, referentially safe, and transactionally ordered.**
3. **P1: Enforce protected key use at the Keychain/Secure Enclave boundary.**
4. **P1: Make all Keychain + SwiftData lifecycle operations status-checked and
   compensating/transactional.**
5. **P1: Fix import disclosure, live-session policy drift, and Mosh-key logging.**
6. **P2: Replace legacy RSA-SHA1, shorten secret memory lifetime, remove legacy
   file keys, upgrade dependencies, and fill test gaps.**

## Transport coverage

Tessera's four transport combinations were reviewed explicitly.

| Transport | Private-key path | Audit result |
|---|---|---|
| Plain SSH | Fresh `ResolvedSSHConnection` -> Keychain -> Citadel/NIOSSH | Shared enforced policy; one-shot software-key auth object |
| SSH + tmux | Same SSH connection and resolver | No separate private-key fork |
| Mosh | Fresh SSH bootstrap policy, then UDP Mosh | Bootstrap closes; session key is redacted and cleared during teardown |
| Mosh + tmux | Fresh bootstrap plus fresh SSH `-CC` side-channel policy | Policy/key rotation is re-read for every SSH leg |
| Files/install/revoke | Fresh `ResolvedSSHConnection` for every operation | Same boundary protection, app-lock revocation, and host-key validation |

Live connection automation is intentionally excluded: Tessera never initiates a
connection to the user's hosts during testing. The shared resolver and race
tests cover the four transport combinations; final end-to-end authentication is
part of the manual regression checklist when the user next opens each transport.

## Remediation ledger

| ID | Status | Implemented control | Verification |
|---|---|---|---|
| PK-001 | Closed | Encrypted standard OpenSSH Ed25519 export/verify/restore under the existing UUID; migratable non-synchronizing software-key storage; recovery and missing-material states; install gate | `KeyStoreSecurityTests`; external `ssh-keygen` decryption/fingerprint check; missing-material restore test |
| PK-002 | Closed | Nonanimated dependency-aware confirmation; tracked remote installs; semantic key-identity revocation using a freshly revalidated alternate credential; atomic metadata/reference removal followed by a durable non-secret forward-deletion journal | Persistence-boundary/journal recovery tests; 19 authorized-key installer tests including changed comments/options and stale-credential rejection |
| PK-003 | Closed | `.userPresence` Keychain ACL for protected software keys and `.privateKeyUsage + .userPresence` for new Enclave keys; evaluated `LAContext` bound to retrieval; truthful UI and rotation requirement | ACL query/protection tests; auth-policy tests |
| PK-004 | Closed | Generation-based app-lock revocation cancels pending attempts and atomically rejects/cleans values that complete at the handoff boundary; late biometric completions cannot populate grants | `BiometricRevocationRaceTests` and pending-attempt handoff tests |
| PK-005 | Closed | Typed checked Security operations, injectable Keychain client and persistence boundary, checked lifecycle/migration, compensated protection changes, and crash-recoverable deletion | `KeyStoreSecurityTests` Keychain + persistence failure matrix |
| PK-006 | Closed | File import explains boundary protection, offers owner-auth Keychain storage, and clears passphrase/source buffers after one use | Correct/wrong passphrase encrypted-source import tests and UI review |
| PK-007 | Closed | File importer replaces the PEM text editor; 1 MiB cap; capture/background privacy shield and immediate secret clearing | Compile-time UI review and lifecycle handlers |
| PK-008 | Closed | Every fresh SSH leg re-fetches host, credential, key algorithm, protection, and global policy; identity-bound password provenance/revisions and observed mutation generations close stale-password and A→B→A reuse; missing key metadata fails closed | `SSHAuthenticationPolicyRaceTests` and biometric race tests |
| PK-009 | Closed | Mosh errors no longer carry raw output; centralized redaction validates ports before preserving fields and scrubs malformed, split, escaped, padded, and bare key payloads from diagnostics | `MoshBootstrapTests` redaction/diagnostic matrix |
| PK-010 | Closed | RSA import and legacy RSA authentication are disabled because the current Citadel path only offers RSA/SHA-1 | `KeyStoreSecurityTests` rejection checks |
| PK-011 | Closed | One-shot software auth delegate releases key material after offering it; Swift/native Mosh printable and redundant raw credentials are cleared after handoff; native constructor, invariant-error, crypto, and teardown buffers are scope-wiped | `KeyStoreSecurityTests`; `MoshSecretLifetimeTests` |
| PK-012 | Closed | Raw Documents-key authentication is compiled out of Release; DEBUG migration protects/excludes, verifies Keychain insertion, then removes source and clears data | DEBUG migration tests; Release artifact string scan |
| PK-013 | Closed | No-op agent-forwarding control is hidden; persisted field retained only for schema compatibility | UI/source review |
| PK-014 | Closed | Deterministic Keychain, recovery, integrity, lifetime, biometric-race, policy-race, redaction, and native-secret tests added | Tessera and MoshBridge test suites |
| PK-015 | Closed | SwiftNIO upgraded from 2.97.1 to 2.100.0; call-site reachability review found no Tessera path capable of attacker-controlled >`UInt32.max` ByteBuffer indexing | Resolved-package inspection, Release build, boundary review |

## Historical findings and remediation targets

### PK-001 — High — Software keys are not recoverable after device loss

**Evidence**

- Ed25519, software P-256, imported Ed25519, and imported RSA all call
  `storeKeyData`: `Tessera/KeyStore.swift:32-50`, `:90-104`, `:112-152`.
- Every software-key item uses
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
  `Tessera/KeyStore.swift:234-242`.
- Apple documents that this accessibility class does not migrate to a new
  device:
  <https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly>
- Only Secure Enclave generation warns that loss of the device loses the key:
  `Tessera/Keys/GenerateKeyModal.swift:103-125`.
- The non-Enclave `export private key…` control has an empty action:
  `Tessera/Keys/KeysPageView.swift:288-297`.
- SwiftData stores only public metadata and UUID references:
  `Tessera/StoredKey.swift:4-14`, `Tessera/Identity.swift:29-39`.
- Session restore treats a `StoredKey` metadata row as sufficient and does not
  verify the Keychain secret: `Tessera/SessionRestoreStore.swift:114-131`.

**Preconditions**

- The device is lost, replaced, reset, or restored onto different hardware; or
- the Keychain item disappears while SwiftData metadata remains; and
- the Tessera key is the only remaining credential authorized on a host.

**Impact**

- Permanent account or host lockout.
- Restored metadata can present a key as configured even though it cannot sign.
- Automatic session restore can repeatedly attempt an unrecoverable identity.

**Recommended fix**

Implement both layers for non-Enclave software keys:

1. A user-controlled, passphrase-encrypted, standard OpenSSH recovery export.
   Do not invent a Tessera-only encryption format. Do not write a plaintext
   intermediate to Documents or a long-lived temporary file.
2. A product decision on migratable Apple backups. Recommended default:
   `kSecAttrAccessibleWhenUnlocked` for software keys, without enabling
   `kSecAttrSynchronizable` by default. Retain `ThisDeviceOnly` only if Tessera
   intentionally promises local-only storage and relies exclusively on explicit
   encrypted export.

Secure Enclave keys must remain device-bound and nonexportable. Apple documents
that inability to transfer their private material is fundamental to their
security:
<https://developer.apple.com/documentation/Security/protecting-keys-with-the-secure-enclave>

Add a creation/recovery state machine:

- `notBackedUp`
- `backupExported(date, fingerprint)`
- `deviceBoundUnrecoverable` for Secure Enclave
- `missingPrivateMaterial`

Before `copy to host` or remote installation, require either a completed backup
or an explicit acknowledgement that the key is unrecoverable. For Secure Enclave
keys, recommend installing a second recoverable credential on the host.

Recovery import should derive the public fingerprint, match an existing
metadata-only `StoredKey`, and restore the secret under that existing key ID so
all `Identity` and host references repair automatically.

**Acceptance criteria**

- A generated Ed25519 key can be exported as a passphrase-protected standard
  OpenSSH private key and imported by OpenSSH outside Tessera.
- A recovery file imported on a clean simulator produces the same public
  fingerprint and authenticates through all four transport combinations.
- A restored SwiftData row without matching Keychain material is visibly marked
  missing and is not eligible for automatic session restore.
- No plaintext private-key file remains in Documents, tmp, pasteboard, logs, or
  a share-extension container after export.
- Secure Enclave keys never expose an export action and require a clear
  unrecoverability acknowledgement before remote installation.

### PK-002 — High — One tap can irreversibly destroy an in-use key

**Evidence**

- `delete key` invokes deletion immediately with no alert or confirmation:
  `Tessera/Keys/KeysPageView.swift:288-291`.
- `used by` is informational only: `Tessera/Keys/KeysPageView.swift:392-437`.
- Deletion removes Keychain material first, then deletes the model row and saves:
  `Tessera/Keys/KeysPageView.swift:451-455`.
- Save failure is only logged after the private material is already gone:
  `Tessera/Keys/KeysPageView.swift:486-491`.
- `CredentialMode.key(UUID)` references are not detached or repaired:
  `Tessera/Identity.swift:29-39`.
- Successful remote installations are not maintained as a durable installation
  inventory: `Tessera/Keys/InstallKeyToHostFlow.swift:299-331`.

**Preconditions**

- Accidental tap or malicious local interaction with an unlocked app.

**Impact**

- Permanent loss of the sole local credential.
- Hosts and identities continue pointing at a missing key.
- Remote `authorized_keys` entries remain valid even though Tessera can no longer
  use or revoke the credential.
- Multiple hosts may be affected by one shared key.

**Recommended fix**

- Present a nonanimated confirmation containing the key fingerprint, backup
  status, number of local identities/hosts, and known remote installations.
- Label the action precisely: `delete local private key`; do not imply remote
  revocation.
- Block deletion until local references are detached/reassigned, or perform the
  reference update in the same explicit workflow.
- Offer remote revocation where a reachable alternate credential exists.
- If remote placement is not tracked, state that the user must remove the public
  key manually from every host.
- Make deletion compensating: do not destroy the Keychain secret until model
  changes are validated and ready to commit; if the final Keychain delete fails,
  surface failure and retain consistent metadata.

**Acceptance criteria**

- A single tap cannot delete a key.
- A key referenced by any identity produces a dependency-aware confirmation.
- Cancel leaves Keychain, metadata, identities, and sessions unchanged.
- Injected SwiftData and Keychain failures cannot produce an unreported partial
  delete.
- The UI distinguishes local deletion from remote authorization revocation.

### PK-003 — Medium — “Face ID per use” is not enforced at the key boundary

**Evidence**

- The UI promises `prompt biometric each time this key signs`:
  `Tessera/Keys/KeysPageView.swift:259-269`.
- The app performs one check before resolving the key:
  `Tessera/SSHAuth.swift:53-68`.
- A successful result is cached for 30 seconds by host UUID:
  `Tessera/Security/BiometricSessionCache.swift:14-40`.
- `BiometricGate` uses `.deviceOwnerAuthentication`, which allows device-passcode
  fallback rather than requiring Face ID: `Tessera/Security/BiometricGate.swift:10-30`.
- Software Keychain items have no `kSecAttrAccessControl`:
  `Tessera/KeyStore.swift:234-242`.
- Secure Enclave keys use only `.privateKeyUsage`, without `.userPresence` or
  `.biometryCurrentSet`: `Tessera/KeyStore.swift:57-74`.
- The protection flag is ordinary SwiftData metadata:
  `Tessera/StoredKey.swift:15-22`.

Apple documents that Keychain ACLs are evaluated by the Secure Enclave and can
require user presence or the current biometric enrollment:
<https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web>

**Preconditions**

- Knowledge of the device passcode; or
- code execution inside Tessera while the device is unlocked; or
- another signing/authentication leg within the 30-second grant window.

**Impact**

- The control does not provide the property stated by the UI.
- Software keys remain extractable to compromised in-process code after device
  unlock.
- Enclave keys remain nonextractable, but compromised in-process code can request
  signatures without an OS-enforced presence check.

**Recommended fix**

- For protected software-key items, use `kSecAttrAccessControl` with the product's
  intended constraint: `.biometryCurrentSet` for biometric-only semantics or
  `.userPresence` for biometric-or-passcode semantics.
- For new Secure Enclave keys, create them with `.privateKeyUsage` combined with
  the selected user-presence constraint.
- Rename the UI if the intended behavior is one authorization per connection
  burst rather than one authorization per signature.
- Bind any application-level grant to at least `(hostID, endpoint, keyID,
  policyGeneration)`, not host ID alone.
- Changing an Enclave key's ACL may require key rotation; design that migration
  explicitly rather than pretending a SwiftData toggle changes hardware policy.

**Acceptance criteria**

- Direct Keychain retrieval of a protected software key cannot succeed without
  satisfying the configured OS access-control requirement.
- Direct Enclave signing cannot succeed without satisfying the configured OS
  access-control requirement.
- UI wording exactly matches passcode fallback and caching behavior.
- SSH, SSH+tmux, Mosh, Mosh+tmux, files, and install-to-host all share the same
  enforced policy.

### PK-004 — Medium — App lock can race an in-flight biometric grant

**Evidence**

- `lock()` starts grant revocation in an unstructured `Task` and returns:
  `Tessera/Security/AppLockController.swift:19-30`.
- `revokeAll()` clears only completed grants:
  `Tessera/Security/BiometricSessionCache.swift:43-45`.
- It does not cancel `inFlight` tasks.
- A successful in-flight result can subsequently write a new grant:
  `Tessera/Security/BiometricSessionCache.swift:26-39`.
- The pending connection does not recheck app-lock state before loading/using the
  key.

**Preconditions**

- A key-use authentication is in progress as the app locks, backgrounds, or hits
  the idle timeout.

**Impact**

- A connection may continue authenticating behind the lock UI.
- A successful task can repopulate authorization after revocation.
- Because grants are host-ID-only, changing endpoint or identity during the grant
  window can transfer authorization to a different credential context.

**Recommended fix**

- Add a monotonic revocation/policy generation to the cache.
- Cancel and remove all in-flight tasks on lock.
- Reject results whose generation changed while awaiting LocalAuthentication.
- Cancel pending connection/authentication attempts on app lock.
- Recheck lock state and current key policy immediately before Keychain retrieval
  or signing.

**Acceptance criteria**

- A deterministic test can pause biometric evaluation, invoke lock, then return
  success without creating a grant or continuing the connection.
- No background/idle-lock race can leave a valid cached authorization.

### PK-005 — Medium — Keychain and SwiftData lifecycle operations are unchecked and non-atomic

**Evidence**

- `storeKeyData` discards the `SecItemAdd` result:
  `Tessera/KeyStore.swift:234-243`.
- `deleteKey` discards the `SecItemDelete` result:
  `Tessera/KeyStore.swift:223-230`.
- Generation/import returns valid-looking metadata even if Keychain insertion
  failed: `Tessera/KeyStore.swift:32-152`.
- The modal writes Keychain material before separately inserting/saving SwiftData:
  `Tessera/Keys/GenerateKeyModal.swift:165-190`,
  `Tessera/Keys/ImportKeyModal.swift:94-107`.
- Deletion has the inverse unsafe ordering: `Tessera/Keys/KeysPageView.swift:451-455`.
- Password operations repeat the unchecked-status pattern:
  `Tessera/KeychainHelper.swift:19-39`, `:60-68`.

Apple's Keychain guidance says to check every operation's return status:
<https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain>

**Preconditions**

- Keychain failure, duplicate/conflicting item, entitlement problem, protected
  data unavailability, SwiftData failure, migration issue, or storage failure.

**Impact**

- Phantom metadata without a secret.
- Orphaned private material after an operation reported as failed.
- Misleading successful generation/import/deletion.
- Irreversible key loss on partial delete.

**Recommended fix**

- Make every Keychain helper `throws` and preserve the `OSStatus` in a typed,
  non-secret error.
- Centralize key lifecycle in one service that owns compensating actions.
- Create/import: write Keychain -> save metadata -> delete Keychain item and roll
  back the model if metadata save fails.
- Delete: validate/reassign references -> commit metadata intent -> delete the
  Keychain item -> finalize; define and test compensation for each failure point.
- Add an integrity scan that detects metadata-only keys and orphaned Keychain
  items without logging secret data.

**Acceptance criteria**

- Failure injection exists for every `SecItem*` and `ModelContext.save` step.
- Every partial failure leaves a documented, detectable, recoverable state.
- UI success is impossible unless both secret and metadata operations succeed.

### PK-006 — Medium — Import silently removes the source key’s passphrase protection

**Evidence**

- Import accepts a passphrase in ordinary UI wording:
  `Tessera/Keys/ImportKeyModal.swift:32-70`.
- Ed25519 import decrypts the OpenSSH key, then stores only its raw 32-byte seed:
  `Tessera/KeyStore.swift:112-126`.
- `requiresBiometric` defaults to false: `Tessera/StoredKey.swift:28-43`.
- Encrypted RSA is rejected and the user is advised to provide an unencrypted
  key: `Tessera/KeyStore.swift:135-169`.

**Preconditions**

- The user imports a passphrase-protected key and assumes that protection remains
  active after import.

**Impact**

- The independent passphrase protection is replaced by device-unlocked Keychain
  protection without explicit informed consent.
- RSA guidance may cause a plaintext copy to be created outside Tessera and left
  behind.

**Recommended fix**

- State before import: `The passphrase is used once to decrypt this file and is
  not retained. Subsequent protection will be ...`.
- Offer immediate OS-enforced user-presence protection for the imported key.
- Support safe encrypted RSA import instead of directing users to create a
  plaintext source file.
- If retaining passphrase-on-every-use is a product option, store only the
  encrypted standard representation and request the passphrase at authentication;
  do not silently mix the two models.

**Acceptance criteria**

- The user can distinguish import-time passphrase use from per-use protection.
- No workflow recommends creating an unencrypted source key.
- Tests cover correct and incorrect passphrases without logging input or derived
  key material.

### PK-007 — Medium — Private PEM import is exposed to capture and ordinary text-input surfaces

**Evidence**

- PEM and passphrase are held in SwiftUI `@State String` values:
  `Tessera/Keys/ImportKeyModal.swift:11-14`.
- The entire PEM is rendered in a normal visible `TextEditor`:
  `Tessera/Keys/ImportKeyModal.swift:32-57`.
- The passphrase correctly uses `SecureField`, but the key body does not:
  `Tessera/Keys/ImportKeyModal.swift:68-70`,
  `Tessera/Design/Components/Input.swift:13-19`.
- App lock is applied only at background and animates for 0.18 seconds:
  `Tessera/TesseraApp.swift:43-55`,
  `Tessera/Security/AppLockController.swift:28-31`.
- Locking overlays `ContentView`; it does not unmount or clear the import state:
  `Tessera/TesseraApp.swift:172-185`.
- The user can disable background lock.

Apple requires sensitive data to be hidden before UIKit captures the background
snapshot:
<https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background>

**Preconditions**

- App-switcher snapshot, screen recording/sharing, shoulder surfing, an
  overprivileged keyboard, or process-memory access.

**Impact**

- Complete private-key disclosure.
- Multiple immutable `String`/`Data`/text-storage copies can outlive the modal.

**Recommended fix**

- Prefer an explicit paste control or security-scoped file importer over a
  general-purpose multiline editor.
- Mask the key body by default with reveal-on-demand.
- Install an immediate, nonanimated privacy shield on inactive/background while
  sensitive UI is present, independent of the user's app-lock preference.
- Detect active capture and warn or obscure the import surface as appropriate.
- Clear bindings before dismiss/background and minimize immutable secret copies.
  Document that Swift/UIKit cannot guarantee deterministic zeroization.

**Acceptance criteria**

- A simulator app-switcher screenshot never contains PEM text.
- Backgrounding during import clears or securely obscures the secret immediately,
  without animation.
- Cancel and success clear all view-owned secret state.

### PK-008 — Medium — Active sessions use stale key selection and biometric policy for fresh SSH legs

**Evidence**

- `Host` is a value snapshot containing `storedKeyID`:
  `Tessera/Host.swift:10-23`, `:79-109`.
- `SSHSession` and `MoshSession` retain immutable credential/policy snapshots:
  `Tessera/SSHSession.swift:30-35`, `:84-92`,
  `Tessera/MoshSession.swift:138-140`, `:187-195`.
- ContentView computes them once when constructing the live session:
  `Tessera/ContentView.swift:2178-2198`.
- Later Mosh monitor and tmux side-channel connections authenticate using those
  old values: `Tessera/MoshSession.swift:516-538`, `:1169-1189`.
- FileBridge recognizes frozen-credential rotation but can still receive a live
  session's stale `Host`: `Tessera/Files/FileBridge.swift:29-60`,
  `Tessera/SessionView.swift:258-263`, `:1527-1533`.

**Preconditions**

- A user changes key A to key B, changes the host endpoint, or enables biometric
  protection while a live session exists; then a new side-channel SSH connection
  is opened.

**Impact**

- Fresh authentication can continue with key A or an obsolete protection policy.
- A security-policy change does not take effect when the user expects it to.

**Recommended fix**

- Resolve current `PersistedHost`, `StoredKey`, and global policy immediately
  before every fresh SSH connection.
- Alternatively, push policy/credential changes into live sessions and cancel or
  restart every affected side channel.
- Treat key rotation, endpoint changes, and biometric-policy changes as a policy
  generation change that invalidates grants and pending connection attempts.

**Acceptance criteria**

- With Mosh active, rotate A -> B and force tmux/file/monitor reconnection; only B
  may be offered.
- Enabling biometric protection during an active session affects the next fresh
  SSH leg.
- Changing endpoint or identity invalidates any cached biometric grant.

### PK-009 — Medium — Malformed Mosh bootstrap output can disclose the live Mosh session key in logs

**Evidence**

- `MoshBootstrapError` stores raw stdout/stderr:
  `Tessera/MoshBootstrap.swift:16-23`.
- Malformed/missing parser errors retain the full combined transcript:
  `Tessera/MoshBootstrap.swift:234-277`.
- Remote command failure logs raw stderr:
  `Tessera/MoshBootstrap.swift:112-121`.
- `MoshSession` passes `String(describing: error)` directly to `NSLog`:
  `Tessera/MoshSession.swift:297-327`.
- The in-app diagnostics sanitizer does not cover direct `NSLog` sinks:
  `Tessera/Settings/SettingsPageView.swift:306-311`, `:512-548`.
- Tests prove malformed errors retain a candidate key:
  `TesseraTests/MoshBootstrapTests.swift:196-218`.

**Preconditions**

- A malformed `MOSH CONNECT` line includes a valid key, or a failing remote
  command writes a connect line to stderr; and
- an attacker or support recipient can access unified logs while the detached
  server remains reachable.

**Impact**

- Disclosure of the 128-bit symmetric Mosh session credential.
- Potential access to the live detached Mosh server.

**Recommended fix**

- Never store raw bootstrap transcripts in error associated values.
- Parse and retain only bounded, non-secret diagnostics.
- Redact `MOSH CONNECT <port> <key>` before every log/error boundary, including
  `NSLog`.
- Add a centralized sensitive-data redactor used by both unified logs and in-app
  diagnostics.

**Acceptance criteria**

- Malformed stdout and stderr tests containing valid-looking session keys never
  expose the key through `String(describing:)`, `localizedDescription`, `NSLog`,
  or the diagnostic file.

### PK-010 — Medium — Imported RSA uses deprecated SHA-1 `ssh-rsa` without a key-size policy

**Evidence**

- Tessera accepts RSA import and persistence without a modulus-size check:
  `Tessera/KeyStore.swift:135-152`.
- It routes imported RSA into Citadel authentication:
  `Tessera/KeyStore.swift:212-218`.
- Resolved Citadel 0.12.1 declares `ssh-rsa` and hashes/signs with SHA-1:
  `build/DerivedData/SourcePackages/checkouts/Citadel/Sources/Citadel/Algorithms/RSA.swift:140-168`,
  `:212-250`.
- OpenSSH disabled RSA/SHA-1 signatures by default because SHA-1 is broken:
  <https://www.openssh.org/txt/release-8.8>

**Preconditions**

- The user imports an RSA key and connects to a server that accepts legacy
  `ssh-rsa` signatures.

**Impact**

- Use of deprecated signature cryptography.
- Compatibility failures against modern OpenSSH servers.
- Weak/undersized imported RSA keys are not screened by Tessera.

**Recommended fix**

- Support `rsa-sha2-256` and/or `rsa-sha2-512` user-auth signatures.
- Reject RSA keys below the chosen minimum policy, at least 2048 bits.
- Disable RSA import until the implementation can provide modern signatures, or
  label legacy compatibility explicitly.
- Prefer Ed25519 as the default recoverable software key.

**Acceptance criteria**

- Packet-level or server-log verification confirms RSA-SHA2, never `ssh-rsa`.
- 1024-bit and otherwise undersized RSA imports fail with a safe message.
- Modern OpenSSH default configuration accepts the resulting authentication.

### PK-011 — Low — Software keys and session credentials have unnecessarily long process-memory lifetimes

**Evidence**

- Keychain data is copied into `Data`, PEM `String`, and CryptoKit/Citadel key
  objects: `Tessera/KeyStore.swift:188-218`.
- Citadel's auth object retains the private-key offer:
  `build/DerivedData/SourcePackages/checkouts/Citadel/Sources/Citadel/SSHAuthenticationMethod.swift:6-20`,
  `:42-59`.
- Citadel `SSHClient` retains an authentication-method closure for the client's
  entire lifetime even when reconnect is `.never`:
  `build/DerivedData/SourcePackages/checkouts/Citadel/Sources/Citadel/Client.swift:111-140`,
  `:278-319`.
- Tessera retains the client for live SSH and Mosh-tmux sessions:
  `Tessera/SSHSession.swift:229-231`,
  `Tessera/MoshSession.swift:1052-1055`, `:1183-1192`.
- Citadel RSA frees the private exponent with `BN_free`, not `BN_clear_free`:
  `build/DerivedData/SourcePackages/checkouts/Citadel/Sources/Citadel/Algorithms/RSA.swift:167-187`.
- Mosh key material exists in Swift, Objective-C++, and C++ copies and is not
  explicitly cleared on teardown:
  `Tessera/MoshSession.swift:707-767`,
  `Packages/MoshBridge/Sources/MoshBridge/MoshBridge.mm:109-123`,
  `Packages/MoshBridge/Sources/MoshCore/MoshClient.cc:103-145`, `:453-470`.

**Preconditions**

- Process-memory access through debugging, jailbreak, memory corruption, or a
  comparable local compromise.

**Impact**

- A wider window for extracting software private keys or session credentials.
- Secure Enclave keys are not affected in the same way because their scalar does
  not enter application memory.

**Recommended fix**

- Do not retain authentication offers after user authentication completes when
  reconnect is disabled.
- Use signing delegates/closures that minimize raw key exposure where the
  dependency APIs allow it.
- Use wipeable mutable buffers for native secret storage and explicit cleansing
  on teardown.
- Replace `BN_free` with `BN_clear_free` for private RSA material.
- Minimize immutable Swift `String` copies; document where hard zeroization is
  impossible.

**Acceptance criteria**

- Ownership/lifetime tests or instrumentation show that the auth object is
  released after authentication, not after the terminal session ends.
- Native Mosh and RSA secret buffers are explicitly cleared during teardown.

### PK-012 — Low — Legacy/debug raw keys remain supported in file-shared Documents

**Evidence**

- Release code can load legacy private seeds directly from Documents:
  `Tessera/SSHAuth.swift:75-81`, `:118-124`.
- Documents is exposed through Files/Finder sharing:
  `Tessera/Info.plist:5-15`.
- DEBUG seeding mirrors `tessera-dev-key.raw` into Keychain but never removes the
  source file: `Tessera/TesseraApp.swift:351-395`, `:484-497`.
- The seeder invocation is DEBUG-only: `Tessera/TesseraApp.swift:103-109`.

**Preconditions**

- A legacy or development raw seed exists in Documents.

**Impact**

- Direct extraction through Files/Finder, device backup/container tooling, or
  other access to the file-shared Documents container.

**Recommended fix**

- Compile legacy raw-key resolution out of release builds.
- Implement a one-time migration that validates, stores, verifies, then removes
  the raw file.
- Until removal, use complete file protection and exclude development seeds from
  backups. Never reuse the development key outside isolated test hosts.

**Acceptance criteria**

- A release build contains no path that authenticates from a Documents raw seed.
- Successful DEBUG migration removes the source only after verified Keychain
  insertion.

### PK-013 — Informational — Agent-forwarding UI is currently a no-op

**Evidence**

- `StoredKey.agentForwarding` says backend plumbing is deferred:
  `Tessera/StoredKey.swift:23-26`.
- The UI presents an apparently functional toggle:
  `Tessera/Keys/KeysPageView.swift:272-281`.
- No auth-agent channel, `SSH_AUTH_SOCK`, or Citadel forwarding path consumes the
  flag.

**Current security effect**

No remote signing-oracle/private-key forwarding exposure currently exists. The
risk is misleading configuration and future implementation without a threat
model.

**Recommendation**

Hide or label the control unavailable. Before implementation, separately threat
model remote agent requests, destination binding, user confirmation, lifetime,
and Mosh/tmux side-channel behavior.

### PK-014 — Informational — Key lifecycle security tests are largely absent

Existing tests cover public-key formatting, migration schema, session-restore
metadata, and authorized-key command quoting. They do not cover:

- Keychain add/update/delete status failures.
- Keychain/SwiftData compensation at each failure point.
- Recovery export/import round trips.
- Metadata restored without Keychain material.
- Safe deletion and identity reference repair.
- Keychain/Enclave ACL enforcement.
- Biometric grant revocation and in-flight races.
- Credential/policy rotation during active Mosh sessions.
- Background snapshot redaction during import.
- Mosh session-key log redaction.
- RSA minimum size and RSA-SHA2 negotiation.
- Secret lifetime/cleansing in native code.

Add dependency injection around Security framework operations and biometric
evaluation so these cases can be deterministic unit tests rather than simulator-
only manual checks.

### PK-015 — Informational/unconfirmed — SwiftNIO version is in an affected advisory range

**Evidence**

- `Tessera.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  pins SwiftNIO 2.97.1.
- CVE-2026-43671 / GHSA-r3rc-9hpw-54v9 affects SwiftNIO through 2.99.0 and is
  patched in 2.100.0:
  <https://github.com/advisories/GHSA-r3rc-9hpw-54v9>

**Audit assessment**

The upstream advisory is High severity, but its memory-safety path requires an
attacker-influenced ByteBuffer index/length exceeding `UInt32.max`. This focused
audit did not establish a reachable Tessera SSH/Mosh path meeting that condition,
so this is not counted as a confirmed Tessera vulnerability.

**Recommendation**

- Upgrade to SwiftNIO 2.100.0 or newer after checking fork/Citadel constraints.
- Run a separate reachability review over SSH packet lengths, file-transfer sizes,
  forwarding, and Mosh bridge boundaries.
- Record the dependency update and reachability result in this document.

## Positive controls to preserve

Do not regress these properties while fixing the findings:

- Software key material is stored in Keychain, not SwiftData:
  `Tessera/KeyStore.swift:234-257`, `Tessera/StoredKey.swift:4-14`.
- The app and share extension declare an app group but no shared Keychain access
  group; default Keychain items are not automatically available to the extension:
  `Tessera/Tessera.entitlements`,
  `TesseraShareExtension/TesseraShareExtension.entitlements`.
- Secure Enclave P-256 uses an Enclave-backed NIOSSH key and does not export the
  scalar: `Tessera/Security/EnclaveAuthDelegate.swift:7-40`.
- A configured missing/corrupt key fails closed instead of falling back to a
  password: `Tessera/SSHAuth.swift:45-73`.
- Plain SSH, Mosh bootstrap, Mosh monitor, Mosh+tmux, files, and authorized-key
  installation reuse the common authentication resolver.
- Every reviewed SSH leg supplies Tessera's TOFU validator and disables automatic
  Citadel reconnect.
- No SSH private-key bytes are intentionally inserted into remote shell commands,
  environment variables, argv, diagnostic messages, or the session-restore
  document.
- Copy-to-pasteboard currently copies only the public authorized-key line:
  `Tessera/Keys/KeysPageView.swift:216-242`.
- The audit found no committed PEM private-key blocks or key artifact files in the
  current Git tree or repository history, excluding vendored dependency fixtures.

## P0 recovery milestone — implemented design

This section preserves the design constraints used to implement PK-001. The
milestone is complete.

### Product behavior

1. Generate the software key and persist it only if Keychain insertion succeeds.
2. Immediately present `protect your recovery key`.
3. Require and confirm an export passphrase. Explain that Tessera cannot recover
   it.
4. Export a standard encrypted OpenSSH private-key file through Files.
5. Record only non-secret backup metadata: completion date and public fingerprint.
6. Enable install/copy-to-host only after successful backup, unless the user
   explicitly chooses device-only/unrecoverable behavior.
7. Provide `verify recovery file` by importing/decrypting it and comparing the
   derived public fingerprint without replacing the live key.
8. Provide `restore missing key` that matches by fingerprint and writes the
   secret under the existing `StoredKey.id`.

### Format and storage constraints

- Use standard passphrase-encrypted OpenSSH private-key format for interoperability.
- Support Ed25519 first if necessary, but do not continue offering software P-256
  generation as recoverable until standard encrypted P-256 export/import exists.
- Do not implement custom encryption around raw seeds unless a standard format is
  truly unavailable and the design receives separate cryptographic review.
- Never place plaintext private material on the general pasteboard.
- Any unavoidable transient file must use complete file protection, exist only for
  the export operation, and be securely removed as far as the platform permits.
- Logs may contain algorithm, public fingerprint, status, and byte count; never
  passphrase, raw key, encrypted file contents, or recovery filename/path.

### Existing-key migration

For each non-Enclave `StoredKey`:

1. Verify the Keychain item exists and derives the stored public fingerprint.
2. Mark missing/mismatched items explicitly; do not silently repair or delete.
3. Mark valid existing keys `notBackedUp` until the user exports/verifies recovery.
4. If adopting migratable `kSecAttrAccessibleWhenUnlocked`, perform a checked,
   failure-safe accessibility migration and verify retrieval afterward.
5. Do not change Secure Enclave item accessibility or claim it is portable.

### Verification requirements

- Generate -> encrypted export -> delete app/container on a disposable simulator
  -> reinstall -> import -> same fingerprint.
- Import the recovery key with OpenSSH/`ssh-keygen` outside Tessera.
- Wrong passphrase, cancelled export, Files-provider failure, Keychain failure, and
  SwiftData failure leave no plaintext or inconsistent success state.
- Missing Keychain secret prevents automatic session restore.
- Recovery rehydrates the existing key ID and all referencing identities.
- SSH, SSH+tmux, Mosh, and Mosh+tmux authenticate after recovery.
- Secure Enclave generation continues to be nonexportable and clearly labeled.

## Verification record

- The aggregate Tessera unit run passed 367/367 tests on the booted iPad Pro
  simulator.
- `KeyStoreSecurityTests`: 29 tests cover encrypted OpenSSH recovery,
  interoperability preconditions, recovery under an existing UUID, missing and
  orphaned material, checked Keychain failures, compensation, ACL attributes,
  accessibility migration, RSA rejection, and one-shot secret ownership.
- `BiometricRevocationRaceTests`: app-lock and policy-generation revocation win
  over in-flight and late authorization results.
- `SSHAuthenticationPolicyRaceTests`: endpoint, key, algorithm, protection, and
  global-policy changes are re-read for later SSH legs.
- `MoshBootstrapTests`: malformed, split, and encoded secret output is redacted
  from both errors and diagnostics.
- `MoshSecretLifetimeTests`: 3/3 package tests show Swift/native Mosh session-key
  ownership is released and native teardown is deterministic.
- `SessionRestoreResolverTests`: missing, mismatched, invalid, and legacy-RSA
  private material fails closed while owner-auth material remains eligible to
  prompt at connection time.
- `RemoteAuthorizedKeysInstallerTests`: revocation removes and verifies the
  semantic SSH key identity despite changed comments/options, rejects malformed
  targets, and revalidates the alternate credential against live policy.
- An encrypted recovery fixture generated by Tessera was decrypted by the host
  `ssh-keygen`, producing the expected Ed25519 public key; the temporary fixture
  and test hook were removed.
- The Release artifact is built and scanned for the removed Documents raw-key
  authentication strings.
- The verified Debug app is installed and launched normally on the user's
  pre-existing booted iPad simulator without resetting its data.
- Three independent adversarial reviewers re-read the integrated lifecycle/UI,
  auth-policy, and Mosh/native changes. Their recovery-format, integrity,
  cancellation, stale-credential, semantic-revocation, and secret-lifetime
  findings were fixed before the final 367-test aggregate run.

The vendored mosh source has security-cleansing changes in its own nested
repository. Before publishing, commit those changes in the mosh fork and then
record the resulting submodule pointer in Tessera; this is repository bookkeeping,
not an unremediated runtime finding. No commits were created during this work.

## External references

- Apple, Keychain `WhenUnlockedThisDeviceOnly`:
  <https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly>
- Apple, Keychain data protection and access control:
  <https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web>
- Apple, Secure Enclave keys:
  <https://developer.apple.com/documentation/Security/protecting-keys-with-the-secure-enclave>
- Apple, hiding sensitive UI before background snapshot:
  <https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background>
- Apple, checking Keychain operation status:
  <https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain>
- OpenSSH 8.8 release notes, RSA/SHA-1 disabled:
  <https://www.openssh.org/txt/release-8.8>
- SwiftNIO advisory GHSA-r3rc-9hpw-54v9:
  <https://github.com/advisories/GHSA-r3rc-9hpw-54v9>
