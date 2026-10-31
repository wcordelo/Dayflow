package app.dayflow.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import app.dayflow.android.capture.CapturePrivacyContext
import app.dayflow.android.capture.MediaProjectionCaptureController
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

class MainActivity : ComponentActivity() {
    private lateinit var captureController: MediaProjectionCaptureController
    private lateinit var chromeOsCapabilities: ChromeOsCapabilities
    private lateinit var appModel: DayflowAndroidAppModel
    private var pendingCaptureAccountId: String? = null

    private val capturePermission = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        captureController.acceptConsent(result.resultCode, result.data)
    }

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val accountId = pendingCaptureAccountId
        pendingCaptureAccountId = null
        if (granted && notificationsAreVisible()) {
            captureController.requestCapture(capturePermission, accountId)
        } else {
            captureController.markNotificationPermissionRequired()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureController = MediaProjectionCaptureController(this)
        chromeOsCapabilities = ChromeOsCapabilities.detect(this)
        appModel = DayflowAndroidAppModel(applicationContext)
        setContent {
            val captureStatus by captureController.status.collectAsStateWithLifecycle()
            val appState by appModel.state.collectAsStateWithLifecycle()
            val privacyContext = CapturePrivacyContext.fromSharedSettings(appState.projection.settings)
            LaunchedEffect(appState.projection.settings) {
                captureController.updatePrivacyContext(privacyContext)
            }
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(5_000)
                    captureController.refreshFromService()
                    appModel.refreshLocalProjection()
                }
            }
            DayflowAndroidProductSurface(
                appModel = appModel,
                appState = appState,
                captureStatus = captureStatus,
                statusFields = captureStatus.statusFields(
                    sharedCapturePaused = privacyContext.userPaused,
                    derivedSync = appState.syncHealthSummary(),
                ),
                capabilities = chromeOsCapabilities,
                onStartCapture = { startCapture(appModel.captureAccountId()) },
                onStopCapture = captureController::stop,
            )
        }
    }

    override fun onResume() {
        super.onResume()
        if (::appModel.isInitialized) {
            appModel.syncIfConfigured()
            appModel.refreshLocalProjection()
        }
        if (::captureController.isInitialized) captureController.refreshFromService()
    }

    override fun onDestroy() {
        if (::appModel.isInitialized) appModel.close()
        super.onDestroy()
    }

    private fun startCapture(accountId: String?) {
        if (notificationsAreVisible()) {
            captureController.requestCapture(capturePermission, accountId)
            return
        }

        pendingCaptureAccountId = accountId
        captureController.markNotificationPermissionRequired()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }

        startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        })
    }

    private fun notificationsAreVisible(): Boolean =
        NotificationManagerCompat.from(this).areNotificationsEnabled()
}
