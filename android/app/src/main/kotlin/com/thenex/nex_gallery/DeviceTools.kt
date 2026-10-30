package com.thenex.nex_gallery

import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.WallpaperManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.google.zxing.integration.android.IntentIntegrator
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/** Device state used to schedule heavy local work, plus wallpaper actions. */
class DeviceTools(
    private val context: Context,
    messenger: BinaryMessenger,
    private val activityProvider: () -> Activity? = { null },
) : MethodChannel.MethodCallHandler {
    private val activity: Activity get() = requireNotNull(activityProvider()) { "This action needs an open nexGallery window" }
    private val channel = MethodChannel(messenger, "com.thenex.nex_gallery/device")
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var transferOwner: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "claimTransferSession" -> {
                val owner = call.argument<String>("owner") ?: ""
                if (!Regex("^[A-Za-z0-9_-]{1,96}$").matches(owner)) { result.error("invalid_owner", "Invalid transfer owner", null); return }
                val claimed = TransferCoordinator.claim(owner)
                if (claimed) transferOwner = owner
                result.success(claimed)
            }
            "releaseTransferSession" -> {
                val owner = call.argument<String>("owner") ?: ""
                if (owner == transferOwner) { TransferCoordinator.release(owner); transferOwner = null }
                result.success(null)
            }
            "configureBackground" -> {
                BackgroundTransfers.configure(context, call.argument<Boolean>("periodic") == true,
                    call.argument<Boolean>("transfers") == true, call.argument<Boolean>("wifiOnly") != false,
                    call.argument<Boolean>("chargingOnly") != false, call.argument<Number>("minutes")?.toLong() ?: 60L,
                    call.argument<Number>("callbackHandle")?.toLong() ?: 0L)
                result.success(null)
            }
            "runBackgroundNow" -> { BackgroundTransfers.runNow(context); result.success(null) }
            "runBackgroundReadiness" -> {
                if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) { result.notImplemented(); return }
                result.success(BackgroundTransfers.readiness(context, call.argument<Number>("callbackHandle")?.toLong() ?: 0L).toString())
            }
            "backgroundWorkStatus" -> runAsync(result) {
                val id = java.util.UUID.fromString(call.argument<String>("id"))
                val work = androidx.work.WorkManager.getInstance(context).getWorkInfoById(id).get()
                mapOf("state" to work?.state?.name, "ok" to work?.outputData?.getBoolean("ok", false), "error" to work?.outputData?.getString("error"))
            }
            "setWallpaper" -> runAsync(result) { setWallpaper(call) }
            "getDeviceConditions" -> result.success(conditions())
            "getNetworkState" -> result.success(networkState())
            "scanQrCode" -> scanQrCode(call, result)
            "confirmUser" -> confirmUser(call, result)
            "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
            "installApk" -> installApk(call, result)
            else -> result.notImplemented()
        }
    }

    private var scanResult: MethodChannel.Result? = null

    /// Opens the camera scanner. Only QR codes are decoded; nothing is stored.
    private fun scanQrCode(call: MethodCall, result: MethodChannel.Result) {
        if (scanResult != null) {
            result.error("scan_active", "A scan is already open", null)
            return
        }
        scanResult = result
        IntentIntegrator(activity)
            .setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
            .setPrompt(call.argument<String>("prompt") ?: "Scan the code shown on your PC")
            .setBeepEnabled(false)
            .setOrientationLocked(false)
            .initiateScan()
    }

    /// Opens Android's installer for an update the app downloaded and
    /// verified. Android itself refuses an APK signed with a different key.
    /// Replies "started", or "needsPermission" after opening the setting that
    /// lets nexGallery install apps.
    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val updates = File(context.cacheDir, "updates").canonicalFile
        val file = path?.let { File(it).canonicalFile }
        if (file == null || file.parentFile != updates || !file.name.endsWith(".apk") || !file.isFile) {
            result.error("invalid_update", "Only downloaded updates can be installed", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"),
                ),
            )
            result.success("needsPermission")
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${context.packageName}.fileprovider", file)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        result.success("started")
    }

    private var authResult: MethodChannel.Result? = null
    private val confirmCredentialRequest = 41727

    /// Asks for a fingerprint, face or the screen-lock PIN before an action
    /// that cannot be undone. Replies "success", "cancelled" or "notSecured"
    /// when the phone has no screen lock.
    private fun confirmUser(call: MethodCall, result: MethodChannel.Result) {
        if (authResult != null) {
            result.error("auth_active", "A confirmation is already open", null)
            return
        }
        val title = call.argument<String>("title") ?: "Confirm it's you"
        val subtitle = call.argument<String>("subtitle") ?: ""
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) {
            result.success("notSecured")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val builder = BiometricPrompt.Builder(activity).setTitle(title)
            if (subtitle.isNotEmpty()) builder.setSubtitle(subtitle)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_WEAK or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setDeviceCredentialAllowed(true)
            }
            var replied = false
            fun reply(value: String) {
                if (!replied) {
                    replied = true
                    result.success(value)
                }
            }
            builder.build().authenticate(
                CancellationSignal(),
                activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        authentication: BiometricPrompt.AuthenticationResult?,
                    ) = reply("success")

                    // A rejected finger is not final; the prompt stays open.
                    override fun onAuthenticationError(code: Int, message: CharSequence?) =
                        reply("cancelled")
                },
            )
            return
        }
        // Android 7-9: the system screen-lock confirmation.
        @Suppress("DEPRECATION")
        val intent = keyguard.createConfirmDeviceCredentialIntent(title, subtitle)
        if (intent == null) {
            result.success("notSecured")
            return
        }
        authResult = result
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, confirmCredentialRequest)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == confirmCredentialRequest) {
            val result = authResult ?: return false
            authResult = null
            result.success(if (resultCode == Activity.RESULT_OK) "success" else "cancelled")
            return true
        }
        if (requestCode != IntentIntegrator.REQUEST_CODE) return false
        val result = scanResult ?: return false
        scanResult = null
        val scanned = IntentIntegrator.parseActivityResult(requestCode, resultCode, data)
        result.success(
            if (scanned?.contents == null) {
                mapOf("status" to "cancelled")
            } else {
                mapOf("status" to "scanned", "text" to scanned.contents)
            },
        )
        return true
    }

    private fun setWallpaper(call: MethodCall): Map<String, Any> {
        val uri = Uri.parse(
            call.argument<String>("uri") ?: throw IllegalArgumentException("A media URI is required"),
        )
        val manager = WallpaperManager.getInstance(activity)
        if (!manager.isWallpaperSupported || !manager.isSetWallpaperAllowed) {
            return mapOf("status" to "unsupported")
        }
        val flags = when (call.argument<String>("target")) {
            "home" -> WallpaperManager.FLAG_SYSTEM
            "lock" -> WallpaperManager.FLAG_LOCK
            else -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
        }
        val stream = context.contentResolver.openInputStream(uri)
            ?: throw FileNotFoundException("The image could not be opened")
        stream.use { manager.setStream(it, null, true, flags) }
        return mapOf("status" to "completed")
    }

    private fun conditions(): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val power = context.getSystemService(PowerManager::class.java)
        val memory = ActivityManager.MemoryInfo()
        val activityManager = context.getSystemService(ActivityManager::class.java)
        activityManager?.getMemoryInfo(memory)
        return mapOf(
            "charging" to (
                status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
                ),
            "batteryPercent" to if (level >= 0 && scale > 0) level * 100 / scale else null,
            "powerSave" to (power?.isPowerSaveMode ?: false),
            "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) power?.currentThermalStatus else null,
            "lowRamDevice" to (activityManager?.isLowRamDevice ?: false),
            "lowMemory" to memory.lowMemory,
            "availableMemoryBytes" to memory.availMem,
            "totalMemoryBytes" to memory.totalMem,
        )
    }

    private fun networkState(): Map<String, Any> {
        val manager = context.getSystemService(ConnectivityManager::class.java)
            ?: return mapOf("connected" to false)
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
            ?: return mapOf("connected" to false)
        return mapOf(
            "connected" to capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            "wifi" to (
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                ),
            "cellular" to capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
            "vpn" to capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
            "metered" to manager.isActiveNetworkMetered,
        )
    }

    private fun runAsync(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: SecurityException) {
                mainHandler.post { result.error("permission_denied", error.message, null) }
            } catch (error: Exception) {
                mainHandler.post { result.error("device_error", error.message, null) }
            }
        }
    }

    fun dispose() {
        transferOwner?.let { TransferCoordinator.release(it) }
        transferOwner = null
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
