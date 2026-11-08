package com.docuscan.docu_scan

import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.docuscan/local_files"
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method == "readUri") {
                try {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    if (bytes == null) result.error("READ_FAILED", "Could not read scanner image", null)
                    else result.success(bytes)
                } catch (e: Exception) { result.error("READ_FAILED", e.message, null) }
            } else result.notImplemented()
        }
    }
}
