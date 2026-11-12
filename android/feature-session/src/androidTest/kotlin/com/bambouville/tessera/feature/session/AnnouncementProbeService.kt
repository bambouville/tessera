package com.bambouville.tessera.feature.session

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import java.util.concurrent.LinkedBlockingQueue

/**
 * An enabled accessibility service, as a screen reader is: Compose sends its
 * semantics events only while one is on. It keeps what a screen reader
 * would speak from a live region: the content description of each changed
 * node that is one.
 */
class AnnouncementProbeService : AccessibilityService() {
    override fun onServiceConnected() {
        connected = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val source = event.source
        log.add("${AccessibilityEvent.eventTypeToString(event.eventType)} changes=${event.contentChangeTypes} " +
            "package=${event.packageName} class=${event.className} source=${source?.className} " +
            "description=${source?.contentDescription} live=${source?.liveRegion} text=${event.text}")
        if (source == null) return
        if (source.liveRegion != android.view.View.ACCESSIBILITY_LIVE_REGION_NONE) {
            spoken.put(LiveRegionChange(source.liveRegion, source.contentDescription?.toString()))
        }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (connected === this) connected = null
        super.onDestroy()
    }

    data class LiveRegionChange(val mode: Int, val description: String?)

    companion object {
        @Volatile var connected: AnnouncementProbeService? = null
        val spoken = LinkedBlockingQueue<LiveRegionChange>()
        val log: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
    }
}
