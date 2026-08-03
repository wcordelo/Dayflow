package app.dayflow.android

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobService
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.PersistableBundle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Provider-neutral entry point for a content-free Android wake. FCM or a
 * platform-equivalent dispatcher can deliver this explicit action later; a
 * random broadcast or a payload containing journal/capture fields is ignored.
 */
class DayflowSyncWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (!DayflowSyncWakeContract.accepts(
                action = intent?.action,
                kind = intent?.getStringExtra(EXTRA_KIND),
                extraKeys = intent?.extras?.keySet(),
            )) return

        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        val extras = PersistableBundle().apply {
            putString(EXTRA_KIND, intent?.getStringExtra(EXTRA_KIND))
        }
        val job = JobInfo.Builder(
            JOB_ID,
            ComponentName(context, DayflowSyncWakeJobService::class.java),
        )
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setOverrideDeadline(0L)
            .setExtras(extras)
            .build()
        scheduler.schedule(job)
    }

    companion object {
        const val ACTION_SYNC_WAKE = "app.dayflow.android.action.SYNC_WAKE"
        const val EXTRA_KIND = "kind"
        private const val JOB_ID = 7_031
    }
}

internal object DayflowSyncWakeContract {
    const val SYNC_AVAILABLE = "sync_available"

    fun accepts(action: String?, kind: String?, extraKeys: Set<String>? = null): Boolean =
        action == DayflowSyncWakeReceiver.ACTION_SYNC_WAKE
            && kind == SYNC_AVAILABLE
            && (extraKeys == null || extraKeys == setOf(DayflowSyncWakeReceiver.EXTRA_KIND))

    fun acceptsScheduledExtras(kind: String?, extraKeys: Set<String>): Boolean =
        kind == SYNC_AVAILABLE && extraKeys == setOf(DayflowSyncWakeReceiver.EXTRA_KIND)
}

/** Executes one bounded background sync and never interprets wake content. */
class DayflowSyncWakeJobService : JobService() {
    private var job: Job? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (!DayflowSyncWakeContract.acceptsScheduledExtras(
                params.extras.getString(DayflowSyncWakeReceiver.EXTRA_KIND),
                params.extras.keySet(),
            )) {
            jobFinished(params, false)
            return false
        }

        job?.cancel()
        job = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            try {
                DayflowAndroidAppModel(applicationContext).syncForPushWake()
            } finally {
                jobFinished(params, false)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        job?.cancel()
        job = null
        return true
    }

    override fun onDestroy() {
        job?.cancel()
        job = null
        super.onDestroy()
    }

}
