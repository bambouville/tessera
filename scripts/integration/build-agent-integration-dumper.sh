#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf '%s\n' 'usage: build-agent-integration-dumper.sh OUTPUT MODULE_CACHE' >&2
    exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OUTPUT=$1
MODULE_CACHE=$2
SWIFTC_BIN=${SWIFTC_BIN:-$(command -v swiftc || true)}
if [ -z "$SWIFTC_BIN" ] || [ ! -x "$SWIFTC_BIN" ]; then
    printf '%s\n' 'agent integration dumper build requires swiftc' >&2
    exit 1
fi

mkdir -p "$MODULE_CACHE"
"$SWIFTC_BIN" -O -module-cache-path "$MODULE_CACHE" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Presentation/AgentDisplayText.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostBuildRevision.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentIntegrationRemoval.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentActions.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentComposerEvidence.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/TerminalScreenEvidence.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentPromptGrammar.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentPromptScreens.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentPromptAnswerPlanner.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Actions/AgentOutgoingFrontier.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Domain/AgentDomain.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentIntegrationDecision.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentLifecycle.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentCodexConversationRecovery.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Persistence/AgentMetadata.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Presentation/AgentCodexTranscriptContent.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Presentation/AgentTranscriptGrouping.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Projection/AgentProjection.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Projection/AgentIngestion.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Projection/AgentIngestionWindow.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Projection/AgentProjectionContinuation.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Providers/AgentProviders.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Providers/AgentTierCAdapters.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Reducer/AgentCenterRuntime.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Reducer/AgentContentBudget.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Reducer/AgentOccupancy.swift" \
    "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Search/AgentSearch.swift" \
    "$SCRIPT_DIR/AgentIntegrationSourceDump.swift" \
    "$SCRIPT_DIR/AgentMarkdownDumperStub.swift" \
    -o "$OUTPUT"
