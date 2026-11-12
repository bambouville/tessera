package com.bambouville.tessera.security

import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** A strong biometric or the device's PIN, pattern or password: what owner-authenticated keys accept. */
private const val OWNER_AUTHENTICATORS =
    BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL

/** Whether this device can confirm its owner: it has a screen lock. */
fun canConfirmDeviceOwner(context: Context): Boolean =
    context.getSystemService(BiometricManager::class.java)
        ?.canAuthenticate(OWNER_AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

/**
 * Asks the device owner to confirm with a strong biometric or the screen
 * lock, on the system's own prompt. True once they confirm; false when they
 * cancel, the prompt fails or the device has no screen lock. Cancelling the
 * caller dismisses the prompt without an answer.
 */
suspend fun confirmDeviceOwner(context: Context, title: CharSequence, description: CharSequence): Boolean {
    if (!canConfirmDeviceOwner(context)) return false
    val prompt = BiometricPrompt.Builder(context)
        .setTitle(title)
        .setDescription(description)
        .setAllowedAuthenticators(OWNER_AUTHENTICATORS)
        .build()
    return suspendCancellableCoroutine { continuation ->
        val signal = CancellationSignal()
        continuation.invokeOnCancellation { signal.cancel() }
        prompt.authenticate(signal, context.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (continuation.isActive) continuation.resume(true)
            }

            // No onAuthenticationFailed: a biometric that did not match leaves
            // the prompt up for another try or the screen lock.
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (continuation.isActive) continuation.resume(false)
            }
        })
    }
}
