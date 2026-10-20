package com.bambouville.tessera

import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.xmlpull.v1.XmlPullParser

/**
 * Agent metadata is deliberately device-local.  Keep this test beside the app
 * manifest because a Room-only test cannot prove the packaged backup policy.
 */
@RunWith(AndroidJUnit4::class)
class AgentBackupPolicyInstrumentedTest {
    @Test
    fun appDisablesAutoBackupAndExcludesDatabaseInBothRuleSets() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val info = context.packageManager.getApplicationInfo(context.packageName, 0)
        assertEquals(0, info.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)

        assertExcludedDomains(context.resources.getXml(R.xml.backup_rules), setOf("database", "sharedpref"))
        assertExcludedDomains(context.resources.getXml(R.xml.data_extraction_rules), setOf("database", "sharedpref"))
    }

    private fun assertExcludedDomains(parser: XmlPullParser, expected: Set<String>) {
        val found = mutableSetOf<String>()
        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG && parser.name == "exclude" && parser.getAttributeValue(null, "path") == ".") {
                parser.getAttributeValue(null, "domain")?.let(found::add)
            }
            parser.next()
        }
        expected.forEach { domain -> assertTrue("backup policy must exclude $domain", domain in found) }
    }
}
