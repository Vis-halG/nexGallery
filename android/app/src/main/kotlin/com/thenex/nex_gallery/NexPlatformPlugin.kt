package com.thenex.nex_gallery

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/** Context-backed channels also work in WorkManager's headless Flutter engine.
 * Activity access is required only for explicit pickers/consent/biometrics. */
class NexPlatformPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var media: AndroidMediaBridge? = null
    private var device: DeviceTools? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        media = AndroidMediaBridge(binding.applicationContext, binding.binaryMessenger) { activity }
        device = DeviceTools(binding.applicationContext, binding.binaryMessenger) { activity }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        media?.dispose(); media = null
        device?.dispose(); device = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding; activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeActivityResultListener(this)
        binding = null; activity = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray): Boolean {
        media?.onRequestPermissionsResult(code)
        return false
    }
    override fun onActivityResult(code: Int, result: Int, data: Intent?): Boolean {
        if (device?.onActivityResult(code, result, data) == true) return true
        media?.onActivityResult(code, result, data)
        return false
    }
}
