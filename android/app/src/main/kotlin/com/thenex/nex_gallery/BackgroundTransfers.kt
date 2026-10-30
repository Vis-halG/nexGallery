package com.thenex.nex_gallery

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.*
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One transfer journal has one owner, even when two Flutter engines exist. */
object TransferCoordinator {
    @Volatile var foreground = false
    var workerChannel: MethodChannel? = null
    private var owner: String? = null
    val workerRunning = AtomicBoolean(false)
    @Synchronized fun claim(value: String): Boolean {
        if (owner != null && owner != value) return false
        owner = value; return true
    }
    @Synchronized fun release(value: String) { if (owner == value) owner = null }
    fun foregroundChanged(value: Boolean) {
        foreground = value
        if (value) workerChannel?.invokeMethod("stop", null)
    }
}

object BackgroundTransfers {
    const val PERIODIC = "nexgallery-camera-backup-v1"
    const val IMMEDIATE = "nexgallery-transfer-handoff-v1"
    private const val PREFERENCES = "nexgallery-background"
    fun configure(context: Context, periodic: Boolean, transfers: Boolean, wifi: Boolean, charging: Boolean, minutes: Long, callbackHandle: Long) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putBoolean("periodic", periodic).putBoolean("transfers", transfers)
            .putBoolean("wifi", wifi).putBoolean("charging", charging).putLong("callback", callbackHandle).apply()
        val manager = WorkManager.getInstance(context)
        if (periodic) {
            val interval = if (minutes in listOf(15L, 60L, 360L)) minutes else 60L
            val request = PeriodicWorkRequestBuilder<TransferWorker>(interval, TimeUnit.MINUTES)
                .setConstraints(constraints(context))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
            manager.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, request)
        } else manager.cancelUniqueWork(PERIODIC)
        if (!periodic && !transfers) manager.cancelUniqueWork(IMMEDIATE)
    }
    private fun constraints(context: Context): Constraints {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return Constraints.Builder()
            .setRequiredNetworkType(if (preferences.getBoolean("wifi", true)) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresCharging(preferences.getBoolean("charging", true))
            .setRequiresBatteryNotLow(true).setRequiresStorageNotLow(true).build()
    }
    fun runNow(context: Context) {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (!preferences.getBoolean("periodic", false) && !preferences.getBoolean("transfers", false)) return
        val request = OneTimeWorkRequestBuilder<TransferWorker>().setConstraints(constraints(context))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        WorkManager.getInstance(context).enqueueUniqueWork(IMMEDIATE, ExistingWorkPolicy.KEEP, request)
    }
    fun callbackHandle(context: Context): Long = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getLong("callback", 0)
    fun readiness(context: Context, callbackHandle: Long): UUID {
        require(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        val request = OneTimeWorkRequestBuilder<TransferWorker>().setInputData(workDataOf("readiness" to true, "callback" to callbackHandle)).build()
        WorkManager.getInstance(context).enqueue(request)
        return request.id
    }
}

/** Bounded work, persistent retry and OS network/power constraints. The Dart
 * entry point reuses the signed-request/transfer implementation, not a second
 * unreviewed HTTP client. No Activity or interactive permission prompts. */
class TransferWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val readiness = inputData.getBoolean("readiness", false)
        if (!readiness && TransferCoordinator.foreground) return Result.success()
        if (!TransferCoordinator.workerRunning.compareAndSet(false, true)) return Result.retry()
        var engine: FlutterEngine? = null
        var channel: MethodChannel? = null
        val completed = CompletableDeferred<Boolean>()
        try {
            setForeground(notification())
            withContext(Dispatchers.Main) {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                val workerEngine = FlutterEngine(applicationContext, null, false)
                engine = workerEngine
                workerEngine.plugins.add(NexPlatformPlugin())
                val workerChannel = MethodChannel(workerEngine.dartExecutor.binaryMessenger, "com.thenex.nex_gallery/background_worker")
                channel = workerChannel
                TransferCoordinator.workerChannel = workerChannel
                workerChannel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "configuration" -> result.success(mapOf("readiness" to readiness, "foreground" to TransferCoordinator.foreground))
                        "complete" -> { if (!completed.isCompleted) completed.complete(call.argument<Boolean>("retry") == true); result.success(null) }
                        else -> result.notImplemented()
                    }
                }
                val handle = inputData.getLong("callback", BackgroundTransfers.callbackHandle(applicationContext))
                val callback = requireNotNull(FlutterCallbackInformation.lookupCallbackInformation(handle)) { "Background callback is unavailable" }
                workerEngine.dartExecutor.executeDartCallback(DartExecutor.DartCallback(applicationContext.assets, loader.findAppBundlePath(), callback))
            }
            val retry = withTimeout(if (readiness) 45_000L else 8 * 60 * 1000L) { completed.await() }
            return if (retry) Result.retry() else Result.success(workDataOf("ok" to true))
        } catch (_: TimeoutCancellationException) {
            return if (readiness) Result.failure(workDataOf("error" to "Headless callback timed out")) else Result.retry()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return if (readiness) Result.failure(workDataOf("error" to error.toString())) else Result.retry()
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                val stopped = CompletableDeferred<Unit>()
                channel?.invokeMethod("stop", null, object : MethodChannel.Result {
                    override fun success(value: Any?) { if (!stopped.isCompleted) stopped.complete(Unit) }
                    override fun error(code: String, message: String?, details: Any?) { if (!stopped.isCompleted) stopped.complete(Unit) }
                    override fun notImplemented() { if (!stopped.isCompleted) stopped.complete(Unit) }
                }) ?: stopped.complete(Unit)
                withTimeoutOrNull(10_000) { stopped.await() }
                channel?.setMethodCallHandler(null)
                if (TransferCoordinator.workerChannel === channel) TransferCoordinator.workerChannel = null
                engine?.destroy()
                TransferCoordinator.workerRunning.set(false)
            }
        }
    }
    private fun notification(): ForegroundInfo {
        val channel = "nexgallery-transfers"
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = applicationContext.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(channel, "nexGallery transfers", NotificationManager.IMPORTANCE_LOW))
        }
        val cancel = WorkManager.getInstance(applicationContext).createCancelPendingIntent(id)
        val notification = NotificationCompat.Builder(applicationContext, channel)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("nexGallery")
            .setContentText("Backing up or transferring your selected files")
            .setOngoing(true).setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_delete, "Stop", cancel).build()
        return if (Build.VERSION.SDK_INT >= 29) ForegroundInfo(8734, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else ForegroundInfo(8734, notification)
    }
}
