package com.bambouville.tessera.security

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.KeyStore
import java.security.Signature
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidKeystoreSignerInstrumentedTest {
    @Test
    fun nonExportableP256SignerProducesVerifiableSshSignatureAndRejectsStalePolicy() {
        runBlocking {
            val store = AndroidKeystoreCredentialStore()
            val alias = "tessera-phase-a-${UUID.randomUUID()}"
            try {
                val credential = store.generateP256(
                    alias = alias,
                    ownerAuthenticationRequired = false,
                    requestStrongBox = true,
                    allowStrongBoxFallback = true,
                )
                val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                val privateKey = keyStore.getKey(alias, null)
                val publicKey = keyStore.getCertificate(alias).publicKey
                assertNull(privateKey.encoded)
                assertFalse(credential.capabilities.exportable)
                assertEquals(SshPublicKeyAlgorithm.ECDSA_SHA2_NISTP256, credential.capabilities.algorithm)
                assertNotEquals(KeySecurityLevel.UNKNOWN, credential.capabilities.securityLevel)
                assertTrue(credential.publicKeyBlob.size > 90)

                val attempt = UUID.randomUUID()
                val generation = AtomicLong(41)
                val signer = store.signer(credential) { id, value ->
                    id == attempt && value == generation.get()
                }
                val payload = "tessera-android-keystore-phase-a".encodeToByteArray()
                val sshSignature = signer.sign(
                    attempt,
                    41,
                    payload,
                    SshSignatureAlgorithm.ECDSA_SHA2_NISTP256,
                )
                assertTrue(sshSignature.isNotEmpty())
                val der = SshEcdsaP256Codec.sshBlobToDer(sshSignature)
                assertTrue(Signature.getInstance("SHA256withECDSA").run {
                    initVerify(publicKey)
                    update(payload)
                    verify(der)
                })

                generation.incrementAndGet()
                try {
                    signer.sign(
                        attempt,
                        41,
                        payload,
                        SshSignatureAlgorithm.ECDSA_SHA2_NISTP256,
                    )
                    fail("stale signing context was accepted")
                } catch (_: StaleSigningContextException) {
                    // Expected: the attempt's policy generation no longer authorizes signing.
                }
                Log.i(
                    "TesseraKeystore",
                    "TESSERA_KEYSTORE_SIGNER_OK securityLevel=${credential.capabilities.securityLevel} " +
                        "strongBox=${credential.capabilities.strongBoxBacked} exportable=false",
                )
            } finally {
                store.delete(alias)
            }
        }
    }
}
