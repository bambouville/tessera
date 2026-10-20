package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.continuity.PendingContinuationRecovery

/**
 * Recovery is deliberately narrower than pairing continuation: it can reopen
 * a destination only when the currently resolved route exactly still matches
 * the authenticated metadata. The original encrypted pairing transaction is
 * never reconstructed after process death.
 */
internal object PendingContinuationRecoveryPolicy {
    /**
     * Everything about a resolved route that can be compared without deriving
     * the shared route identity: the route ends at the destination and names
     * each host once.
     *
     * The record's transport and tmux target are the *sender's*; they are not
     * compared with the saved row. The receiver connects over its own row's
     * transport regardless, and the staged tmux target is re-applied as the
     * session override on recovery, so a row whose transport or session mode
     * differs still resumes the same rendezvous — the same reason the live
     * acceptance path ([ContinuationRouteMatchPolicy]) ignores them.
     *
     * Kept separate so the identity — which is the shared core's, reached over
     * the native bridge — is asked for only once the local shape already
     * agrees.
     */
    fun routeShapeMatches(
        record: PendingContinuationRecovery,
        destination: SavedHost?,
        resolvedRoute: List<SavedHost>?,
    ): Boolean {
        val host = destination ?: return false
        val route = resolvedRoute ?: return false
        if (route.isEmpty()) return false
        if (route.last().id != host.id || route.map(SavedHost::id).distinct().size != route.size) return false
        return record.hostId == host.id
    }

    fun matchesCurrentRoute(
        record: PendingContinuationRecovery,
        destination: SavedHost?,
        resolvedRoute: List<SavedHost>?,
    ): Boolean {
        if (!routeShapeMatches(record, destination, resolvedRoute)) return false
        val route = checkNotNull(resolvedRoute)
        return record.routeIdentity == continuationRouteIdentity(checkNotNull(destination), route.dropLast(1))
    }

    fun canOffer(
        record: PendingContinuationRecovery,
        destination: SavedHost?,
        resolvedRoute: List<SavedHost>?,
        credentialUsable: Boolean,
    ): Boolean {
        return credentialUsable && matchesCurrentRoute(record, destination, resolvedRoute)
    }
}
