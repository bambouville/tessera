package com.bambouville.tessera.security

import android.app.Activity
import java.util.concurrent.CopyOnWriteArrayList

/** The foreground activity the system's owner prompt needs, noting when it pauses and stops. */
class OwnerConfirmationTestActivity : Activity() {
    val callbacks = CopyOnWriteArrayList<String>()

    override fun onPause() {
        super.onPause()
        callbacks += "pause"
    }

    override fun onStop() {
        super.onStop()
        callbacks += "stop"
    }
}
