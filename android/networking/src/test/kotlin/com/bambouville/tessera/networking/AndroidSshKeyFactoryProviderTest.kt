package com.bambouville.tessera.networking

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.Security
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import net.schmizz.sshj.common.ECDSACurve
import net.schmizz.sshj.common.ECDSAKeyFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * SSHJ looks up host-key factories by algorithm name alone, so these aliases must
 * resolve to Tessera's provider. When its services could not be instantiated (R8
 * stripped SPIs registered by class name), JCA silently moved on to AndroidKeyStore.
 */
class AndroidSshKeyFactoryProviderTest {
    @After
    fun removeProvider() {
        Security.removeProvider(AndroidSshKeyFactoryProvider.NAME)
    }

    @Test
    fun everyAliasResolvesToTesserasProvider() {
        AndroidSshKeyFactoryProvider.install()

        for (algorithm in listOf("Ed25519", "EdDSA")) {
            assertEquals(algorithm, AndroidSshKeyFactoryProvider.NAME, KeyFactory.getInstance(algorithm).provider.name)
        }
    }

    /**
     * SSHJ 0.40 rebuilt NIST host keys through a non-standard `ECDSA` factory, which only
     * Tessera's provider offered; 0.41 asks for the standard `EC` one, so there is no alias.
     */
    @Test
    fun sshjRebuildsANistHostKeyWithoutAnEcdsaAlias() {
        AndroidSshKeyFactoryProvider.install()
        val hostKey = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
            .generateKeyPair().public as ECPublicKey

        val rebuilt = ECDSAKeyFactory.getPublicKey(hostKey.w, ECDSACurve.SECP256R1)

        assertEquals(hostKey, rebuilt)
    }

    @Test
    fun installingTwiceKeepsOneProvider() {
        AndroidSshKeyFactoryProvider.install()
        AndroidSshKeyFactoryProvider.install()

        assertEquals(1, Security.getProviders().count { it.name == AndroidSshKeyFactoryProvider.NAME })
    }
}
