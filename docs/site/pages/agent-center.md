---
title: agent center
nav: 11
description: Watch and answer every Claude Code and Codex session across your connections (experimental).
---

# Agent center

The agent center gathers your Claude Code and Codex sessions from across every
connection — tmux windows, panes, and raw sessions — onto one page, and lets
you answer their prompts without hunting for the right pane. It's
**experimental** and off by default: enable it in
**settings → experimental → agent center**. Turning it off later does not
uninstall host hooks.

Open it from the sidebar's **agents** entry, with **⌘⇧A**, or from the
top-bar attention button that appears when agents are waiting.

## The agents page

Cards are grouped by status — **needs input**, **just finished**, **working**,
**idle**, **status unavailable** — under a summary line
("N agents · N sessions · N hosts") and an "agents need attention / all caught
up" banner.

Each card shows the agent's current prompt. From a card you can:

- press **⇥** to move between cards and **1**–**9** to pick a numbered option,
- **⌘↩ open** — jump straight to that pane,
- type in the message field — "message \<name\>…" queues, "prompt \<name\>…"
  sends immediately,
- interrupt the agent.

Answers re-check the live prompt before being sent, and sends verify
submission — so you never answer a question the agent already moved past.

<figure>
<a href="/docs/assets/img/agent-center.png" aria-label="Enlarge screenshot">
<img src="/docs/assets/img/agent-center.png" alt="The agents page with cards grouped under needs input, just finished, working, and idle, each card showing provider, session, host, window and pane, plus inline answer buttons and a prompt field." loading="lazy" width="1500" height="1125">
</a>
<figcaption>Cards grouped by what needs you first. Blocked agents surface their choices as inline buttons.</figcaption>
</figure>


## How detection works

Baseline detection is heuristic, read from terminal text, using the same
grammars as [swipe pad profiles](swipe-pad.md#profiles) (built-in Claude Code
and Codex grammars, plus any custom profiles you define).

For **precise status**, Tessera offers an opt-in **host hook**: a terminal
exposes process presence and pixels, but not whether an agent is computing,
idle, or blocked — the agents' own lifecycle hooks are the authoritative
signal. Installing it (per host, from the agents page) places
`~/.config/tessera/agent-lifecycle.sh` on the server, merges hook entries into
the Claude Code and Codex user configs — never rewriting your existing aliases
or functions — and adds a sourcing line to `.zshrc` / `.bashrc` (marked
`# TESSERA-AGENT-LIFECYCLE`). The page shows the hook's state: not installed /
needs an update / inactive.

## Attention notifications

With **agent attention notifications** enabled, Tessera posts an iOS banner —
"\<host\> · \<window\>", "Claude Code needs input", "… just finished" — when an
off-screen agent finishes or needs you while Tessera is backgrounded. Tapping
the banner routes straight to the right pane.

- Enabling this turns terminal-bell background
  [notifications](notifications.md) off once; the agent channel is the more
  precise one.
- iPadOS may suspend longer sessions in the background, so delivery on very
  long-running sessions is best-effort.
