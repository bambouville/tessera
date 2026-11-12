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
 * Narrow Android JCA adapter for SSHJ host-key parsing.
 *
 * AndroidKeyStore advertises Ed25519 KeyFactory support but intentionally rejects imported
 * X.509 public keys. This provider owns only SSHJ's Ed25519 names and delegates imported
 * public-key work to Conscrypt. It does not implement cryptography or intercept Keystore
 * signatures. NIST ECDSA keys need no alias: since 0.41 SSHJ asks for the standard `EC`
 * factory, which Android's own providers import.
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
        // Each service constructs its SPI directly. Registered by class name instead, the
        // SPIs are only ever created by reflection, which R8 cannot see: release builds
        // emptied them into abstract shells, JCA skipped this provider, and host-key
        // parsing fell through to AndroidKeyStore's factory, which refuses imported keys.
        putService(KeyFactoryService(this, "Ed25519") { AndroidEd25519KeyFactorySpi() })
        putService(KeyFactoryService(this, "EdDSA") { AndroidEd25519KeyFactorySpi() })
    }
}

private class KeyFactoryService(
    provider: Provider,
    algorithm: String,
    private val create: () -> KeyFactorySpi,
) : Provider.Service(provider, "KeyFactory", algorithm, KeyFactorySpi::class.java.name, null, null) {
    override fun newInstance(constructorParameter: Any?): Any = create()
}

class AndroidEd25519KeyFactorySpi : KeyFactorySpi() {
    private val delegate: KeyFactory by lazy {
        KeyFactory.getInstance("Ed25519", AndroidSshKeyFactoryProvider.importedKeys())
    }

    override fun engineGeneratePublic(keySpec: KeySpec): PublicKey =
        delegate.generatePublic(keySpec)

    override fun engineGeneratePrivate(keySpec: KeySpec): PrivateKey =
        delegate.generatePrivate(keySpec)

    override fun <T : KeySpec> engineGetKeySpec(key: Key, keySpec: Class<T>): T =
        delegate.getKeySpec(key, keySpec)

    override fun engineTranslateKey(key: Key): Key = delegate.translateKey(key)
}
