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
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.google.zxing.integration.android.IntentIntegrator
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/** Device state used to schedule heavy local work, plus wallpaper actions. */
class DeviceTools(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.thenex.nex_gallery/device")
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setWallpaper" -> runAsync(result) { setWallpaper(call) }
            "getDeviceConditions" -> result.success(conditions())
            "getNetworkState" -> result.success(networkState())
            "scanQrCode" -> scanQrCode(call, result)
            "confirmUser" -> confirmUser(call, result)
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
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
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
        val stream = activity.contentResolver.openInputStream(uri)
            ?: throw FileNotFoundException("The image could not be opened")
        stream.use { manager.setStream(it, null, true, flags) }
        return mapOf("status" to "completed")
    }

    private fun conditions(): Map<String, Any?> {
        val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val power = activity.getSystemService(PowerManager::class.java)
        val memory = ActivityManager.MemoryInfo()
        val activityManager = activity.getSystemService(ActivityManager::class.java)
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
        val manager = activity.getSystemService(ConnectivityManager::class.java)
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
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
