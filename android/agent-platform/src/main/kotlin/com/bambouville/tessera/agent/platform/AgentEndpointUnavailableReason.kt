package com.bambouville.tessera.agent.platform

/**
 * Every reason an endpoint reports in [AgentEndpointResult.Unavailable] or
 * [AgentEndpointCapabilities.reason]. Results, diagnostics and tests keep
 * [reason], the English an endpoint has always reported; the integration
 * panel and Agent Center notices show [text] in the reader's language.
 */
enum class AgentEndpointUnavailableReason(val reason: String, val text: Int) {
    AgentRuntime("Agent runtime unavailable", R.string.agent_platform_endpoint_agent_runtime_unavailable),
    TerminalUploads("File uploads are unavailable for this terminal", R.string.agent_platform_endpoint_terminal_uploads_unavailable),
    Uploads("File uploads are unavailable", R.string.agent_platform_endpoint_uploads_unavailable),
    ProcessOccupancy("Process occupancy is unavailable for this terminal", R.string.agent_platform_endpoint_process_occupancy_unavailable),
    ProcessRoot("Process root is unavailable", R.string.agent_platform_endpoint_process_root_unavailable),
    MoshProcessRoot("mosh process root is unavailable", R.string.agent_platform_endpoint_mosh_process_root_unavailable),
    ForegroundShellProof("foreground shell proof is unavailable", R.string.agent_platform_endpoint_foreground_shell_proof_unavailable),
    FreshTerminalEvidence("fresh terminal evidence is unavailable", R.string.agent_platform_endpoint_fresh_terminal_evidence_unavailable),
    TerminalCapture("terminal_capture_unavailable", R.string.agent_platform_endpoint_terminal_capture_unavailable),
    LaunchDirectoryUnproven("launch requires a proven SSH+tmux pane directory", R.string.agent_platform_endpoint_launch_directory_unproven),
    RawTransportOneFocus("raw transport has one focused terminal", R.string.agent_platform_endpoint_raw_transport_one_focus),
    RawPromptCapture("raw transport has no authoritative prompt capture yet", R.string.agent_platform_endpoint_raw_prompt_capture_unavailable),
    RawTerminalRoute("raw terminal route unavailable", R.string.agent_platform_endpoint_raw_terminal_route_unavailable),
    RouteProofRejected("remote server did not accept the route proof marker", R.string.agent_platform_endpoint_route_proof_rejected),
    SpawnRequiresTmux("spawn and fork require tmux", R.string.agent_platform_endpoint_spawn_requires_tmux),
    TmuxControl("tmux control is unavailable", R.string.agent_platform_endpoint_tmux_control_unavailable),
    TmuxControlRoute("tmux control route unavailable", R.string.agent_platform_endpoint_tmux_control_route_unavailable),
    RemoteData("remote data unavailable", R.string.agent_platform_endpoint_remote_data_unavailable),
    SessionClosed("session closed", R.string.agent_platform_endpoint_session_closed);

    companion object {
        /** The resource for an endpoint's [reason], or null for words no endpoint here reports. */
        fun textFor(reason: String): Int? = entries.firstOrNull { it.reason == reason }?.text
    }
}
