package app.dayflow.android.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.content.res.Configuration
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import app.dayflow.android.DayflowAndroidAccountStore
import app.dayflow.android.DayflowAndroidKeyStore
import app.dayflow.android.DayflowAndroidSyncSession
import app.dayflow.android.UniFFIDayflowCoreBridge
import java.util.TimeZone

class DayflowCaptureService : Service() {
    private lateinit var statusStore: CaptureStatusStore
    private lateinit var keyStore: DayflowAndroidKeyStore
    private lateinit var accountStore: DayflowAndroidAccountStore
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var callback: MediaProjection.Callback? = null
    private var frameThread: HandlerThread? = null
    private var frameHandler: Handler? = null
    private var displayListener: DisplayManager.DisplayListener? = null
    private var projectionMetricsSnapshot: ProjectionMetrics? = null
    private var frameCount = 0L
    @Volatile
    private var accountId = ""
    private var lastDerivedSampleAt = 0L
    private var lastStatusPersistAt = 0L
    @Volatile
    private var contextJson = CapturePrivacyContext().contextJson()
    @Volatile
    private var policyJson = CapturePrivacyContext().policyJson()
    private val serviceHandler = Handler(Looper.getMainLooper())
    private var lifecycleReceiverRegistered = false
    private val lifecycleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (CaptureLifecycleSignals.stopsCapture(intent?.action)) {
                stopWithStatus(
                    CaptureState.PRIVACY_PAUSED,
                    "Capture paused while the Android device is locked or sleeping.",
                )
            }
        }
    }
    private val heartbeat = object : Runnable {
        override fun run() {
            statusStore.markServiceHeartbeat()
            serviceHandler.postDelayed(this, SERVICE_HEARTBEAT_INTERVAL_MILLIS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        statusStore = CaptureStatusStore(this)
        keyStore = DayflowAndroidKeyStore(this)
        accountStore = DayflowAndroidAccountStore(keyStore)
        registerLifecycleReceiver()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopWithStatus(CaptureState.STOPPED, "Capture stopped from the Android system notification.")
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_UPDATE_PRIVACY) {
            contextJson = intent.getStringExtra(EXTRA_CONTEXT_JSON) ?: contextJson
            policyJson = intent.getStringExtra(EXTRA_POLICY_JSON) ?: policyJson
            if (projection == null) {
                // A privacy update is only meaningful for an already attached
                // MediaProjection. Do not leave a foreground-service instance
                // alive if an update races service startup/recreation.
                statusStore.save(
                    CaptureStatus(
                        CaptureState.STOPPED,
                        "The capture service stopped before a MediaProjection session was attached.",
                        frameCount,
                    ),
                )
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, -1) ?: -1
        val resultData = intent?.projectionData() ?: run {
            stopWithStatus(CaptureState.PERMISSION_REVOKED, "The Android capture token is missing or expired.")
            return START_NOT_STICKY
        }
        contextJson = intent.getStringExtra(EXTRA_CONTEXT_JSON) ?: contextJson
        policyJson = intent.getStringExtra(EXTRA_POLICY_JSON) ?: policyJson
        accountId = intent.getStringExtra(EXTRA_ACCOUNT_ID) ?: accountId

        if (!deviceAllowsCapture()) {
            stopWithStatus(
                CaptureState.PRIVACY_PAUSED,
                "Capture paused while the Android device is locked or sleeping.",
            )
            return START_NOT_STICKY
        }

        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            stopWithStatus(CaptureState.LOCAL_EVENT_ERROR, "Android could not show the required capture notification: ${error.message}")
            return START_NOT_STICKY
        }

        startServiceHeartbeat()
        startProjection(resultCode, resultData)
        return START_NOT_STICKY
    }

    private fun startProjection(resultCode: Int, resultData: Intent) {
        cleanupProjection()
        frameCount = 0
        lastDerivedSampleAt = 0
        lastStatusPersistAt = 0
        val manager = getSystemService(MediaProjectionManager::class.java)
        val nextProjection = try {
            manager.getMediaProjection(resultCode, resultData)
        } catch (error: Exception) {
            stopWithStatus(CaptureState.PERMISSION_REVOKED, "Android rejected the capture session: ${error.message}")
            return
        } ?: run {
            stopWithStatus(CaptureState.PERMISSION_REVOKED, "Android returned no capture session.")
            return
        }
        projection = nextProjection
        callback = object : MediaProjection.Callback() {
            override fun onStop() {
                stopWithStatus(CaptureState.PERMISSION_REVOKED, "Android stopped capture (lock, system stop, or another projection session).")
            }

            @androidx.annotation.RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            override fun onCapturedContentResize(width: Int, height: Int) {
                // App-window projection on Android/ChromeOS can resize without
                // changing the physical display. Use the dimensions Android
                // reports for the captured content rather than guessing from
                // the host window configuration.
                val handler = frameHandler ?: return
                val densityDpi = projectionMetrics().densityDpi
                handler.post {
                    resizeProjectionIfNeeded(ProjectionMetrics(width, height, densityDpi))
                }
            }
        }
        nextProjection.registerCallback(callback!!, Handler(mainLooper))

        val metrics = projectionMetrics()
        frameThread = HandlerThread("dayflow-capture-frames").also { it.start() }
        val frameHandler = Handler(frameThread!!.looper)
        this.frameHandler = frameHandler
        projectionMetricsSnapshot = metrics
        try {
            imageReader = createImageReader(metrics, frameHandler)
            virtualDisplay = nextProjection.createVirtualDisplay(
                "Dayflow",
                metrics.width,
                metrics.height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader!!.surface,
                null,
                frameHandler,
            )
            registerDisplayListener(frameHandler)
        } catch (error: Exception) {
            stopWithStatus(CaptureState.PERMISSION_REVOKED, "Android could not start the capture surface: ${error.message}")
            return
        }
        statusStore.save(CaptureStatus(CaptureState.RUNNING, "Capture is active.", frameCount))
    }

    private fun createImageReader(metrics: ProjectionMetrics, handler: Handler): ImageReader =
        ImageReader.newInstance(metrics.width, metrics.height, PixelFormat.RGBA_8888, 2).also { reader ->
            reader.setOnImageAvailableListener(::handleImageAvailable, handler)
        }

    private fun handleImageAvailable(source: ImageReader) {
        source.acquireLatestImage()?.use {
            // Derivation is local. The image is closed immediately and no raw frame is written to disk or sent to the relay.
            val decision = runCatching {
                UniFFIDayflowCoreBridge.captureDecision(contextJson, policyJson)
            }.getOrDefault(app.dayflow.android.DayflowCaptureDecision(false, "privacy_decision_unavailable"))
            if (decision.allowed) {
                frameCount += 1
                val now = System.currentTimeMillis() / 1_000L
                // SharedPreferences is not a frame counter. Persist a coarse
                // heartbeat so the UI can recover status after restart without
                // writing on every GPU frame.
                if (lastStatusPersistAt == 0L || now - lastStatusPersistAt >= 5) {
                    lastStatusPersistAt = now
                    statusStore.save(CaptureStatus(CaptureState.RUNNING, "Capture is active.", frameCount))
                }
                if (now - lastDerivedSampleAt >= 60) {
                    lastDerivedSampleAt = now
                    runCatching {
                        val derivedCard = DayflowLocalVisualDeriver.derive(
                            it,
                            applicationId = "android:$packageName",
                        )
                        // The service is a second trust boundary: callers can
                        // be stale across an account sign-out or approval
                        // transition. Only an explicitly admitted account
                        // may receive an account-scoped capture event.
                        val activeAccountId = accountStore.load()?.accountId?.trim()
                        val admittedAccountId = accountId.trim().takeIf {
                            it.isNotBlank()
                                && it == activeAccountId
                                && keyStore.hasAccountKeyAdmission(it)
                        } ?: ""
                        val offset = TimeZone.getDefault().getOffset(now * 1_000L) / 60_000
                        val day = UniFFIDayflowCoreBridge.logicalDayKey(now, offset, 4u.toUByte())
                        DayflowAndroidSyncSession(applicationContext).enqueueCaptureDerived(
                            accountId = admittedAccountId,
                            captureId = "$now-$frameCount",
                            day = day,
                            startTimestamp = now,
                            endTimestamp = now,
                            title = derivedCard.title,
                            summary = derivedCard.summary,
                            category = derivedCard.category,
                            source = "android_media_projection",
                            derivationMode = derivedCard.derivationMode,
                        )
                    }.onFailure { error ->
                        statusStore.save(
                            CaptureStatus(
                                CaptureState.LOCAL_EVENT_ERROR,
                                "Capture is active, but the local event was not queued: ${error.message}",
                                frameCount,
                            ),
                        )
                    }
                }
            } else {
                statusStore.save(CaptureStatus(CaptureState.PRIVACY_PAUSED, "Capture paused: ${decision.reason}.", frameCount))
                stopSelf()
            }
        }
    }

    private fun registerDisplayListener(handler: Handler) {
        val manager = getSystemService(DisplayManager::class.java)
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit

            override fun onDisplayRemoved(displayId: Int) = Unit

            override fun onDisplayChanged(displayId: Int) {
                handler.post { resizeProjectionIfNeeded() }
            }
        }
        displayListener = listener
        manager.registerDisplayListener(listener, handler)
    }

    /**
     * ChromeOS can resize an Android window or move it between displays while
     * MediaProjection remains active. Recreate the ImageReader and resize the
     * virtual display on the capture thread so frames do not continue using a
     * stale surface or dimensions.
     */
    private fun resizeProjectionIfNeeded(expectedMetrics: ProjectionMetrics? = null) {
        val display = virtualDisplay ?: return
        val reader = imageReader ?: return
        val current = expectedMetrics ?: projectionMetrics()
        val previous = projectionMetricsSnapshot ?: return
        if (current == previous || current.width <= 0 || current.height <= 0) return

        val handler = frameHandler ?: return
        val replacement = runCatching { createImageReader(current, handler) }.getOrElse { error ->
            statusStore.save(CaptureStatus(CaptureState.LOCAL_EVENT_ERROR, "Capture resize failed: ${error.message}", frameCount))
            return
        }
        runCatching {
            display.resize(current.width, current.height, current.densityDpi)
            display.setSurface(replacement.surface)
            imageReader = replacement
            projectionMetricsSnapshot = current
            reader.close()
        }.onFailure { error ->
            replacement.close()
            statusStore.save(CaptureStatus(CaptureState.LOCAL_EVENT_ERROR, "Capture resize failed: ${error.message}", frameCount))
        }
    }

    private fun projectionMetrics(): ProjectionMetrics {
        val windowManager = getSystemService(WindowManager::class.java)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.maximumWindowMetrics.bounds
            ProjectionMetrics(bounds.width(), bounds.height(), resources.displayMetrics.densityDpi)
        } else {
            @Suppress("DEPRECATION")
            ProjectionMetrics(resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels, resources.displayMetrics.densityDpi)
        }
    }

    private fun stopWithStatus(state: CaptureState, detail: String) {
        statusStore.save(CaptureStatus(state, detail, frameCount))
        stopSelf()
    }

    private fun cleanupProjection() {
        displayListener?.let { listener ->
            getSystemService(DisplayManager::class.java).unregisterDisplayListener(listener)
        }
        displayListener = null
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        callback?.let { projection?.unregisterCallback(it) }
        projection?.stop()
        projection = null
        callback = null
        frameThread?.quitSafely()
        frameThread = null
        frameHandler = null
        projectionMetricsSnapshot = null
    }

    override fun onDestroy() {
        stopServiceHeartbeat()
        unregisterLifecycleReceiver()
        cleanupProjection()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        frameHandler?.post { resizeProjectionIfNeeded() }
    }

    private fun deviceAllowsCapture(): Boolean {
        val power = getSystemService(PowerManager::class.java) ?: return false
        val keyguard = getSystemService(KeyguardManager::class.java) ?: return false
        return power.isInteractive && !keyguard.isKeyguardLocked
    }

    private fun registerLifecycleReceiver() {
        val filter = android.content.IntentFilter().apply {
            addAction(CaptureLifecycleSignals.SCREEN_OFF_ACTION)
            addAction(CaptureLifecycleSignals.SHUTDOWN_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(lifecycleReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(lifecycleReceiver, filter)
        }
        lifecycleReceiverRegistered = true
    }

    private fun unregisterLifecycleReceiver() {
        if (!lifecycleReceiverRegistered) return
        runCatching { unregisterReceiver(lifecycleReceiver) }
        lifecycleReceiverRegistered = false
    }

    private fun buildNotification(): Notification {
        val stopIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, DayflowCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Dayflow capture is active")
            .setContentText("Frames are processed locally. Android is showing the capture indicator.")
            .setOngoing(true)
            .addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_media_pause,
                    "Stop",
                    stopIntent,
                ).build(),
            )
            .build()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Dayflow capture", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun startServiceHeartbeat() {
        serviceHandler.removeCallbacks(heartbeat)
        statusStore.markServiceHeartbeat()
        serviceHandler.postDelayed(heartbeat, SERVICE_HEARTBEAT_INTERVAL_MILLIS)
    }

    private fun stopServiceHeartbeat() {
        serviceHandler.removeCallbacks(heartbeat)
        statusStore.clearServiceHeartbeat()
    }

    private fun Intent.projectionData(): Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(EXTRA_RESULT_DATA)
    }

    private data class ProjectionMetrics(val width: Int, val height: Int, val densityDpi: Int)

    companion object {
        const val EXTRA_RESULT_CODE = "dayflow.result_code"
        const val EXTRA_RESULT_DATA = "dayflow.result_data"
        const val EXTRA_CONTEXT_JSON = "dayflow.capture_context_json"
        const val EXTRA_POLICY_JSON = "dayflow.privacy_policy_json"
        const val EXTRA_ACCOUNT_ID = "dayflow.account_id"
        const val ACTION_STOP = "app.dayflow.android.action.STOP"
        const val ACTION_UPDATE_PRIVACY = "app.dayflow.android.action.UPDATE_PRIVACY"
        private const val CHANNEL_ID = "dayflow_capture"
        private const val NOTIFICATION_ID = 4811
        private const val SERVICE_HEARTBEAT_INTERVAL_MILLIS = 5_000L
    }
}
