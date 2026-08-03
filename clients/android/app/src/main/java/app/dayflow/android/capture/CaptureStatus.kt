package app.dayflow.android.capture

import app.dayflow.android.UniFFIDayflowCoreBridge
import org.json.JSONArray
import org.json.JSONObject

enum class CaptureState {
    IDLE,
    AWAITING_CONSENT,
    STARTING,
    RUNNING,
    STOPPED,
    PERMISSION_REVOKED,
    PRIVACY_PAUSED,
    NOTIFICATION_PERMISSION_REQUIRED,
    ACCOUNT_REQUIRED,
    LOCAL_EVENT_ERROR,
    UNSUPPORTED,
}

data class CaptureStatus(
    val state: CaptureState,
    val detail: String,
    val framesObserved: Long = 0,
) {
    /**
     * The fields below are the native-client status contract. They are
     * deliberately derived from the local capture state and local projection;
     * no capture state is sent to the relay as plaintext.
     */
    fun statusFields(sharedCapturePaused: Boolean, derivedSync: String): DayflowCaptureStatusFields =
        DayflowCaptureStatusFields(
            capturePermission = when (state) {
                CaptureState.AWAITING_CONSENT -> "awaiting_consent"
                CaptureState.STARTING, CaptureState.RUNNING -> "granted"
                CaptureState.PERMISSION_REVOKED -> "revoked"
                CaptureState.NOTIFICATION_PERMISSION_REQUIRED -> "notification_permission_required"
                CaptureState.UNSUPPORTED -> "unsupported"
                else -> "not_active"
            },
            captureSession = state.name.lowercase(),
            capturePaused = if (sharedCapturePaused || state == CaptureState.PRIVACY_PAUSED) {
                "paused"
            } else {
                "not_paused"
            },
            derivedSync = derivedSync.ifBlank { "unknown" },
        )
}

data class DayflowCaptureStatusFields(
    val capturePermission: String,
    val captureSession: String,
    val capturePaused: String,
    val derivedSync: String,
) {
    fun asMap(): Map<String, String> = mapOf(
        DayflowNativeStatusKeys.CAPTURE_PERMISSION to capturePermission,
        DayflowNativeStatusKeys.CAPTURE_SESSION to captureSession,
        DayflowNativeStatusKeys.CAPTURE_PAUSED to capturePaused,
        DayflowNativeStatusKeys.DERIVED_SYNC to derivedSync,
    )
}

object DayflowNativeStatusKeys {
    const val CAPTURE_PERMISSION = "capture_permission"
    const val CAPTURE_SESSION = "capture_session"
    const val CAPTURE_PAUSED = "capture_paused"
    const val DERIVED_SYNC = "derived_sync"
}

internal object CaptureStatusRecovery {
    const val SERVICE_HEARTBEAT_MAX_AGE_MILLIS = 15_000L

    fun requiresLiveService(state: CaptureState): Boolean = state in setOf(
        CaptureState.AWAITING_CONSENT,
        CaptureState.STARTING,
        CaptureState.RUNNING,
    )

    fun isStale(state: CaptureState, heartbeatAtMillis: Long, nowMillis: Long): Boolean {
        if (!requiresLiveService(state)) return false
        if (state == CaptureState.AWAITING_CONSENT) return true
        return heartbeatAtMillis <= 0L
            || nowMillis - heartbeatAtMillis > SERVICE_HEARTBEAT_MAX_AGE_MILLIS
    }
}

internal object CaptureLifecycleSignals {
    const val SCREEN_OFF_ACTION = "android.intent.action.SCREEN_OFF"
    const val SHUTDOWN_ACTION = "android.intent.action.ACTION_SHUTDOWN"

    fun stopsCapture(action: String?): Boolean = action == SCREEN_OFF_ACTION || action == SHUTDOWN_ACTION
}

data class CapturePrivacyContext(
    val permissionGranted: Boolean = true,
    val userPaused: Boolean = false,
    val deviceLocked: Boolean = false,
    val sleeping: Boolean = false,
    val privateContext: Boolean = false,
    val drmContent: Boolean = false,
    val applicationId: String? = null,
    val windowTitle: String? = null,
    val blockedApplicationIds: Set<String> = emptySet(),
    val blockedWindowTitleFragments: List<String> = emptyList(),
) {
    fun decision(): app.dayflow.android.DayflowCaptureDecision = runCatching {
        UniFFIDayflowCoreBridge.captureDecision(contextJson(), policyJson())
    }.getOrDefault(app.dayflow.android.DayflowCaptureDecision(false, "privacy_decision_unavailable"))

    fun allowsCapture(): Boolean = decision().allowed

    fun contextJson(): String = JSONObject()
        .put("permission_granted", permissionGranted)
        .put("user_paused", userPaused)
        .put("device_locked", deviceLocked)
        .put("sleeping", sleeping)
        .put("private_context", privateContext)
        .put("drm_content", drmContent)
        .put("application_id", applicationId ?: JSONObject.NULL)
        .put("window_title", windowTitle ?: JSONObject.NULL)
        .toString()

    fun policyJson(): String = JSONObject()
        .put("ignore_private_context", true)
        .put("pause_on_drm", true)
        .put("blocked_application_ids", JSONArray(blockedApplicationIds.sorted()))
        .put("blocked_window_title_fragments", JSONArray(blockedWindowTitleFragments))
        .toString()

    companion object {
        const val SHARED_CAPTURE_PAUSE_SETTING = "dayflow.capture.paused"

        /** Convert the decrypted local projection into capture state. */
        fun fromSharedSettings(settings: Map<String, String>): CapturePrivacyContext {
            val paused = when (settings[SHARED_CAPTURE_PAUSE_SETTING]?.trim()?.lowercase()) {
                null, "false" -> false
                "true" -> true
                // A malformed shared privacy value must not silently resume
                // capture. The next explicit false write can resume it.
                else -> true
            }
            return CapturePrivacyContext(userPaused = paused)
        }
    }
}
