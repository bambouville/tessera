package com.bambouville.tessera.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AndroidKeystoreCredentialStore {
    private val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    fun generateP256(
        alias: String,
        ownerAuthenticationRequired: Boolean,
        ownerAuthenticationValiditySeconds: Int? = null,
        requestStrongBox: Boolean = false,
        allowStrongBoxFallback: Boolean = false,
    ): StoredKeystoreCredential {
        require(alias.isNotBlank())
        require(ownerAuthenticationValiditySeconds == null || ownerAuthenticationValiditySeconds >= 0)
        delete(alias)
        try {
            generate(
                alias,
                ownerAuthenticationRequired,
                ownerAuthenticationValiditySeconds,
                requestStrongBox,
            )
        } catch (error: StrongBoxUnavailableException) {
            if (!requestStrongBox || !allowStrongBoxFallback) throw error
            delete(alias)
            generate(alias, ownerAuthenticationRequired, ownerAuthenticationValiditySeconds, false)
        }
        return load(alias, requestStrongBox)
    }

    fun load(alias: String, strongBoxRequested: Boolean = false): StoredKeystoreCredential {
        val privateKey = keyStore.getKey(alias, null) as? PrivateKey
            ?: error("Android Keystore credential is unavailable")
        val certificate = keyStore.getCertificate(alias)
            ?: error("Android Keystore public certificate is unavailable")
        val publicKey = certificate.publicKey as? ECPublicKey
            ?: error("Android Keystore credential is not an EC key")
        val keyInfo = KeyFactory.getInstance(privateKey.algorithm, PROVIDER)
            .getKeySpec(privateKey, KeyInfo::class.java)
        val securityLevel = keyInfo.toSecurityLevel()
        val validity = if (keyInfo.isUserAuthenticationRequired) {
            @Suppress("DEPRECATION")
            keyInfo.userAuthenticationValidityDurationSeconds.takeIf { it >= 0 }
        } else {
            null
        }
        return StoredKeystoreCredential(
            alias = alias,
            keyId = UUID.nameUUIDFromBytes(alias.encodeToByteArray()),
            publicKeyBlob = SshEcdsaP256Codec.publicKeyBlob(publicKey),
            capabilities = SignerCapabilities(
                algorithm = SshPublicKeyAlgorithm.ECDSA_SHA2_NISTP256,
                exportable = privateKey.encoded != null,
                ownerAuthenticationRequired = keyInfo.isUserAuthenticationRequired,
                ownerAuthenticationValiditySeconds = validity,
                securityLevel = securityLevel,
                strongBoxRequested = strongBoxRequested,
                strongBoxBacked = securityLevel == KeySecurityLevel.STRONGBOX,
            ),
        )
    }

    fun signer(
        credential: StoredKeystoreCredential,
        isAuthorized: (UUID, Long) -> Boolean,
    ): CredentialSigner = AndroidKeystoreCredentialSigner(
        keyStore = keyStore,
        credential = credential,
        isAuthorized = isAuthorized,
    )

    fun delete(alias: String) {
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }

    private fun generate(
        alias: String,
        ownerAuthenticationRequired: Boolean,
        ownerAuthenticationValiditySeconds: Int?,
        useStrongBox: Boolean,
    ) {
        val builder = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(ownerAuthenticationRequired)
        if (ownerAuthenticationRequired) {
            val validity = ownerAuthenticationValiditySeconds ?: 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setUserAuthenticationParameters(
                    validity,
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(validity)
            }
        }
        builder.setIsStrongBoxBacked(useStrongBox)
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply {
            initialize(builder.build())
            generateKeyPair()
        }
    }

    private fun KeyInfo.toSecurityLevel(): KeySecurityLevel =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (securityLevel) {
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> KeySecurityLevel.SOFTWARE
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> KeySecurityLevel.TRUSTED_ENVIRONMENT
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> KeySecurityLevel.STRONGBOX
                KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE -> KeySecurityLevel.UNKNOWN_SECURE
                else -> KeySecurityLevel.UNKNOWN
            }
        } else {
            @Suppress("DEPRECATION")
            if (isInsideSecureHardware) KeySecurityLevel.UNKNOWN_SECURE
            else KeySecurityLevel.SOFTWARE
        }

    companion object {
        private const val PROVIDER = "AndroidKeyStore"
    }
}

data class StoredKeystoreCredential(
    val alias: String,
    val keyId: UUID,
    val publicKeyBlob: ByteArray,
    val capabilities: SignerCapabilities,
)

private class AndroidKeystoreCredentialSigner(
    private val keyStore: KeyStore,
    private val credential: StoredKeystoreCredential,
    private val isAuthorized: (UUID, Long) -> Boolean,
) : CredentialSigner {
    override val keyId: UUID = credential.keyId
    override val algorithm: SshPublicKeyAlgorithm = credential.capabilities.algorithm
    override val publicKeyBlob: ByteArray
        get() = credential.publicKeyBlob.copyOf()
    override val capabilities: SignerCapabilities = credential.capabilities

    override suspend fun sign(
        attemptId: UUID,
        policyGeneration: Long,
        payload: ByteArray,
        signatureAlgorithm: SshSignatureAlgorithm,
    ): ByteArray = withContext(Dispatchers.IO) {
        require(signatureAlgorithm == SshSignatureAlgorithm.ECDSA_SHA2_NISTP256)
        if (!isAuthorized(attemptId, policyGeneration)) throw StaleSigningContextException()
        val privateKey = keyStore.getKey(credential.alias, null) as? PrivateKey
            ?: error("Android Keystore credential is unavailable")
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(payload)
            sign()
        }
        if (!isAuthorized(attemptId, policyGeneration)) throw StaleSigningContextException()
        SshEcdsaP256Codec.derToSshBlob(der)
    }
}
