package com.bambouville.tessera.data

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TesseraDatabaseMigrationTest {
    private fun databaseName(version: Int) = "tessera-migration-test-$version-${System.nanoTime()}"

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        TesseraDatabase::class.java,
        emptyList(),
        FrameworkSQLiteOpenHelperFactory(),
    )

    @Test
    fun migration3To4PreservesHostsAndAddsRecoverablePairingState() {
        val databaseName = databaseName(3)
        helper.createDatabase(databaseName, 3).apply {
            execSQL(
                "INSERT INTO hosts (id, displayName, hostname, port, username, jumpHostId, identityId, tmuxMode, tmuxTarget, createdAtEpochMilliseconds, updatedAtEpochMilliseconds) " +
                    "VALUES ('12345678-1234-1234-1234-123456789abc', 'fixture', 'fixture.example', 22, 'alice', NULL, NULL, 'off', NULL, 1, 1)",
            )
            close()
        }

        helper.runMigrationsAndValidate(databaseName, 4, true, TesseraDatabase.Migration3To4).use { database ->
            database.query("SELECT transportKind FROM hosts WHERE id = '12345678-1234-1234-1234-123456789abc'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("ssh", cursor.getString(0))
            }
            database.query("SELECT COUNT(*) FROM pending_cross_device_access").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
        }
    }

    @Test
    fun migration4To5AddsOnlyAgentMetadataTables() {
        val databaseName = databaseName(4)
        helper.createDatabase(databaseName, 4).close()

        helper.runMigrationsAndValidate(databaseName, 5, true, TesseraDatabase.Migration4To5).use { database ->
            val tables = mutableSetOf<String>()
            database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'agent_%'").use { cursor ->
                while (cursor.moveToNext()) tables += cursor.getString(0)
            }
            assertEquals(
                setOf("agent_thread_metadata", "agent_route_tokens", "agent_thread_lineage"),
                tables,
            )
            tables.forEach { table ->
                database.query("PRAGMA table_info($table)").use { cursor ->
                    while (cursor.moveToNext()) {
                        val column = cursor.getString(cursor.getColumnIndexOrThrow("name")).lowercase()
                        listOf("transcript", "cursor", "path", "content", "preview", "body").forEach { forbidden ->
                            assertTrue("$table must not persist $forbidden", forbidden !in column)
                        }
                    }
                }
            }
        }
    }

    @Test
    fun everyShippedSchemaVersionCanMigrateToMetadataSchema() {
        val databaseName = databaseName(1)
        helper.createDatabase(databaseName, 1).close()

        helper.runMigrationsAndValidate(
            databaseName,
            6,
            true,
            TesseraDatabase.Migration1To2,
            TesseraDatabase.Migration2To3,
            TesseraDatabase.Migration3To4,
            TesseraDatabase.Migration4To5,
            TesseraDatabase.Migration5To6,
        ).use { database ->
            database.query("SELECT COUNT(*) FROM agent_launch_receipts").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
        }
    }

    @Test
    fun migration7To8KeepsReadStateAndAddsNullableCompletionKeys() {
        val databaseName = databaseName(7)
        helper.createDatabase(databaseName, 7).apply {
            execSQL(
                "INSERT INTO agent_thread_metadata (threadKey, lastReadRecordID, unread, updatedAtEpochMilliseconds) " +
                    "VALUES ('host:claude:session', 'record-1', 0, 42)",
            )
            close()
        }

        helper.runMigrationsAndValidate(databaseName, 8, true, TesseraDatabase.Migration7To8).use { database ->
            database.query(
                "SELECT lastReadRecordID, updatedAtEpochMilliseconds, unreadCompletionKey, acknowledgedCompletionKey " +
                    "FROM agent_thread_metadata WHERE threadKey = 'host:claude:session'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("record-1", cursor.getString(0))
                assertEquals(42L, cursor.getLong(1))
                assertTrue(cursor.isNull(2))
                assertTrue(cursor.isNull(3))
            }
            database.query("PRAGMA table_info(agent_thread_metadata)").use { cursor ->
                while (cursor.moveToNext()) {
                    val column = cursor.getString(cursor.getColumnIndexOrThrow("name")).lowercase()
                    listOf("transcript", "cursor", "path", "content", "preview", "body").forEach { forbidden ->
                        assertTrue("agent_thread_metadata must not persist $forbidden", forbidden !in column)
                    }
                }
            }
        }
    }

    @Test
    fun everyShippedSchemaVersionCanMigrateToCompletionKeys() {
        val databaseName = databaseName(1)
        helper.createDatabase(databaseName, 1).close()

        helper.runMigrationsAndValidate(
            databaseName,
            8,
            true,
            TesseraDatabase.Migration1To2,
            TesseraDatabase.Migration2To3,
            TesseraDatabase.Migration3To4,
            TesseraDatabase.Migration4To5,
            TesseraDatabase.Migration5To6,
            TesseraDatabase.Migration6To7,
            TesseraDatabase.Migration7To8,
        ).close()
    }

    @Test
    fun migration5To6AddsIdentifierOnlyLaunchReceipts() {
        val databaseName = databaseName(5)
        helper.createDatabase(databaseName, 5).close()

        helper.runMigrationsAndValidate(databaseName, 6, true, TesseraDatabase.Migration5To6).use { database ->
            database.query("PRAGMA table_info(agent_launch_receipts)").use { cursor ->
                while (cursor.moveToNext()) {
                    val column = cursor.getString(cursor.getColumnIndexOrThrow("name")).lowercase()
                    listOf("transcript", "cursor", "path", "content", "preview", "body", "task").forEach { forbidden ->
                        assertTrue("agent_launch_receipts must not persist $forbidden", forbidden !in column)
                    }
                }
            }
        }
    }
}
