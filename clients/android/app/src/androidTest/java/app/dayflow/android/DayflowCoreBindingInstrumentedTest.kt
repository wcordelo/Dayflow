package app.dayflow.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Executes the generated UniFFI binding against the packaged Rust library. */
@RunWith(AndroidJUnit4::class)
class DayflowCoreBindingInstrumentedTest {
    @Test
    fun generatedBindingSealsProjectsAndAppliesPrivacy() {
        val bridge = UniFFIDayflowCoreBridge
        val payload = JSONObject()
            .put("kind", "JournalUpsert")
            .put(
                "value",
                JSONObject()
                    .put("id", "android-binding-smoke")
                    .put("day", "2026-08-01")
                    .put("body", "Rust binding smoke test"),
            )
            .toString()
        val envelope = bridge.seal(
            payloadJson = payload,
            eventId = "android-binding-smoke-event",
            deviceId = "android-binding-smoke-device",
            logicalClock = 1uL,
            accountRootKey = ByteArray(32) { 7 },
        )

        assertEquals(1, envelope.schemaVersion.toInt())
        assertEquals(1u, envelope.keyVersion)
        val projection = bridge.project(
            envelopes = listOf(envelope),
            accountRootKey = ByteArray(32) { 7 },
        )
        assertTrue(projection.contains("android-binding-smoke"))
        assertTrue(projection.contains("Rust binding smoke test"))

        val decision = bridge.captureDecision(
            contextJson = JSONObject()
                .put("permission_granted", true)
                .put("user_paused", false)
                .put("device_locked", false)
                .put("sleeping", false)
                .put("private_context", true)
                .put("drm_content", false)
                .toString(),
            policyJson = JSONObject()
                .put("ignore_private_context", true)
                .put("pause_on_drm", true)
                .put("blocked_application_ids", JSONArray())
                .put("blocked_window_title_fragments", JSONArray())
                .toString(),
        )
        assertFalse(decision.allowed)
        assertEquals("private_context", decision.reason)
    }

    @Test
    fun generatedBindingMatchesCanonicalRequestVector() {
        assertEquals(
            "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:" +
                "b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:" +
                "0123456789abcdef0123456789abcdef:mac-device",
            UniFFIDayflowCoreBridge.canonicalDeviceRequest(
                method = "post",
                pathWithQuery = "/v1/sync/events?cursor=abc",
                body = "{\"hello\":\"opaque\"}".toByteArray(Charsets.UTF_8),
                timestamp = 1_723_456_789L,
                nonce = "0123456789abcdef0123456789abcdef",
                deviceId = "mac-device",
            ),
        )
    }

    @Test
    fun generatedBindingRecoveryKitRetainsKeyVersionsAndRejectsWrongPassphrase() {
        val bridge = UniFFIDayflowCoreBridge
        var keyRing = DayflowAndroidAccountKeyRing.fromRootKey(ByteArray(32) { 7 })
        keyRing = keyRing.adding(ByteArray(32) { 9 }, version = 2u, active = true)

        val kit = bridge.exportRecoveryKit(keyRing, "correct horse battery")
        val restored = bridge.restoreRecoveryKeyRing(kit, "correct horse battery")

        assertEquals(keyRing.toJson(), restored.toJson())
        assertEquals(listOf(1u, 2u), restored.versions())
        assertEquals(2u, restored.activeKeyVersion)
        assertArrayEquals(ByteArray(32) { 7 }, restored.keyData(1u))
        assertArrayEquals(ByteArray(32) { 9 }, restored.keyData(2u))
        var rejected = false
        try {
            bridge.restoreRecoveryKeyRing(kit, "wrong passphrase")
        } catch (_: Throwable) {
            rejected = true
        }
        assertTrue(rejected)
    }

    @Test
    fun keystoreCommitIsReadableBeforeTheSyncReturns() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = DayflowAndroidKeyStore(context)
        val accountId = "instrumentation-${System.currentTimeMillis()}"
        val value = byteArrayOf(7, 8, 9)
        try {
            store.store(accountId, "commit-test", value)
            assertArrayEquals(value, store.load(accountId, "commit-test"))
        } finally {
            store.delete(accountId, "commit-test")
            assertNull(store.load(accountId, "commit-test"))
        }
    }

    @Test
    fun physicalDeviceIdentityIsStableAcrossSessionInstances() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val first = DayflowAndroidSyncSession(context).currentDeviceId()
        val second = DayflowAndroidSyncSession(context).currentDeviceId()
        assertEquals(first, second)
    }

    @Test
    fun localStoreMergeAdvancesClockBeforeTheNextLocalEvent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val accountId = "remote-clock-${System.currentTimeMillis()}"
        DayflowLocalSyncStore(context, accountId).use { store ->
            val remote = DayflowEventEnvelope(
                eventId = "remote-clock-17",
                deviceId = "ios-clock-test",
                logicalClock = 17uL,
                schemaVersion = DayflowEventEnvelope.CURRENT_SCHEMA_VERSION.toUShort(),
                keyVersion = 1u,
                nonce = "A".repeat(32),
                ciphertext = "A".repeat(24),
            )
            assertEquals(1, store.merge(listOf(remote)))
            assertEquals(18uL, store.nextLogicalClock())

            val later = remote.copy(
                eventId = "remote-clock-25",
                deviceId = "windows-clock-test",
                logicalClock = 25uL,
            )
            assertEquals(1, store.merge(listOf(later)))
            assertEquals(26uL, store.nextLogicalClock())
        }
    }

    @Test
    fun localStoreSyncHealthPersistsBoundedStateAcrossReopen() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val accountId = "sync-health-${System.currentTimeMillis()}"
        DayflowLocalSyncStore(context, accountId).use { store ->
            store.recordSyncHealth(
                DayflowAndroidSyncHealthState.FAILED,
                "Relay response included user journal text!",
                atMillis = 100_000,
            )
            val health = store.syncHealth()
            assertEquals(DayflowAndroidSyncHealthState.FAILED, health.state)
            assertEquals("relayresponseincludeduserjournaltext", health.failureCode)
            assertNull(health.lastSuccessfulSyncAtMillis)
        }
        DayflowLocalSyncStore(context, accountId).use { store ->
            store.recordSyncHealth(DayflowAndroidSyncHealthState.SYNCED, atMillis = 200_000)
            val health = store.syncHealth()
            assertEquals(DayflowAndroidSyncHealthState.SYNCED, health.state)
            assertEquals(200_000L, health.lastSyncAtMillis)
            assertEquals(200_000L, health.lastSuccessfulSyncAtMillis)
            assertNull(health.failureCode)
        }
    }
}
