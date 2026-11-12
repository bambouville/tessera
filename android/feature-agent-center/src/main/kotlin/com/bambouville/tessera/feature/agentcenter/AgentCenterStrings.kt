package com.bambouville.tessera.feature.agentcenter

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import com.bambouville.tessera.agent.platform.AgentEndpointUnavailableReason
import com.bambouville.tessera.files.R as FilesR
import java.util.Locale

/**
 * The words a thread row's derived text uses (its list identity, its
 * accessibility description, its meter and its last activity), so that text
 * is built, and JVM-tested, outside Compose. This module's unit tests run
 * without Android resources, so they pass English words directly.
 */
internal class AgentRowWords(
    val fork: String,
    val needsInput: String,
    val working: String,
    val idle: String,
    val finished: String,
    val unavailable: String,
    val needsYourAttention: String,
    val host: (String) -> String,
    val queued: (String) -> String,
    val contextPercent: (String) -> String,
    val lineChanges: (String) -> String,
    val now: String,
    val minutesAgo: (Long) -> String,
    val hoursAgo: (Long) -> String,
    val daysAgo: (Long) -> String,
    val inMinutes: (Long) -> String,
    val inHours: (Long) -> String,
    val inDays: (Long) -> String,
)

internal fun Resources.agentRowWords(): AgentRowWords = AgentRowWords(
    fork = getString(R.string.agent_center_fork),
    needsInput = getString(R.string.agent_center_needs_input),
    working = getString(R.string.agent_center_working),
    idle = getString(R.string.agent_center_idle),
    finished = getString(R.string.agent_center_finished),
    unavailable = getString(R.string.agent_center_unavailable),
    needsYourAttention = getString(R.string.agent_center_needs_your_attention),
    host = { getString(R.string.agent_center_host, it) },
    queued = { getString(R.string.agent_center_queued, it) },
    contextPercent = { getString(R.string.agent_center_context_percent, it) },
    lineChanges = { getString(R.string.agent_center_line_changes, it) },
    now = getString(R.string.agent_center_time_now),
    minutesAgo = { getString(R.string.agent_center_time_minutes_ago, it) },
    hoursAgo = { getString(R.string.agent_center_time_hours_ago, it) },
    daysAgo = { getString(R.string.agent_center_time_days_ago, it) },
    inMinutes = { getString(R.string.agent_center_time_in_minutes, it) },
    inHours = { getString(R.string.agent_center_time_in_hours, it) },
    inDays = { getString(R.string.agent_center_time_in_days, it) },
)

/** Reads [LocalConfiguration], so a locale change recomposes every caller. */
@Composable
internal fun rememberAgentRowWords(): AgentRowWords {
    val configuration = LocalConfiguration.current
    val resources = LocalResources.current
    return remember(configuration, resources) { resources.agentRowWords() }
}

/**
 * Resolves this module's strings by id. With no arguments a string comes back
 * as written, placeholders included.
 */
internal fun interface AgentStrings {
    fun get(@StringRes id: Int, vararg args: Any): String
}

internal fun Resources.agentStrings(): AgentStrings =
    AgentStrings { id, args -> if (args.isEmpty()) getString(id) else getString(id, *args) }

/** Notice dialogs and the unavailable state read presenter notices through this. */
@Composable
internal fun rememberAgentNoticeLocalizer(): AgentNoticeLocalizer {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val resources = LocalResources.current
    return remember(context, configuration, resources) { agentNoticeLocalizer(context, resources) }
}

/** [resources] are the reader's; the English the presenter writes comes from the default resources. */
// English resolves to the unqualified `values/` (no module has `values-en`),
// which the base APK always carries: no language split can be missing.
@SuppressLint("AppBundleLocaleChanges")
internal fun agentNoticeLocalizer(context: Context, resources: Resources): AgentNoticeLocalizer {
    val english = Configuration(resources.configuration).apply { setLocale(Locale.ENGLISH) }
    return AgentNoticeLocalizer(context.createConfigurationContext(english).resources.agentStrings(), resources.agentStrings())
}

/**
 * Presenter notices stay English in state: the presenter has no Context, the
 * Send anyway retry compares notices, and tests and diagnostics read them.
 * The dialog shows each in the reader's language by matching it against the
 * English of [AGENT_NOTICES], whole or as sentences ending in one of
 * [AGENT_NOTICE_TRAILING_SENTENCES], or as an endpoint's
 * [AgentEndpointUnavailableReason]. Anything else (a Core code) shows as it
 * came.
 */
internal class AgentNoticeLocalizer(private val english: AgentStrings, private val localized: AgentStrings) {
    private class Template(val id: Int, val pattern: Regex, val positions: List<Int>)

    private val exact: Map<String, Int> by lazy {
        AGENT_NOTICES.map { english.get(it) }.zip(AGENT_NOTICES.asList())
            .filterNot { (text, _) -> PLACEHOLDER.containsMatchIn(text) }.toMap()
    }

    private val templates: List<Template> by lazy {
        AGENT_NOTICES.asList().mapNotNull { id ->
            val text = english.get(id)
            val placeholders = PLACEHOLDER.findAll(text).toList()
            if (placeholders.isEmpty()) return@mapNotNull null
            val pattern = StringBuilder()
            var literalStart = 0
            for (placeholder in placeholders) {
                pattern.append(Regex.escape(text.substring(literalStart, placeholder.range.first))).append("(.+)")
                literalStart = placeholder.range.last + 1
            }
            pattern.append(Regex.escape(text.substring(literalStart)))
            Template(id, Regex(pattern.toString(), RegexOption.DOT_MATCHES_ALL), placeholders.map { it.groupValues[1].toInt() })
        }
    }

    private val trailingSentences: List<Pair<String, Int>> by lazy {
        AGENT_NOTICE_TRAILING_SENTENCES.map { " ${english.get(it)}" to it }
    }

    fun localize(notice: String): String = localizeOrNull(notice) ?: notice

    private fun localizeOrNull(text: String): String? {
        exact[text]?.let { return localized.get(it) }
        AgentEndpointUnavailableReason.textFor(text)?.let { return localized.get(it) }
        for ((tail, id) in trailingSentences) {
            if (text.length <= tail.length || !text.endsWith(tail)) continue
            val head = text.dropLast(tail.length)
            return localized.get(R.string.agent_center_notice_sentences, localizeOrNull(head) ?: head, localized.get(id))
        }
        for (template in templates) {
            val match = template.pattern.matchEntire(text) ?: continue
            val args = arrayOfNulls<Any>(template.positions.max())
            template.positions.forEachIndexed { index, position -> args[position - 1] = match.groupValues[index + 1] }
            return localized.get(template.id, *args.requireNoNulls())
        }
        return null
    }

    private companion object {
        val PLACEHOLDER = Regex("%(\\d+)\\\$s")
    }
}

/** Every notice the presenter, its state helpers and a selection miss write, in English, except a code shown as it came. */
internal val AGENT_NOTICES = intArrayOf(
    R.string.agent_center_notice_runtime_unavailable,
    R.string.agent_center_notice_disabled,
    R.string.agent_center_notice_upload_terminal_unavailable,
    R.string.agent_center_notice_reopen_before_attaching,
    R.string.agent_center_notice_attachment_cancelled,
    R.string.agent_center_notice_upload_stopped,
    R.string.agent_center_notice_upload_unsupported_path,
    R.string.agent_center_notice_uploaded_terminal_changed,
    R.string.agent_center_notice_upload_failed,
    R.string.agent_center_notice_open_terminal_to_continue,
    R.string.agent_center_open_terminal_to_answer,
    R.string.agent_center_notice_action_in_progress,
    R.string.agent_center_notice_action_proof_unavailable,
    R.string.agent_center_notice_send_could_not_start,
    R.string.agent_center_notice_prompt_changed,
    R.string.agent_center_notice_review_prompt,
    R.string.agent_center_notice_original_terminal_unavailable,
    R.string.agent_center_notice_terminal_gone,
    R.string.agent_center_notice_control_pending,
    R.string.agent_center_notice_focus_failed,
    R.string.agent_center_notice_request_unavailable,
    R.string.agent_center_notice_launch_in_progress,
    R.string.agent_center_notice_launch_target_stale,
    R.string.agent_center_notice_session_disconnected,
    R.string.agent_center_notice_launch_authority_unavailable,
    R.string.agent_center_notice_choose_proven_directory,
    R.string.agent_center_notice_launch_invalid,
    R.string.agent_center_notice_launch_no_correlation,
    R.string.agent_center_notice_launch_malformed,
    R.string.agent_center_notice_launch_plan_changed,
    R.string.agent_center_notice_binding_stale,
    R.string.agent_center_notice_process_proof_unavailable,
    R.string.agent_center_notice_process_changed,
    R.string.agent_center_notice_directory_proof_changed,
    R.string.agent_center_notice_split_target_unavailable,
    R.string.agent_center_notice_fork_provenance_unavailable,
    R.string.agent_center_notice_worktree_unacknowledged,
    R.string.agent_center_notice_receipt_not_accepted,
    R.string.agent_center_notice_launch_acknowledged,
    R.string.agent_center_notice_receipt_persistence,
    R.string.agent_center_notice_launch_failed_code,
    R.string.agent_center_notice_agent_launched,
    R.string.agent_center_notice_binding_stale_retry,
    R.string.agent_center_notice_verification_failed,
    R.string.agent_center_notice_action_in_flight,
    R.string.agent_center_notice_terminal_cannot_act,
    R.string.agent_center_notice_input_not_ready,
    R.string.agent_center_notice_terminal_draft,
    R.string.agent_center_notice_launch_request_invalid,
    R.string.agent_center_not_sent_input_not_ready_named,
    R.string.agent_center_not_sent_input_not_ready,
    R.string.agent_center_not_sent_terminal_draft_named,
    R.string.agent_center_not_sent_terminal_draft,
    R.string.agent_center_not_sent_route_changed,
    R.string.agent_center_not_sent_input_unavailable,
    R.string.agent_center_not_sent_unsupported_input_named,
    R.string.agent_center_not_sent_unsupported_input,
    R.string.agent_center_not_sent_plan_mismatch,
    R.string.agent_center_not_sent_receipt_unavailable,
    R.string.agent_center_not_sent_cancelled,
    R.string.agent_center_not_sent_unexpected,
    // A transcript selection's misses: the terminal's own (feature-session's
    // TERMINAL_SESSION_NOT_CONNECTED, also Files' files_terminal_not_connected),
    // RemoteSelectionPathResolver.noDirectoryMessage, and Files' English ones
    // (RemoteFilesController.openTranscriptSelectedPath).
    R.string.agent_center_notice_terminal_not_connected,
    FilesR.string.files_selection_no_directory,
    FilesR.string.files_selection_not_a_path,
    FilesR.string.files_selection_not_found,
    FilesR.string.files_selection_unsupported_type,
    FilesR.string.files_selection_ambiguous,
    FilesR.string.files_route_unavailable,
    FilesR.string.files_connection_unavailable,
)

/** Sentences a notice may end with after another notice: a not-sent message's outcome, then the retry's warning. */
internal val AGENT_NOTICE_TRAILING_SENTENCES = intArrayOf(
    R.string.agent_center_notice_send_anyway_unverified,
    R.string.agent_center_not_sent_merged,
    R.string.agent_center_not_sent_restored,
    R.string.agent_center_not_sent_nothing_typed,
)
