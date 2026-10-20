package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Shared Core as built for Android reads a question from the capture a phone
 * sends: a tmux pane's SGR kept (`capture-pane -e -N`), its key hints wrapped
 * at 56 columns (AgentPromptScreenFixtures.claudeAskWidePhone), and the
 * review that ends a flow of long questions.
 */
@RunWith(AndroidJUnit4::class)
class SharedAgentPromptObservationInstrumentedTest {
    @Test
    fun aStyledPhoneWidthCaptureReadsAsItsQuestion() = runBlocking {
        val observation = observe(CAPTURE)
        assertEquals("question", text("kind", observation))
        assertEquals("☐ Run plan ☐ Report ✔ Submit", text("progress", observation))
        assertTrue(text("question", observation).orEmpty().startsWith("Which plan should the next run use? The last run of the ledger import"))
        assertEquals(listOf("Keep the current plan (safe)", "Switch to the fast path", "Stop and report", "Type something.", "Chat about this"),
            labels(observation))
        val controls = (observation.fields["controls"] as SharedAgentValue.ArrayValue).values.map { text("kind", it as SharedAgentValue.ObjectValue) }
        assertEquals(listOf("cancel"), controls)
    }

    /**
     * The review after long questions runs taller than 30 rows at 56 columns
     * (claudeReviewTallPhone), or than a 30-row pane, which scrolls its rule
     * off (claudeReviewScrolledShort). It shows no key hints, and still
     * offers Submit.
     */
    @Test
    fun aTallReviewOffersSubmit() = runBlocking {
        for (capture in listOf(REVIEW_TALL, REVIEW_SCROLLED)) {
            val observation = observe(capture)
            assertEquals("review", text("kind", observation))
            assertEquals("Ready to submit your answers?", text("question", observation))
            assertEquals(listOf("Submit answers", "Cancel"), labels(observation))
        }
    }

    private suspend fun observe(capture: String): SharedAgentValue.ObjectValue {
        assertTrue(CoreBridge.inspectAgent() is AgentBridgeState.Ready)
        return SharedAgentRuntime.create().use { runtime ->
            coroutineScope {
                val reply = async(start = CoroutineStart.UNDISPATCHED) {
                    withTimeout(10_000) {
                        runtime.events.first {
                            it is SharedAgentRuntimeEvent.Failure ||
                                it is SharedAgentRuntimeEvent.Snapshot && it.snapshot.kind == SharedAgentSnapshotKind.PromptObservation
                        }
                    }
                }
                val command = JSONObject().put("v", 1).put("kind", "promptObservation").put("promptRequestID", "phone")
                    .put("promptObservation", JSONObject().put("providerID", JSONObject().put("rawValue", "claude")).put("visibleText", capture))
                assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(command.toString().encodeToByteArray()))
                val event = reply.await()
                if (event is SharedAgentRuntimeEvent.Failure) fail("Core refused the observation: ${event.code}")
                val payload = (event as SharedAgentRuntimeEvent.Snapshot).snapshot.payload
                assertEquals(SharedAgentValue.StringValue("phone"), payload.fields["promptRequestID"])
                payload.fields["promptObservation"] as? SharedAgentValue.ObjectValue
                    ?: throw AssertionError("Core read no question from the capture")
            }
        }
    }

    private fun text(name: String, value: SharedAgentValue.ObjectValue) = (value.fields[name] as? SharedAgentValue.StringValue)?.value

    private fun labels(observation: SharedAgentValue.ObjectValue) =
        (observation.fields["options"] as SharedAgentValue.ArrayValue).values.map { text("label", it as SharedAgentValue.ObjectValue) }

    private companion object {
        val CAPTURE = """
            |␛[38;5;231m⏺␛[39m Tool result received: "The user answered: \"Which     
            |  database should the service use?\"=\"CockroachDB\",   
            |  \"Which features should ship first?\"=\"Export,       
            |  Sharing\", \"Should I open a pull request when        
            |  done?\"=\"No\". Read the answers carefully \u2014 they
            |  may request clarification, changes, or that you not   
            |  proceed \u2014 and        
            |
            |␛[38;5;246m✻␛[39m ␛[38;5;246mCrunched for 0s · done 7:45 AM␛[39m                        
            |                                                        
            |␛[38;5;239m␛[48;5;237m❯ ␛[38;5;231mSCRIPT:askwide␛[39m                                        
            |␛[38;5;246m␛[49m────────────────────────────────────────────────────────
            |← ␛[38;5;16m␛[48;5;153m ☐ Run plan ␛[39m␛[49m ☐ Report  ✔ Submit  →                    
            |                            
            |␛[2m│␛[0m ␛[1m␛[38;5;231mWhich plan should the next run use? The last run of ␛[0m  
            |␛[2m│␛[0m ␛[1m␛[38;5;231mthe ledger import (src/…/import/batch_job.py, 120 rows
            |␛[0;2m│␛[0m ␛[1m␛[38;5;231mper batch) finished in 244 s against a 164–190 s ␛[0m     
            |␛[2m│␛[0m ␛[1m␛[38;5;231mbudget, and the retry pass after it took 62.6 s for ␛[0m  
            |␛[2m│␛[0m ␛[1m␛[38;5;231m33,945 rows. The fast path is about 1.7× quicker than 
            |␛[0;2m│␛[0m ␛[1m␛[38;5;231mthe current one, but it skips the checksum pass, so a 
            |␛[0;2m│␛[0m ␛[1m␛[38;5;231mcorrupt batch would only show up in the nightly audit.
            |␛[0;2m│␛[0m ␛[1m␛[38;5;231mWhich trade-off do you want?␛[0m                          
            |
            |␛[38;5;153m❯␛[39m ␛[38;5;246m1.␛[39m ␛[38;5;153mKeep the current plan (safe)␛[39m                       
            |     ␛[38;5;246mRun the same batches with the checksum pass on ␛[39m    
            |     ␛[38;5;246mevery batch, and report the timing against the ␛[39m    
            |     ␛[38;5;246m164–190 s budget again so the regression is ␛[39m       
            |     ␛[38;5;246mvisible: −23.63% → about −13%.␛[39m                     
            |  ␛[38;5;246m2.␛[39m Switch to the fast path
            |     ␛[38;5;246mSkip the checksum pass for this run, keep a copy of
            |␛[39m     ␛[38;5;246mevery batch, and rely on the nightly audit to ␛[39m     
            |     ␛[38;5;246mcatch a corrupt one.␛[39m                               
            |  ␛[38;5;246m3.␛[39m Stop and report                                    
            |     ␛[38;5;246mStop now and report the partial timings.␛[39m           
            |  ␛[38;5;246m4. Type something.␛[39m        
            |␛[38;5;246m────────────────────────────────────────────────────────
            |␛[39m  5. Chat about this                                    
            |
            |␛[38;5;246mEnter to select · Tab/Arrow keys to navigate · Esc to ␛[39m  
            |␛[38;5;246mcancel␛[39m                                                  
        """.trimMargin().replace("␛", "\u001b")

        val REVIEW_TALL = """
            |                                                        
            |␛[38;5;231m⏺␛[39m Tool result received: "Your questions have been       
            |  answered: "Which plan should the next run use? The    
            |  last run of the ledger import                         
            |  (src/\u2026/import/batch_job.py, 120 rows per batch)  
            |  finished in 244 s against a 164\u2013190 s budget, and
            |  the retry pass after it took 62.6 s for 33,945 rows.  
            |  The fast path is about 1.7\u00d                       
            |                                                        
            |␛[38;5;246m✻␛[39m ␛[38;5;246mSautéed for 0s · done 10:42 AM␛[39m                        
            |                                                        
            |␛[38;5;239m␛[48;5;237m❯ ␛[38;5;231mSCRIPT:askreview␛[39m                                      
            |␛[49m                                                        
            |␛[38;5;246m────────────────────────────────────────────────────────
            |␛[39m←  ☒ Import lever  ☒ Release  ☒ Audit check ␛[38;5;16m␛[48;5;153m ✔ Submit ␛[38;5;246m␛[49m →
            |␛[39m                                                        
            |␛[1m␛[38;5;231mReview your answers␛[0m                                     
            |                                                        
            | ␛[2m│␛[0m ● Which lever should the importer try first? The     
            | ␛[2m│␛[0m   nightly import (src/…/import/ledger_job.py, 400    
            | ␛[2m│␛[0m   rows per batch) now spends 71% of its time         
            | ␛[2m│␛[0m   re-reading the same vendor table, and the cache    
            | ␛[2m│␛[0m   that would fix it doubles peak memory to about 3.2 
            | ␛[2m│␛[0m   GB on the smallest worker. Batching the vendor     
            | ␛[2m│␛[0m   reads keeps memory flat but only saves about a     
            | ␛[2m│␛[0m   third of the time, and it changes the order the    
            | ␛[2m│␛[0m   audit log sees. Which one should I try first,      
            | ␛[2m│␛[0m   keeping the audit order stable?                    
            |   ␛[38;5;114m→ Batch the vendor reads␛[39m                             
            | ␛[2m│␛[0m ● The release branch test suite passes on            
            | ␛[2m│␛[0m   release/2026-09-ledger (tip 4c1e9a7b2). All 14     
            | ␛[2m│␛[0m   suites pass, the parity audit reports 0 failures,  
            | ␛[2m│␛[0m   and the output is identical to the current main.   
            | ␛[2m│␛[0m   Fast-forward main to it now?                       
            |   ␛[38;5;114m→ Fast-forward␛[39m                                       
            | ␛[2m│␛[0m ● Open item from the last round: a vendor payment is 
            | ␛[2m│␛[0m   checked for currency, limits and funds, but not for
            | ␛[2m│␛[0m   the holiday calendar. A payment due on a bank      
            | ␛[2m│␛[0m   holiday reads settle_early=true, then gets dropped 
            | ␛[2m│␛[0m   when the batch closes at the cut-off. Both ledgers 
            | ␛[2m│␛[0m   agree, so parity holds, but the published total is 
            | ␛[2m│␛[0m   optimistic. Fix it?                                
            |   ␛[38;5;114m→ can payments settle a day late?␛[39m                    
            |
            |␛[38;5;246mReady to submit your answers?␛[39m                           
            |
            |␛[38;5;153m❯␛[39m ␛[38;5;246m1. ␛[38;5;153mSubmit answers␛[39m         
            |  ␛[38;5;246m2. ␛[39mCancel   
        """.trimMargin().replace("␛", "\u001b")

        val REVIEW_SCROLLED = """
            | ␛[2m│␛[0m   keeping the audit order stable?                    
            |   ␛[38;5;114m→ Batch the vendor reads␛[39m                             
            | ␛[2m│␛[0m ● The release branch test suite passes on            
            | ␛[2m│␛[0m   release/2026-09-ledger (tip 4c1e9a7b2). All 14     
            | ␛[2m│␛[0m   suites pass, the parity audit reports 0 failures,  
            | ␛[2m│␛[0m   and the output is identical to the current main.   
            | ␛[2m│␛[0m   Fast-forward main to it now?                       
            |   ␛[38;5;114m→ Fast-forward␛[39m                                       
            | ␛[2m│␛[0m ● Open item from the last round: a vendor payment is 
            | ␛[2m│␛[0m   checked for currency, limits and funds, but not for
            | ␛[2m│␛[0m   the holiday calendar. A payment due on a bank      
            | ␛[2m│␛[0m   holiday reads settle_early=true, then gets dropped 
            | ␛[2m│␛[0m   when the batch closes at the cut-off. Both ledgers 
            | ␛[2m│␛[0m   agree, so parity holds, but the published total is 
            | ␛[2m│␛[0m   optimistic. Fix it?                                
            |   ␛[38;5;114m→ can payments settle a day late?␛[39m                    
            | ␛[2m│␛[0m ● If the fast-forward goes wrong, should the rollback
            | ␛[2m│␛[0m   restore the previous main tip and replay the three 
            | ␛[2m│␛[0m   ledger migrations in reverse, or keep main and     
            | ␛[2m│␛[0m   ship a revert commit? Replaying takes about twenty 
            | ␛[2m│␛[0m   minutes and needs the ledger writer stopped; a     
            | ␛[2m│␛[0m   revert commit is instant but leaves the migrations 
            | ␛[2m│␛[0m   applied until the next release, which the parity   
            | ␛[2m│␛[0m   audit would then flag every night.                 
            |   ␛[38;5;114m→ Revert commit␛[39m                                      
            |                            
            |␛[38;5;246mReady to submit your answers?␛[39m                           
            |
            |␛[38;5;153m❯␛[39m ␛[38;5;246m1. ␛[38;5;153mSubmit answers␛[39m         
            |  ␛[38;5;246m2. ␛[39mCancel   
        """.trimMargin().replace("␛", "\u001b")
    }
}
