package com.bambouville.tessera.networking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Files keys interrupted-upload cleanup by route identity, so it must name one machine. */
class SshRouteIdentityTest {
    private val hops = listOf(
        SshRouteHop("jump", SshEndpoint("bastion.example", 2222), "jump", SshAuthentication.Password),
        SshRouteHop("host", SshEndpoint("10.0.0.5", 22), "pi", SshAuthentication.Password),
    )

    @Test
    fun theSameAccountsAndHostKeyAlwaysGiveTheSameIdentity() {
        val identity = AndroidSshBackend.routeIdentity(hops, key(1))

        assertEquals(identity, AndroidSshBackend.routeIdentity(hops.map { it.copy(id = "renamed") }, key(1)))
        assertEquals(
            "jump@bastion.example:2222 > pi@10.0.0.5:22 ssh-ed25519 SHA256:MwmEfO5FS0+Z3P6P3FURp7oWjOC25WhO9z+QMNAJuLU",
            identity,
        )
    }

    @Test
    fun anotherMachineBehindTheSameAddressIsAnotherRoute() {
        assertNotEquals(AndroidSshBackend.routeIdentity(hops, key(1)), AndroidSshBackend.routeIdentity(hops, key(2)))
        assertNotEquals(AndroidSshBackend.routeIdentity(hops, key(1)), AndroidSshBackend.routeIdentity(hops.takeLast(1), key(1)))
    }

    private fun key(seed: Int) = SshHostKeyObservation("10.0.0.5", 22, "ssh-ed25519", ByteArray(51) { (it * seed).toByte() })
}
