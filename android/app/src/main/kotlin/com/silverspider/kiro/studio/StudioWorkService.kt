package com.silverspider.kiro.studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the app process alive (with a progress notification) while the Studio renders a video
 * or generates an image. The work itself runs elsewhere (FFmpeg child process / ":ai" process);
 * this service only holds the foreground state.
 */
class StudioWorkService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
                val text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
                val progress = intent.getIntExtra(EXTRA_PROGRESS, -1)
                try {
                    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
                    ServiceCompat.startForeground(this, NOTIFICATION_ID, build(title, text, progress), type)
                } catch (e: Exception) {
                    // Foreground start refused (background restrictions): the work continues while the app is visible.
                    stopSelf()
                }
            }
            else -> {
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun build(title: String, text: String, progress: Int): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "استودیو", NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle(title.ifEmpty { "کیرو" })
            .setContentText(text.ifEmpty { "در حال ساخت…" })
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (launch != null) {
            b.setContentIntent(
                android.app.PendingIntent.getActivity(
                    this, 0, launch,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        if (progress in 0..100) b.setProgress(100, progress, false) else b.setProgress(0, 0, true)
        return b.build()
    }

    companion object {
        const val ACTION_START = "com.silverspider.kiro.studio.START"
        const val ACTION_UPDATE = "com.silverspider.kiro.studio.UPDATE"
        const val ACTION_STOP = "com.silverspider.kiro.studio.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        private const val CHANNEL_ID = "kiro_studio"
        private const val NOTIFICATION_ID = 4201

        @Volatile private var lastTitle: String = ""
        @Volatile var running = false
            private set

        fun start(context: Context, title: String) {
            lastTitle = title
            running = true
            send(context, ACTION_START, title, "", -1)
        }

        fun update(context: Context, text: String, progress: Int) {
            if (!running) return
            send(context, ACTION_UPDATE, lastTitle, text, progress)
        }

        fun stop(context: Context) {
            if (!running) return
            running = false
            runCatching {
                context.startService(Intent(context, StudioWorkService::class.java).setAction(ACTION_STOP))
            }
        }

        private fun send(context: Context, action: String, title: String, text: String, progress: Int) {
            val intent = Intent(context, StudioWorkService::class.java)
                .setAction(action)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_PROGRESS, progress)
            try {
                if (action == ACTION_START) ContextCompat.startForegroundService(context, intent) else context.startService(intent)
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException / IllegalStateException: never crash the app.
            }
        }
    }
}
