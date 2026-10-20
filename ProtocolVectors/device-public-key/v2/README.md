# Device public key v2 vectors

V2 uses the platform-neutral `sshBlob` and `protectionClaim` names. A
protection claim is display/audit metadata and never grants authority; peers
must validate the SSH blob and fingerprint independently.
