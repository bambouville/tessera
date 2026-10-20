package com.bambouville.tessera.feature.session

import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.files.RemoteFilesController
import com.bambouville.tessera.networking.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** Cancellation during native SFTP preparation, without opening a host. */
class AgentAttachmentLifetimeInstrumentedTest {
    @Test fun cancellationAndDisposalResolveBeforeConnectionExists(): Unit = runBlocking {
        for (dispose in listOf(false, true)) {
            val entered = CompletableDeferred<Unit>()
            val stopped = CompletableDeferred<Unit>()
            val controller = withContext(Dispatchers.Main) {
                RemoteFilesController(InstrumentationRegistry.getInstrumentation().targetContext,
                    route = { error("no network") },
                    passwordProvider = SshPasswordProvider { error("no network") },
                    hostKeyPolicy = SshHostKeyPolicy { false },
                    keyAuthorizationProvider = SshKeyAuthorizationProvider { error("no network") },
                    liveConnection = {
                        entered.complete(Unit)
                        try { awaitCancellation() } finally { stopped.complete(Unit) }
                    }, reaperDays = 0)
            }
            val task = async(Dispatchers.Main) { controller.uploadAttachment(Uri.parse("content://fixture/not-opened")) }
            try {
                withTimeout(5_000) { entered.await() }
                if (dispose) withContext(Dispatchers.Main) { controller.cancelPendingTransfers() }
                else task.cancel()
                withTimeout(5_000) {
                    task.join()
                    stopped.await()
                    withContext(Dispatchers.Main) { controller.closeAfterTransfers() }
                }
                assertTrue(task.isCancelled)
                assertTrue(controller.transfers.value.isEmpty())
            } finally {
                task.cancelAndJoin()
                withContext(Dispatchers.Main) { controller.closeAfterTransfers() }
            }
        }
        android.util.Log.i("TesseraAttachmentLifetime", "TESSERA_ATTACHMENT_LIFETIME_OK parent=1 dispose=1")
    }
}
