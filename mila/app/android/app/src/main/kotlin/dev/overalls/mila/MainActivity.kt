package dev.overalls.mila

import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity: local_auth (app lock) needs a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var platform: MilaPlatform? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MilaPlatform.CHANNEL)
        platform = MilaPlatform(applicationContext, channel, link(intent), this).also {
            channel.setMethodCallHandler(it)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        link(intent)?.let { platform?.deliver(it) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MilaPlatform.NOTIFICATION_PERMISSION_REQUEST) {
            platform?.permissionResult(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        }
    }

    private fun link(intent: Intent?): String? =
        intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data?.takeIf { it.scheme == "overalls" }?.toString()
}
