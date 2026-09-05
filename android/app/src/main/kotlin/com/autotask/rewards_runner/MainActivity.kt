package com.autotask.rewards_runner

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 任务进度通知（「实时活动」的 Android 承载）：常驻进度通知，
 * 单任务显示任务名+转圈/文本，一键运行显示总进度（x/3）。
 * Dart 侧封装见 lib/core/task_notifier.dart。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "rewards_runner/notifications"
        private const val CHANNEL_ID = "task_progress"
        private const val NOTIF_ID = 1001
        private const val REQ_PERM = 2001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        requestNotifPermission()
                        result.success(notificationsEnabled())
                    }
                    "start" -> {
                        show(call.argument<String>("title") ?: "任务",
                             call.argument<String>("text") ?: "",
                             indeterminate = true, done = 0, total = 0)
                        result.success(null)
                    }
                    "busy" -> {
                        show(call.argument<String>("title") ?: "任务",
                             call.argument<String>("text") ?: "",
                             indeterminate = true, done = 0, total = 0)
                        result.success(null)
                    }
                    "progress" -> {
                        show("AutoRewards 任务",
                             call.argument<String>("text") ?: "",
                             indeterminate = false,
                             done = call.argument<Int>("done") ?: 0,
                             total = call.argument<Int>("total") ?: 0)
                        result.success(null)
                    }
                    "finish" -> {
                        show("AutoRewards 任务", call.argument<String>("text") ?: "已完成",
                             indeterminate = false, done = 1, total = 1, ongoing = false)
                        // 完成通知停留数秒后自动消失
                        android.os.Handler(mainLooper).postDelayed({
                            NotificationManagerCompat.from(this).cancel(NOTIF_ID)
                        }, 5000)
                        result.success(null)
                    }
                    "cancel" -> {
                        NotificationManagerCompat.from(this).cancel(NOTIF_ID)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun notificationsEnabled(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        }

    private fun requestNotifPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !notificationsEnabled()) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_PERM)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(CHANNEL_ID, "任务进度", NotificationManager.IMPORTANCE_LOW)
            ch.description = "运行任务时在通知栏显示实时进度"
            nm.createNotificationChannel(ch)
        }
    }

    private fun show(title: String, text: String, indeterminate: Boolean,
                     done: Int, total: Int, ongoing: Boolean = true) {
        ensureChannel()
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
        if (indeterminate || total <= 0) {
            b.setProgress(0, 0, indeterminate)
        } else {
            b.setProgress(total, done.coerceIn(0, total), false)
                .setContentText("$text（$done/$total）")
        }
        try {
            NotificationManagerCompat.from(this).notify(NOTIF_ID, b.build())
        } catch (_: SecurityException) {
            // 用户未授予通知权限：静默放弃
        }
    }
}
