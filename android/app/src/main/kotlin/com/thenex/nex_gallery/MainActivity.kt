package com.thenex.nex_gallery

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var mediaBridge: AndroidMediaBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mediaBridge = AndroidMediaBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        mediaBridge?.onRequestPermissionsResult(requestCode)
    }

    @Deprecated("Deprecated in Android; retained for API 24 permission/consent compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        mediaBridge?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        mediaBridge?.dispose()
        mediaBridge = null
        super.onDestroy()
    }
}
