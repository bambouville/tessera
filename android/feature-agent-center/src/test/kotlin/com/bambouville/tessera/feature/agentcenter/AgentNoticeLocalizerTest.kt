package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointUnavailableReason
import com.bambouville.tessera.files.R as FilesR
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Presenter notices stay English in state and show in the reader's language.
 * The English comes from values/strings.xml; the "reader's language" here
 * names the resource it resolved and its arguments.
 */
class AgentNoticeLocalizerTest {
    private val english: Map<Int, String> by lazy {
        fun strings(path: String, ids: Class<*>): Map<Int, String> {
            val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File(path))
                .getElementsByTagName("string")
            val text = (0 until nodes.length).associate { index ->
                val node = nodes.item(index)
                node.attributes.getNamedItem("name").nodeValue to node.textContent.replace("\\'", "'")
            }
            return ids.fields.mapNotNull { field -> text[field.name]?.let { field.getInt(null) to it } }.toMap()
        }
        // A transcript selection's misses come from Files in English.
        strings("src/main/res/values/strings.xml", R.string::class.java) +
            strings("../files/src/main/res/values/strings.xml", FilesR.string::class.java)
    }
    private val localizer by lazy {
        AgentNoticeLocalizer(
            english = AgentStrings { id, _ -> english[id] ?: "unlisted $id" },
            localized = AgentStrings { id, args -> "reader($id${args.joinToString("") { ", $it" }})" },
        )
    }

    /** What executeLaunchPlan writes when the endpoint fails a launch with a code, spaced as it always read. */
    @Test
    fun aLaunchFailureIsWrappedAndKeepsItsCode() {
        assertEquals(
            "reader(${R.string.agent_center_notice_launch_failed_code}, tmux placement failed)",
            localizer.localize("Launch failed: tmux placement failed"),
        )
    }

    @Test
    fun everyEndpointUnavailableReasonIsTranslated() {
        for (reason in AgentEndpointUnavailableReason.entries) {
            // The runtime's reason is also this module's own notice; either resource reads the same.
            if (reason == AgentEndpointUnavailableReason.AgentRuntime) continue
            assertEquals(reason.name, "reader(${reason.text})", localizer.localize(reason.reason))
        }
        assertEquals(
            "reader(${R.string.agent_center_notice_runtime_unavailable})",
            localizer.localize(AgentEndpointUnavailableReason.AgentRuntime.reason),
        )
    }

    @Test
    fun aPresenterNoticeStillResolvesToItsOwnString() {
        assertEquals(
            "reader(${R.string.agent_center_notice_launch_target_stale})",
            localizer.localize("Launch target is stale"),
        )
    }

    /** The session screen's selection miss writes this English (TERMINAL_SESSION_NOT_CONNECTED). */
    @Test
    fun aSelectionMissOnADisconnectedTerminalIsTranslated() {
        assertEquals(
            "reader(${R.string.agent_center_notice_terminal_not_connected})",
            localizer.localize("The terminal session is not connected"),
        )
    }

    /** Files' misses for a transcript selection (RemoteFilesController.openTranscriptSelectedPath). */
    @Test
    fun aFilesSelectionMissIsTranslated() {
        assertEquals(
            "reader(${FilesR.string.files_selection_not_found}, /srv/app/main.kt)",
            localizer.localize("Not found: /srv/app/main.kt"),
        )
        assertEquals(
            "reader(${FilesR.string.files_selection_no_directory}, src/App.kt)",
            localizer.localize("Can't resolve src/App.kt — no terminal directory is available for a relative path."),
        )
        assertEquals(
            "reader(${FilesR.string.files_selection_not_a_path})",
            localizer.localize("Selection doesn't look like a path."),
        )
        assertEquals(
            "reader(${FilesR.string.files_route_unavailable})",
            localizer.localize("The authenticated SSH route is unavailable"),
        )
    }

    @Test
    fun aCoreCodeShowsAsItCame() {
        assertEquals("tmux_controlled_elsewhere", localizer.localize("tmux_controlled_elsewhere"))
    }
}
