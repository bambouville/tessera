package com.bambouville.tessera.feature.agentcenter

/** The English of values/strings.xml, for JVM tests, which have no resources. */
internal val EnglishAgentRowWords = AgentRowWords(
    fork = "fork",
    needsInput = "needs input",
    working = "working",
    idle = "idle",
    finished = "finished",
    unavailable = "unavailable",
    needsYourAttention = "needs your attention",
    host = { "host $it" },
    queued = { "$it queued" },
    contextPercent = { "$it% context" },
    lineChanges = { "$it changes" },
    now = "now",
    minutesAgo = { "${it}m ago" },
    hoursAgo = { "${it}h ago" },
    daysAgo = { "${it}d ago" },
    inMinutes = { "in ${it}m" },
    inHours = { "in ${it}h" },
    inDays = { "in ${it}d" },
)
