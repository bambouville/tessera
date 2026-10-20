package com.bambouville.tessera.security

import java.util.UUID

enum class SshPublicKeyAlgorithm {
    ECDSA_SHA2_NISTP256,
}

enum class SshSignatureAlgorithm {
    ECDSA_SHA2_NISTP256,
}

enum class KeySecurityLevel {
    SOFTWARE,
    TRUSTED_ENVIRONMENT,
    STRONGBOX,
    UNKNOWN_SECURE,
    UNKNOWN,
}

data class SignerCapabilities(
    val algorithm: SshPublicKeyAlgorithm,
    val exportable: Boolean,
    val ownerAuthenticationRequired: Boolean,
    val ownerAuthenticationValiditySeconds: Int?,
    val securityLevel: KeySecurityLevel,
    val strongBoxRequested: Boolean,
    val strongBoxBacked: Boolean,
)

interface CredentialSigner {
    val keyId: UUID
    val algorithm: SshPublicKeyAlgorithm
    val publicKeyBlob: ByteArray
    val capabilities: SignerCapabilities

    suspend fun sign(
        attemptId: UUID,
        policyGeneration: Long,
        payload: ByteArray,
        signatureAlgorithm: SshSignatureAlgorithm,
    ): ByteArray
}

class StaleSigningContextException : SecurityException(
    "The connection attempt or credential policy changed while signing",
)
