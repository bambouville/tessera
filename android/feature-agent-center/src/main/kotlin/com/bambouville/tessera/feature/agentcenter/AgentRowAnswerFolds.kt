package com.bambouville.tessera.feature.agentcenter

import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateMapOf

/**
 * One question on one thread row. The action token is Core's hash of the
 * prompt screen's signature, so the agent's next question carries a new one.
 */
internal data class AgentRowPromptKey(val threadKey: String, val actionToken: String)

/** How a waiting row presents its answers. */
internal enum class AgentRowAnswerFold {
    /** The answers show on the row. */
    Open,
    /** Folded by hand, on a row whose thread is not open beside the list. */
    Folded,
    /** Folded while the thread is open beside the list: answer there. */
    AnswerBeside,
    ;

    val folded: Boolean get() = this != Open
}

/**
 * A waiting row shows its answers by default. While its thread is open in the
 * detail pane beside the list, the row folds them, so a wide window shows the
 * options once, in the thread. A single-pane list never folds by default: its
 * detail is another route, not beside. Shown means open beside the list, not
 * scrolled into view.
 */
internal fun agentRowAnswersFoldedByDefault(threadKey: String, shownThreadKey: String?, detailBeside: Boolean): Boolean =
    detailBeside && threadKey == shownThreadKey

/**
 * The rows folded or opened by hand. A choice holds for one question: the
 * thread's next question arrives in its default state. In memory only. Same
 * rules as iOS's `AgentRowAnswerFolds`.
 */
internal data class AgentRowAnswerFolds(
    /** Thread key to the question chosen for and whether its row was left open. */
    private val chosen: Map<String, AgentRowAnswerChoice> = emptyMap(),
) {
    fun choice(key: AgentRowPromptKey): Boolean? = chosen[key.threadKey]?.takeIf { it.actionToken == key.actionToken }?.open

    fun fold(key: AgentRowPromptKey, shownThreadKey: String?, detailBeside: Boolean): AgentRowAnswerFold {
        val beside = agentRowAnswersFoldedByDefault(key.threadKey, shownThreadKey, detailBeside)
        return when {
            choice(key) ?: !beside -> AgentRowAnswerFold.Open
            beside -> AgentRowAnswerFold.AnswerBeside
            else -> AgentRowAnswerFold.Folded
        }
    }

    /** The row left [open] by hand. A thread waits on one question at a time, so this replaces its older choice. */
    fun choosing(key: AgentRowPromptKey, open: Boolean): AgentRowAnswerFolds =
        AgentRowAnswerFolds(chosen + (key.threadKey to AgentRowAnswerChoice(key.actionToken, open)))

    /**
     * Forgets a choice once its question is gone: the thread no longer waits,
     * left the list, or now shows another question. An identical question
     * asked later has the same token, and must still arrive in its default
     * state. [waiting] maps each waiting thread to the token it shows, or to
     * null while that is unknown (its row has no projection yet).
     */
    fun retainingCurrent(waiting: Map<String, String?>): AgentRowAnswerFolds {
        val kept = chosen.filter { (thread, choice) ->
            thread in waiting && waiting[thread].let { shown -> shown == null || shown == choice.actionToken }
        }
        return if (kept.size == chosen.size) this else AgentRowAnswerFolds(kept)
    }
}

internal data class AgentRowAnswerChoice(val actionToken: String, val open: Boolean)

/**
 * Each waiting thread and the question its row shows. A row waits when its
 * list summary or its projection says it needs you; either may lag the other,
 * and a flip must not drop while one of them still shows the question.
 */
internal fun agentWaitingQuestions(
    threads: List<AgentThreadRow>,
    projectedDetails: Map<String, AgentThreadDetail>,
): Map<String, String?> {
    val waiting = HashMap<String, String?>()
    for (row in threads) if (row.attention == "needsYou") waiting[row.key] = null
    for ((key, detail) in projectedDetails) {
        if (detail.row.attention != "needsYou") continue
        waiting[key] = detail.prompt?.actionToken
    }
    return waiting
}

/**
 * An answer being typed into a prompt card: the option that takes text, or
 * null for a text-entry prompt's own field, and the text.
 */
internal data class AgentPromptDraft(val actionToken: String, val optionID: String?, val text: String)

/**
 * Each thread's typed answer, held above the list and the detail so a row that
 * folds its answers, or a card shown in the detail instead, keeps the text.
 * A draft answers one question: the next question starts empty. One per
 * thread, replaced as it is typed, so the map stays as small as the list.
 */
@Stable
internal class AgentPromptDrafts {
    private val drafts = mutableStateMapOf<String, AgentPromptDraft>()

    operator fun get(threadKey: String, actionToken: String): AgentPromptDraft? =
        drafts[threadKey]?.takeIf { it.actionToken == actionToken }

    operator fun set(threadKey: String, draft: AgentPromptDraft) {
        drafts[threadKey] = draft
    }
}
