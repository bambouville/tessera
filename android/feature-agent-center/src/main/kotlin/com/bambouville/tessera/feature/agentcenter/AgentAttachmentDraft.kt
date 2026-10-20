package com.bambouville.tessera.feature.agentcenter

import org.json.JSONObject

/** Quoted prose path; keep separators readable on Android's JSON implementation. */
internal fun quoteAgentAttachmentPath(path: String): String = JSONObject.quote(path).replace("\\/", "/")
