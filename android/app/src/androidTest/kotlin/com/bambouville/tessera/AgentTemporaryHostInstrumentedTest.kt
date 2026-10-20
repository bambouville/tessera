package com.bambouville.tessera

import android.os.Build
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.data.*
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Explicitly authorized disposable-emulator setup, never conversation injection. */
@RunWith(AndroidJUnit4::class)
class AgentTemporaryHostInstrumentedTest {
    @Test fun configureAuthorizedTemporaryTmuxHost() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("temporaryTmux") == "authorized")
        check(args.getString("temporaryHost") == "authorized")
        check(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish")
        val repository = AndroidHostRepository(instrumentation.targetContext)
        val host = repository.observeHosts().first().single()
        check(host.hostname == "10.0.2.2" && host.displayName == "Temporary Mac Test")
        repository.save(HostDraft(id = host.id, displayName = host.displayName, hostname = host.hostname,
            port = host.port, username = host.username, identityId = host.identityId,
            transportKind = TransportKinds.SSH, tmuxMode = TmuxModes.PINNED,
            tmuxTarget = requireNotNull(args.getString("temporaryTmuxTarget"))))
        Unit
    }

    @Test fun prepareAuthorizedTemporaryHost() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        // Setup for the authorized temporary-host workflow only; a plain runtime
        // gate run passes no arguments and must skip it, not fail.
        org.junit.Assume.assumeTrue(args.getString("temporaryHost") == "authorized")
        check(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish") { "Requires an emulator" }
        val context = instrumentation.targetContext
        val hosts = AndroidHostRepository(context)
        check(hosts.observeHosts().first().isEmpty()) { "Requires a fresh disposable app" }
        val configuration = JSONObject(File(requireNotNull(args.getString("configuration"))).readText())
        check(configuration.getString("hostname") == "10.0.2.2")
        val key = AndroidKeystoreCredentialStore().generateP256("agent-test-${UUID.randomUUID()}", false)
        val identity = AndroidIdentityRepository(context).save("Temporary Agent Test",
            CredentialKinds.ANDROID_KEYSTORE_P256, key.alias)
        hosts.save(HostDraft(displayName = configuration.getString("label"), hostname = "10.0.2.2",
            port = configuration.getInt("port"), username = configuration.getString("username"),
            identityId = identity.id, transportKind = TransportKinds.SSH))
        AndroidKnownHostsRepository(context).trust("10.0.2.2", configuration.getInt("port"),
            configuration.getString("algorithm"), Base64.decode(configuration.getString("hostKey"), Base64.DEFAULT))
        AndroidAppPreferences(context).updateAgentCenterEnabled(true)
        File(context.cacheDir, "agent-temporary-public-key").writeText(
            "ecdsa-sha2-nistp256 " + Base64.encodeToString(key.publicKeyBlob, Base64.NO_WRAP) + " tessera-disposable\n")
    }
}
