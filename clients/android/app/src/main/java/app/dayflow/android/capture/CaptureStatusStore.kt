package app.dayflow.android.capture

import android.content.Context

internal class CaptureStatusStore(context: Context) {
    private val preferences = context.getSharedPreferences("dayflow_capture_status", Context.MODE_PRIVATE)

    fun save(status: CaptureStatus) {
        preferences.edit()
            .putString("state", status.state.name)
            .putString("detail", status.detail)
            .putLong("frames", status.framesObserved)
            .apply()
    }

    fun markServiceHeartbeat(nowMillis: Long = System.currentTimeMillis()) {
        preferences.edit().putLong("service_heartbeat_at_ms", nowMillis).apply()
    }

    fun clearServiceHeartbeat() {
        preferences.edit().remove("service_heartbeat_at_ms").apply()
    }

    fun load(nowMillis: Long = System.currentTimeMillis()): CaptureStatus {
        val state = preferences.getString("state", CaptureState.IDLE.name)
            ?.let { value -> runCatching { CaptureState.valueOf(value) }.getOrDefault(CaptureState.IDLE) }
            ?: CaptureState.IDLE
        val frames = preferences.getLong("frames", 0)
        val heartbeatAt = preferences.getLong("service_heartbeat_at_ms", 0)
        if (CaptureStatusRecovery.isStale(state, heartbeatAt, nowMillis)) {
            return CaptureStatus(
                state = CaptureState.STOPPED,
                detail = "The Android capture service is no longer active. Start capture again.",
                framesObserved = frames,
            )
        }
        return CaptureStatus(
            state = state,
            detail = preferences.getString("detail", "Choose Start capture to begin.") ?: "",
            framesObserved = frames,
        )
    }
}
