package com.thenex.nex_gallery

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onResume() { super.onResume(); TransferCoordinator.foregroundChanged(true) }
    override fun onPause() { TransferCoordinator.foregroundChanged(false); super.onPause() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(NexPlatformPlugin::class.java)) {
            flutterEngine.plugins.add(NexPlatformPlugin())
        }
    }
}
