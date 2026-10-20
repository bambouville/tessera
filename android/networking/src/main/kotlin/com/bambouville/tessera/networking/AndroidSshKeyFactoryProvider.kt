package com.bambouville.tessera.networking

import java.security.Key
import java.security.KeyFactory
import java.security.KeyFactorySpi
import java.security.PrivateKey
import java.security.Provider
import java.security.PublicKey
import java.security.Security
import java.security.spec.KeySpec
import org.conscrypt.Conscrypt

/**
 * Narrow Android JCA adapter for SSHJ 0.40 host-key parsing.
 *
 * AndroidKeyStore advertises Ed25519 KeyFactory support but intentionally rejects imported
 * X.509 public keys, while SSHJ also asks for the non-standard `ECDSA` KeyFactory alias. This
 * provider owns only those aliases and delegates imported public-key work to Android's ordinary
 * software crypto provider. It does not implement cryptography or intercept Keystore signatures.
 */
internal object AndroidSshKeyFactoryProvider {
    const val NAME = "TesseraSshKeyFactory"
    private val importProvider: Provider by lazy { Conscrypt.newProvider() }

    @Synchronized
    fun install() {
        if (Security.getProvider(NAME) != null) return
        check(Security.insertProviderAt(TesseraSshProvider(), 1) > 0) {
            "failed to install Android SSH key-factory aliases"
        }
    }

    fun importedKeys(): Provider = importProvider
}

@Suppress("DEPRECATION")
private class TesseraSshProvider : Provider(
    AndroidSshKeyFactoryProvider.NAME,
    1.0,
    "Android-safe imported SSH host-key factories",
) {
    init {
        put("KeyFactory.Ed25519", AndroidEd25519KeyFactorySpi::class.java.name)
        put("KeyFactory.EdDSA", AndroidEd25519KeyFactorySpi::class.java.name)
        put("KeyFactory.ECDSA", AndroidEcKeyFactorySpi::class.java.name)
    }
}

class AndroidEd25519KeyFactorySpi : DelegatingKeyFactorySpi("Ed25519")

class AndroidEcKeyFactorySpi : DelegatingKeyFactorySpi("EC")

abstract class DelegatingKeyFactorySpi(
    private val algorithm: String,
) : KeyFactorySpi() {
    private val delegate: KeyFactory by lazy {
        if (algorithm == "Ed25519") {
            KeyFactory.getInstance(algorithm, AndroidSshKeyFactoryProvider.importedKeys())
        } else Security.getProviders().asSequence()
            .filterNot {
                it.name == AndroidSshKeyFactoryProvider.NAME || it.name == "AndroidKeyStore"
            }
            .mapNotNull { provider ->
                runCatching { KeyFactory.getInstance(algorithm, provider) }.getOrNull()
            }
            .firstOrNull()
            ?: error("Android has no import-capable $algorithm KeyFactory")
    }

    override fun engineGeneratePublic(keySpec: KeySpec): PublicKey =
        delegate.generatePublic(keySpec)

    override fun engineGeneratePrivate(keySpec: KeySpec): PrivateKey =
        delegate.generatePrivate(keySpec)

    override fun <T : KeySpec> engineGetKeySpec(key: Key, keySpec: Class<T>): T =
        delegate.getKeySpec(key, keySpec)

    override fun engineTranslateKey(key: Key): Key = delegate.translateKey(key)
}
