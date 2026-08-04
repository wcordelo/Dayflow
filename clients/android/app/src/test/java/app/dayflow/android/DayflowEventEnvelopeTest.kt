package app.dayflow.android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import app.dayflow.android.capture.CaptureState
import app.dayflow.android.capture.CapturePrivacyContext
import app.dayflow.android.capture.CaptureStatus
import app.dayflow.android.capture.CaptureStatusRecovery
import app.dayflow.android.capture.CaptureLifecycleSignals
import app.dayflow.android.capture.DayflowNativeStatusKeys

class DayflowEventEnvelopeTest {
    @Test
    fun staleCaptureStatusCannotPretendTheServiceIsStillRunning() {
        assertTrue(
            CaptureStatusRecovery.isStale(
                CaptureState.RUNNING,
                heartbeatAtMillis = 1_000,
                nowMillis = 1_000 + CaptureStatusRecovery.SERVICE_HEARTBEAT_MAX_AGE_MILLIS + 1,
            ),
        )
        assertTrue(CaptureStatusRecovery.isStale(CaptureState.STARTING, 0, 10_000))
        assertTrue(CaptureStatusRecovery.isStale(CaptureState.AWAITING_CONSENT, 10_000, 10_000))
        assertFalse(
            CaptureStatusRecovery.isStale(
                CaptureState.RUNNING,
                heartbeatAtMillis = 10_000,
                nowMillis = 10_000 + CaptureStatusRecovery.SERVICE_HEARTBEAT_MAX_AGE_MILLIS,
            ),
        )
        assertFalse(CaptureStatusRecovery.isStale(CaptureState.STOPPED, 0, 10_000))
    }

    @Test
    fun sharedCapturePauseSettingFeedsThePrivacyContext() {
        val paused = CapturePrivacyContext.fromSharedSettings(
            mapOf(CapturePrivacyContext.SHARED_CAPTURE_PAUSE_SETTING to " true "),
        )
        assertTrue(paused.userPaused)
        assertFalse(paused.allowsCapture())

        val resumed = CapturePrivacyContext.fromSharedSettings(emptyMap())
        assertFalse(resumed.userPaused)

        val malformed = CapturePrivacyContext.fromSharedSettings(
            mapOf(CapturePrivacyContext.SHARED_CAPTURE_PAUSE_SETTING to "unexpected"),
        )
        assertTrue(malformed.userPaused)
    }

    @Test
    fun sharedSettingContractRejectsMalformedDatedKeys() {
        assertTrue(DayflowAndroidSharedSettingContract.isAllowedKey("day_goal:2026-02-28"))
        assertTrue(DayflowAndroidSharedSettingContract.isAllowedKey("daily_standup:2026-08-01"))
        assertFalse(DayflowAndroidSharedSettingContract.isAllowedKey("day_goal:2026-02-29"))
        assertFalse(DayflowAndroidSharedSettingContract.isAllowedKey("daily_standup:not-a-date"))
        assertFalse(DayflowAndroidSharedSettingContract.isAllowedKey("dayflow.provider.api_key"))
    }

    @Test
    fun systemLockAndSleepSignalsStopCaptureWithoutResumingIt() {
        assertTrue(CaptureLifecycleSignals.stopsCapture(CaptureLifecycleSignals.SCREEN_OFF_ACTION))
        assertTrue(CaptureLifecycleSignals.stopsCapture(CaptureLifecycleSignals.SHUTDOWN_ACTION))
        assertFalse(CaptureLifecycleSignals.stopsCapture("android.intent.action.USER_PRESENT"))
        assertFalse(CaptureLifecycleSignals.stopsCapture(null))
    }

    @Test
    fun syncWakeAcceptsOnlyTheContentFreeAvailabilitySignal() {
        assertTrue(
            DayflowSyncWakeContract.accepts(
                DayflowSyncWakeReceiver.ACTION_SYNC_WAKE,
                DayflowSyncWakeContract.SYNC_AVAILABLE,
            ),
        )
        assertFalse(
            DayflowSyncWakeContract.accepts(
                DayflowSyncWakeReceiver.ACTION_SYNC_WAKE,
                "journal_content",
            ),
        )
        assertFalse(
            DayflowSyncWakeContract.accepts(
                "app.dayflow.android.action.OTHER",
                DayflowSyncWakeContract.SYNC_AVAILABLE,
            ),
        )
        assertFalse(
            DayflowSyncWakeContract.accepts(
                DayflowSyncWakeReceiver.ACTION_SYNC_WAKE,
                DayflowSyncWakeContract.SYNC_AVAILABLE,
                setOf(DayflowSyncWakeReceiver.EXTRA_KIND, "journal"),
            ),
        )
        assertTrue(
            DayflowSyncWakeContract.acceptsScheduledExtras(
                DayflowSyncWakeContract.SYNC_AVAILABLE,
                setOf(DayflowSyncWakeReceiver.EXTRA_KIND),
            ),
        )
        assertFalse(
            DayflowSyncWakeContract.acceptsScheduledExtras(
                DayflowSyncWakeContract.SYNC_AVAILABLE,
                setOf(DayflowSyncWakeReceiver.EXTRA_KIND, "capture"),
            ),
        )
    }

    @Test
    fun syncHealthSummaryKeepsReplayStateAfterRestart() {
        val health = DayflowAndroidSyncHealth(
            lastSyncAtMillis = 100_000,
            lastSuccessfulSyncAtMillis = 100_000,
            state = DayflowAndroidSyncHealthState.SYNCED,
        )
        assertEquals(
            "Last synced 1m ago · 2 encrypted events queued",
            health.summary(pendingEventCount = 2, nowMillis = 160_000),
        )
        assertEquals(
            "Waiting for device approval",
            DayflowAndroidSyncHealth(
                state = DayflowAndroidSyncHealthState.WAITING_FOR_APPROVAL,
            ).summary(pendingEventCount = 0, nowMillis = 0),
        )
    }

    @Test
    fun nativeStatusFieldsKeepCaptureAndDerivedSyncStateExplicit() {
        val fields = CaptureStatus(CaptureState.RUNNING, "Capture is active.").statusFields(
            sharedCapturePaused = false,
            derivedSync = "Last synced just now",
        )

        assertEquals("granted", fields.capturePermission)
        assertEquals("running", fields.captureSession)
        assertEquals("not_paused", fields.capturePaused)
        assertEquals("Last synced just now", fields.derivedSync)
        assertEquals("granted", fields.asMap()[DayflowNativeStatusKeys.CAPTURE_PERMISSION])

        val paused = CaptureStatus(CaptureState.PRIVACY_PAUSED, "Privacy pause").statusFields(
            sharedCapturePaused = true,
            derivedSync = "",
        )
        assertEquals("not_active", paused.capturePermission)
        assertEquals("paused", paused.capturePaused)
        assertEquals("unknown", paused.derivedSync)
    }

    @Test
    fun sharedWireLimitsRemainAlignedWithRustAndRelay() {
        assertEquals(1, DayflowEventEnvelope.CURRENT_SCHEMA_VERSION)
        assertEquals(9_007_199_254_740_991L, DayflowEventEnvelope.MAX_LOGICAL_CLOCK)

        val envelope = DayflowEventEnvelope(
            eventId = "event-1",
            deviceId = "android-test",
            logicalClock = 1u,
            schemaVersion = DayflowEventEnvelope.CURRENT_SCHEMA_VERSION.toUShort(),
            keyVersion = 1u,
            nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            ciphertext = "AAAAAAAAAAAAAAAAAAAAAA==",
        )
        assertEquals("event-1", envelope.eventId)
        assertEquals(1u, envelope.keyVersion)
    }

    @Test
    fun encryptedFieldShapeMatchesTheRustEnvelopeContract() {
        assertTrue(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                ciphertext = "AAAAAAAAAAAAAAAAAAAAAA==",
            ),
        )
        assertTrue(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce = "_______________________________-",
                ciphertext = "_____________________w",
            ),
        )
        assertFalse(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce = "bm9uY2U",
                ciphertext = "Y2lwaGVydGV4dA",
            ),
        )
    }
}
