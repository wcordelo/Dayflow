package app.dayflow.android

import android.content.Context
import android.content.Intent

/**
 * Provider adapter for FCM or an equivalent push SDK. The provider owns token
 * registration and delivery; Dayflow only accepts the exact content-free wake
 * signal and hands it to the existing receiver/job path.
 */
object DayflowAndroidPushWakeAdapter {
    fun intentForData(context: Context, data: Map<String, String>): Intent? {
        if (!acceptsData(data)) return null
        return Intent(context, DayflowSyncWakeReceiver::class.java).apply {
            action = DayflowSyncWakeReceiver.ACTION_SYNC_WAKE
            putExtra(DayflowSyncWakeReceiver.EXTRA_KIND, DayflowSyncWakeContract.SYNC_AVAILABLE)
        }
    }

    fun acceptsData(data: Map<String, String>): Boolean =
        data.keys == setOf(DayflowSyncWakeReceiver.EXTRA_KIND)
            && data[DayflowSyncWakeReceiver.EXTRA_KIND] == DayflowSyncWakeContract.SYNC_AVAILABLE
}
