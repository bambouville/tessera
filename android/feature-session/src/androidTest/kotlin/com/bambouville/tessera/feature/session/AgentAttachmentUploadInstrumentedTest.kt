package com.bambouville.tessera.feature.session

import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentRemoteStreamDrain
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshExecRequest
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRemoteOperation
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import java.io.File
import java.util.Properties
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

import android.net.Uri
import com.bambouville.tessera.files.RemoteFilesController
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlinx.coroutines.withContext
/** Opt-in upload gate against the disposable VPS, using exact owned paths only. */
class AgentAttachmentUploadInstrumentedTest {
    @Test(timeout = 90_000)
    fun productionControllerUploadsUniqueFilesAndKeepsCarrierAlive(): Unit = runBlocking(Dispatchers.IO) {
        val path = InstrumentationRegistry.getArguments().getString("tesseraAttachmentFixture")
        assumeTrue("requires the opt-in disposable VPS runner", path != null)
        val fixture = Properties().apply { File(requireNotNull(path)).inputStream().use(::load) }
        val host = fixture.getProperty("host")
        require(host !in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2"))
        val keys = fixture.getProperty("hostKeyBlobs").split(',').toSet()
        val route = AndroidSshBackend().openRoute(
            SshRouteRequest(listOf(SshRouteHop("composer-upload", SshEndpoint(host, fixture.getProperty("port").toInt()),
                fixture.getProperty("user"), SshAuthentication.Password))),
            SshPasswordProvider { Base64.decode(fixture.getProperty("passwordBase64"), Base64.DEFAULT).decodeToString().toCharArray() },
            SshHostKeyPolicy { Base64.encodeToString(it.canonicalKeyBlob, Base64.NO_WRAP) in keys },
        )
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val local = File(context.cacheDir, "composer-${UUID.randomUUID()}.txt")
        val payload = "Tessera composer upload ${UUID.randomUUID()}\n".repeat(256).encodeToByteArray()
        local.writeBytes(payload)
        val uploaded = mutableListOf<String>()
        val files = route.openFiles()
        val controller = withContext(Dispatchers.Main) { RemoteFilesController(context,
            route = { error("upload must use the captured carrier") },
            passwordProvider = SshPasswordProvider { error("no reconnect") },
            hostKeyPolicy = SshHostKeyPolicy { false },
            keyAuthorizationProvider = SshKeyAuthorizationProvider { error("no key authorization") },
            liveConnection = { route.openFiles() }, reaperDays = 0) }
        try {
            repeat(2) {
                val remote = withTimeout(20_000) { controller.uploadAttachment(Uri.fromFile(local)) }
                uploaded += remote
                assertTrue(remote.contains("/.cache/tessera/paste-"))
                assertEquals(uploaded.size, uploaded.toSet().size)
                val bytes = ByteArrayOutputStream()
                files.download(remote, bytes) { _, _ -> }
                org.junit.Assert.assertArrayEquals(payload, bytes.toByteArray())
                val parent = remote.substringBeforeLast('/')
                assertEquals(0x1C0, files.stat(parent).permissions?.and(0x1FF))
            }
            withContext(Dispatchers.Main) { controller.closeAfterTransfers() }
            assertEquals("route-alive", route.executeBoundedCommand("printf route-alive").standardOutput)
            Log.i("TesseraAttachmentUpload", "TESSERA_ATTACHMENT_UPLOAD_OK files=2 content=verified unique=1 privateDirectory=1 carrierAlive=1")
        } finally {
            withContext(Dispatchers.Main) { controller.closeAfterTransfers() }
            try {
                var cleanupFailure: Throwable? = null
                uploaded.forEach { remote ->
                    runCatching { files.removeFile(remote) }.onFailure { if (cleanupFailure == null) cleanupFailure = it }
                }
                cleanupFailure?.let { throw it }
            } finally { files.close(); route.close(); local.delete() }
        }
    }
}
