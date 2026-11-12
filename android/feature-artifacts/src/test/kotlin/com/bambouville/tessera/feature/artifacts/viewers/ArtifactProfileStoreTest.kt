package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Test

class ArtifactProfileStoreTest {
    private class FakeProfiles(names: List<String>, private val loaded: Set<String> = emptySet()) : ArtifactProfileStore {
        val stored = names.toMutableList()
        val cleared = mutableListOf<String>()
        val attempts = mutableListOf<String>()
        override val names: List<String> get() = stored.toList()
        override fun delete(name: String) {
            attempts += name
            if (name in loaded) throw IllegalStateException("Cannot delete in-use profile $name")
            stored.remove(name)
        }
        override fun clearData(name: String) { cleared += name }
    }

    @Test fun reconciliationDeletesOnlyArtifactProfilesOfHostsThatNoLongerExist() {
        val store = FakeProfiles(listOf("Default", "artifacts-a", "artifacts-b", "artifacts-", "other-c", "artifacts-c"))
        reconcileArtifactProfiles(store, setOf("a"))
        assertEquals(listOf("Default", "artifacts-a", "artifacts-", "other-c"), store.names)
        assertEquals(listOf("artifacts-b", "artifacts-c"), store.attempts)
        assertEquals(emptyList<String>(), store.cleared)
    }

    @Test fun aProfileThisProcessLoadedLosesItsDataNowAndStaysForTheNextStart() {
        val store = FakeProfiles(listOf("artifacts-a", "artifacts-b"), loaded = setOf("artifacts-a"))
        deleteArtifactProfiles(store, listOf("a", "b"))
        assertEquals(listOf("artifacts-a"), store.names)
        assertEquals(listOf("artifacts-a"), store.cleared)
        // At the next start nothing is loaded yet, so reconciliation deletes it.
        val restarted = FakeProfiles(store.names)
        reconcileArtifactProfiles(restarted, emptySet())
        assertEquals(emptyList<String>(), restarted.names)
    }

    @Test fun otherFailuresNeitherThrowNorClearData() {
        val store = object : ArtifactProfileStore {
            val cleared = mutableListOf<String>()
            override val names = listOf("artifacts-a")
            override fun delete(name: String) = throw IllegalArgumentException("Cannot delete the default profile")
            override fun clearData(name: String) { cleared += name }
        }
        deleteArtifactProfiles(store, listOf("a"))
        assertEquals(emptyList<String>(), store.cleared)
    }
}
