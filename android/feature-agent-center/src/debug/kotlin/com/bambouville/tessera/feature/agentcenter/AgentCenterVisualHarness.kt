package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedAgentSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline

/** Debug-only, host-free fixture scenes for visual and accessibility review. */
enum class AgentCenterHarnessScene(val slug: String, val label: String) {
    PhoneList("agents-list", "agents list"),
    PhonePrompt("agents-prompt", "agents prompt"),
    Markdown("agents-markdown", "agents markdown"),
    TabletSplit("agents-tablet", "agents tablet"),
    Degraded("agents-degraded", "agents degraded"),
    Spawn("agents-spawn", "agents spawn"),
    Fork("agents-fork", "agents fork"),
}

@Composable
fun AgentCenterVisualHarness(scene: AgentCenterHarnessScene, modifier: Modifier = Modifier) {
    val fixture = remember { AgentHarnessFixture() }
    // This is a fake port, not an endpoint: harness interactions never reach
    // SSH, tmux, JNI, or the app database.
    val port = remember { FakeAgentHarnessPort() }
    val detail = if (scene == AgentCenterHarnessScene.Degraded) fixture.observeOnlyDetail else fixture.actionableDetail
    when (scene) {
        AgentCenterHarnessScene.PhoneList -> AgentListPane(
            state = fixture.state,
            onSearch = port::search,
            onSelect = port::select,
            onGroupingChange = port::grouping,
            onSpawn = { port.launch(AgentLaunchKind.Spawn) },
            modifier = modifier,
        )
        AgentCenterHarnessScene.PhonePrompt,
        AgentCenterHarnessScene.Degraded -> AgentDetailPane(
            detail = detail,
            draft = "",
            onDraftChange = port::draft,
            onSend = port::send,
            onInterrupt = port::interrupt,
            onPromptAnswer = port::answer,
            onNewestVisible = port::acknowledge,
            onLoadMore = {},
            onOpenTerminal = port::openTerminal,
            onFork = { port.launch(AgentLaunchKind.Fork) },
            onStartSpeech = port::voice,
            modifier = modifier,
        )
        AgentCenterHarnessScene.Markdown -> AgentDetailPane(
            detail = fixture.markdownDetail,
            draft = "",
            onDraftChange = port::draft,
            onSend = port::send,
            onInterrupt = port::interrupt,
            onPromptAnswer = port::answer,
            onNewestVisible = port::acknowledge,
            onLoadMore = {},
            onOpenTerminal = port::openTerminal,
            onFork = { port.launch(AgentLaunchKind.Fork) },
            onStartSpeech = port::voice,
            modifier = modifier,
        )
        AgentCenterHarnessScene.TabletSplit -> Box(modifier.background(LocalTesseraTokens.current.bg)) {
            Row(Modifier.fillMaxSize()) {
                AgentListPane(fixture.state, port::search, port::select, port::grouping, { port.launch(AgentLaunchKind.Spawn) }, Modifier.width(320.dp).fillMaxHeight())
                TesseraHairline(Modifier.width(1.dp).fillMaxHeight())
                AgentDetailPane(
                    detail = fixture.actionableDetail, draft = "", onDraftChange = port::draft, onSend = port::send,
                    onInterrupt = port::interrupt, onPromptAnswer = port::answer, onNewestVisible = port::acknowledge,
                    onLoadMore = {},
                    onOpenTerminal = port::openTerminal, onFork = { port.launch(AgentLaunchKind.Fork) },
                    onStartSpeech = port::voice,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        AgentCenterHarnessScene.Spawn,
        AgentCenterHarnessScene.Fork -> {
            // Kept visible even though the fake port has no executor, exercising
            // the truthful disabled launch state and every form field.
            AgentSpawnSheet(
                kind = if (scene == AgentCenterHarnessScene.Fork) AgentLaunchKind.Fork else AgentLaunchKind.Spawn,
                onDismiss = {}, selected = fixture.actionableDetail, onLaunchRequested = null,
            )
        }
    }
}

private class FakeAgentHarnessPort {
    private var lastInteraction by mutableStateOf("")
    fun search(value: String) { lastInteraction = "search:$value" }
    fun select(value: String) { lastInteraction = "select:$value" }
    fun grouping(value: String) { lastInteraction = "grouping:$value" }
    fun draft(value: String) { lastInteraction = "draft:$value" }
    fun send() { lastInteraction = "send" }
    fun interrupt() { lastInteraction = "interrupt" }
    fun answer(prompt: AgentPrompt, answer: AgentPromptAnswerChoice) { lastInteraction = "answer:${prompt.actionToken}:$answer" }
    fun acknowledge(value: String) { lastInteraction = "ack:$value" }
    fun openTerminal() { lastInteraction = "open-terminal" }
    fun voice() { lastInteraction = "voice" }
    fun launch(value: AgentLaunchKind) { lastInteraction = "launch:$value" }
}

private class AgentHarnessFixture {
    private val summary = SharedAgentValue.ObjectValue(mapOf(
        "id" to SharedAgentValue.ObjectValue(mapOf(
            "hostID" to SharedAgentValue.StringValue("fixture-host"),
            "providerID" to SharedAgentValue.StringValue("claude"),
            "providerSessionID" to SharedAgentValue.StringValue("fixture-session"),
        )),
        "title" to SharedAgentValue.StringValue("Review release notes"),
        "providerName" to SharedAgentValue.StringValue("Claude Code"),
        "model" to SharedAgentValue.StringValue("fixture model"),
        "preview" to SharedAgentValue.StringValue("Waiting for deployment choice"),
        "status" to SharedAgentValue.StringValue("waitingForInput"),
        "attention" to SharedAgentValue.StringValue("needsYou"),
        "projectBasename" to SharedAgentValue.StringValue("tessera"),
        "branch" to SharedAgentValue.StringValue("feature/agents"),
        "availability" to SharedAgentValue.ObjectValue(mapOf(
            "actions" to SharedAgentValue.BooleanValue(true),
            "spawn" to SharedAgentValue.BooleanValue(true),
            "fork" to SharedAgentValue.BooleanValue(true),
        )),
    ))
    private val prompt: SharedAgentValue.ObjectValue = run {
        val wire = SharedAgentValue.ObjectValue(mapOf(
            "token" to SharedAgentValue.ObjectValue(mapOf("rawValue" to SharedAgentValue.StringValue("fixture-token"))),
            "title" to SharedAgentValue.StringValue("Choose deployment"),
            "detail" to SharedAgentValue.StringValue("Fixture prompt; no remote action is possible."),
            "options" to SharedAgentValue.ArrayValue(listOf(
                SharedAgentValue.ObjectValue(mapOf("id" to SharedAgentValue.StringValue("safe"), "label" to SharedAgentValue.StringValue("Safe"))),
                SharedAgentValue.ObjectValue(mapOf("id" to SharedAgentValue.StringValue("fast"), "label" to SharedAgentValue.StringValue("Fast"))),
            )),
        ))
        SharedAgentValue.ObjectValue(mapOf(
            "actionPrompt" to SharedAgentValue.ObjectValue(mapOf("_0" to wire)),
        ))
    }
    private fun detailSnapshot(capabilities: String): SharedAgentSnapshot {
        val binding = SharedAgentValue.ObjectValue(mapOf(
            "liveSessionID" to SharedAgentValue.StringValue("fixture-live-session"),
            "tmuxSession" to SharedAgentValue.StringValue("main"),
            "windowID" to SharedAgentValue.StringValue("@1"),
            "paneID" to SharedAgentValue.StringValue("%2"),
            "capabilities" to SharedAgentValue.NumberValue(capabilities),
        ))
        val messages = SharedAgentValue.ArrayValue(listOf(
            SharedAgentValue.ObjectValue(mapOf(
                "recordID" to SharedAgentValue.StringValue("fixture-message"),
                "role" to SharedAgentValue.StringValue("assistant"),
                "blocks" to SharedAgentValue.ArrayValue(listOf(
                    SharedAgentValue.ObjectValue(mapOf("text" to SharedAgentValue.ObjectValue(mapOf(
                        "_0" to SharedAgentValue.StringValue("I found two deploy options."),
                    )))),
                    prompt,
                )),
            )),
        ))
        val thread = SharedAgentValue.ObjectValue(mapOf(
            "summary" to summary,
            "binding" to binding,
            "messages" to messages,
        ))
        return SharedAgentSnapshot(
            runtimeGeneration = 1,
            kind = SharedAgentSnapshotKind.Thread,
            payload = SharedAgentValue.ObjectValue(mapOf("thread" to thread)),
        )
    }

    val actionableDetail = requireNotNull(AgentPresentation.detail(detailSnapshot("8")))
    val observeOnlyDetail = requireNotNull(AgentPresentation.detail(detailSnapshot("1")))
    val markdownDetail = actionableDetail.copy(
        row = actionableDetail.row.copy(title = "Markdown sample", preview = null),
        live = listOf(AgentBlock("assistant", AGENT_MARKDOWN_VERIFICATION_SAMPLE, kind = "text", recordID = "fixture-markdown")),
        hasMore = false,
        prompt = null,
    )
    val state = AgentCenterUiState(
        loading = false,
        threads = listOf(actionableDetail.row),
        selectedThreadKey = actionableDetail.row.key,
        detail = actionableDetail,
    )
}

/** Mirrors `AgentMarkdownDocument.verificationSample` in shared Swift Core. */
internal const val AGENT_MARKDOWN_VERIFICATION_SAMPLE = "# Deployment summary\n\nThe **migration** completed with `0` failures.\n\n- [x] Back up state\n- [ ] Verify the remote host\n\n| Check | Result |\n| :--- | ---: |\n| Tests | passing |\n\n```sh\ntessera status\n```"
