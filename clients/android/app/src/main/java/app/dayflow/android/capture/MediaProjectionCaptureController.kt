package app.dayflow.android.capture

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class MediaProjectionCaptureController(private val activity: ComponentActivity) {
    private val manager = activity.getSystemService(MediaProjectionManager::class.java)
    private val statusStore = CaptureStatusStore(activity)
    private val mutableStatus = MutableStateFlow(statusStore.load())
    private var privacyContext = CapturePrivacyContext()
    private var pendingAccountId: String? = null
    private var consentInFlight = false

    val status: StateFlow<CaptureStatus> = mutableStatus

    fun requestCapture(launcher: ActivityResultLauncher<Intent>, accountId: String? = null) {
        if (status.value.state in setOf(
                CaptureState.AWAITING_CONSENT,
                CaptureState.STARTING,
                CaptureState.RUNNING,
            )) {
            return
        }
        if (!privacyContext.allowsCapture()) {
            update(CaptureStatus(CaptureState.PRIVACY_PAUSED, "Dayflow privacy rules paused capture."))
            return
        }
        pendingAccountId = accountId?.takeIf { it.isNotBlank() }
        update(CaptureStatus(CaptureState.AWAITING_CONSENT, "Android will ask which display or app window Dayflow may capture."))
        consentInFlight = true
        try {
            launcher.launch(manager.createScreenCaptureIntent())
        } catch (error: Exception) {
            consentInFlight = false
            pendingAccountId = null
            update(CaptureStatus(CaptureState.LOCAL_EVENT_ERROR, "Dayflow could not open Android capture consent: ${error.message}"))
        }
    }

    fun markNotificationPermissionRequired() {
        update(
            CaptureStatus(
                CaptureState.NOTIFICATION_PERMISSION_REQUIRED,
                "Allow Dayflow notifications so the active capture status stays visible.",
            ),
        )
    }

    fun acceptConsent(resultCode: Int, data: Intent?) {
        // Stop can invalidate a consent sheet while Android is still showing
        // it. Ignore that late activity result instead of resurrecting a
        // foreground service the user explicitly stopped.
        if (!consentInFlight) return
        consentInFlight = false
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingAccountId = null
            update(CaptureStatus(CaptureState.STOPPED, "Capture permission was cancelled."))
            return
        }

        update(CaptureStatus(CaptureState.STARTING, "Starting the visible capture service."))
        val serviceIntent = Intent(activity, DayflowCaptureService::class.java).apply {
            putExtra(DayflowCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(DayflowCaptureService.EXTRA_RESULT_DATA, data)
            putExtra(DayflowCaptureService.EXTRA_CONTEXT_JSON, privacyContext.contextJson())
            putExtra(DayflowCaptureService.EXTRA_POLICY_JSON, privacyContext.policyJson())
            pendingAccountId?.let { putExtra(DayflowCaptureService.EXTRA_ACCOUNT_ID, it) }
        }
        try {
            ContextCompat.startForegroundService(activity, serviceIntent)
        } catch (error: Exception) {
            pendingAccountId = null
            update(
                CaptureStatus(
                    CaptureState.LOCAL_EVENT_ERROR,
                    "Dayflow could not start the visible capture service: ${error.message}",
                ),
            )
            return
        }
        pendingAccountId = null
        // The service writes RUNNING only after Android accepts the token,
        // creates the foreground notification, and attaches a virtual display.
        // Do not claim that capture is active while that handshake is still in
        // flight.
        update(CaptureStatus(CaptureState.STARTING, "Starting the visible capture service."))
    }

    fun stop() {
        activity.stopService(Intent(activity, DayflowCaptureService::class.java))
        consentInFlight = false
        pendingAccountId = null
        update(CaptureStatus(CaptureState.STOPPED, "Capture stopped. Derived data remains local until encrypted sync is enabled."))
    }

    /** Host observers call this before the next frame can be accepted. */
    fun updatePrivacyContext(context: CapturePrivacyContext) {
        privacyContext = context
        if (!context.allowsCapture()) {
            consentInFlight = false
            pendingAccountId = null
            activity.stopService(Intent(activity, DayflowCaptureService::class.java))
            update(CaptureStatus(CaptureState.PRIVACY_PAUSED, "Dayflow privacy rules paused capture."))
        } else if (status.value.state == CaptureState.RUNNING) {
            // Updating privacy must never create a capture service on its own.
            // A fresh MediaProjection token requires a new explicit consent
            // flow; starting an empty service here would look like capture is
            // active while no projection is attached.
            activity.startService(Intent(activity, DayflowCaptureService::class.java).apply {
                action = DayflowCaptureService.ACTION_UPDATE_PRIVACY
                putExtra(DayflowCaptureService.EXTRA_CONTEXT_JSON, context.contextJson())
                putExtra(DayflowCaptureService.EXTRA_POLICY_JSON, context.policyJson())
            })
        }
    }

    fun refreshFromService() {
        update(statusStore.load())
    }

    private fun update(status: CaptureStatus) {
        mutableStatus.value = status
        statusStore.save(status)
    }
}
