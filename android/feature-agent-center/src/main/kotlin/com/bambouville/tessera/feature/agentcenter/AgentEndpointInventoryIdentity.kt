package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding

/** Inventory follows focus, but conversation ownership follows the carrier.
 * A future endpoint changing host/protocol under one key still revokes owners. */
internal fun AgentEndpointBinding.retainsAgentThreadOwners(next: AgentEndpointBinding): Boolean =
    key == next.key && hostID == next.hostID && transport == next.transport &&
        tmuxSession == next.tmuxSession
