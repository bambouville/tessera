package com.bambouville.tessera.networking

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Plain SSH and SSH+tmux sessions run on a shared route, and their forwarding
 * rules ride that same route. Built without a forwarding factory, every such
 * session reported "forwarding is unavailable on a shared SSH route".
 */
class SshRouteOwnerForwardingTest {
    @Test(timeout = 10_000)
    fun routeOwnedTerminalForwardsOverItsRoute() = runBlocking {
        val client = AuthenticatedFakeClient()
        SshRouteOwner(client, listOf(client)).use { owner ->
            owner.openTerminal(columns = 80, rows = 24).use { terminal ->
                terminal.createForwardingRuntime().close()
            }
        }
    }

    @Test(timeout = 10_000)
    fun routeOwnedTmuxControlForwardsOverItsRoute() = runBlocking {
        val client = AuthenticatedFakeClient()
        SshRouteOwner(client, listOf(client)).use { owner ->
            owner.openTmux(sessionTarget = "main").use { tmux ->
                tmux.createForwardingRuntime().close()
            }
        }
        assertTrue("the fake route never opened a channel", client.sessionsOpened > 0)
    }

    private class AuthenticatedFakeClient : SSHClient() {
        var sessionsOpened = 0

        override fun isConnected() = true

        override fun isAuthenticated() = true

        override fun startSession(): Session {
            sessionsOpened += 1
            val input = ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream()
            return Proxy.newProxyInstance(
                javaClass.classLoader,
                arrayOf(Session::class.java, Session.Shell::class.java, Session.Command::class.java),
            ) { proxy, method, arguments ->
                when (method.name) {
                    "exec", "startShell" -> proxy
                    "allocatePTY", "setEnvVar", "close", "join" -> null
                    "getInputStream", "getErrorStream" -> input
                    "getOutputStream" -> output
                    "getExitStatus" -> null
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === arguments?.firstOrNull()
                    "toString" -> "fake-ssh-session"
                    else -> error("Unexpected fake SSH call: ${method.name}")
                }
            } as Session
        }

        override fun close() = Unit
    }
}
