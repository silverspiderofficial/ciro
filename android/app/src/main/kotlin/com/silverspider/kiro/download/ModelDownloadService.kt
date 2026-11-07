package com.silverspider.kiro.download

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.StatFs
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/**
 * Foreground service that downloads GGUF models from Hugging Face (no account needed).
 * Resumable: bytes go to "<name>.part" and an HTTP Range request continues from its size.
 * The finished file is SHA-256 verified before it is renamed into place.
 */
class ModelDownloadService : Service() {

    private lateinit var executor: ExecutorService
    private lateinit var notifications: NotificationManager
    private val main = Handler(Looper.getMainLooper())
    private var running = 0

    override fun onCreate() {
        super.onCreate()
        executor = Executors.newSingleThreadExecutor()
        notifications = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "دانلود مدل", NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            notifications.createNotificationChannel(channel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val job = Job(
                    id = intent.getStringExtra(EXTRA_ID).orEmpty(),
                    url = intent.getStringExtra(EXTRA_URL).orEmpty(),
                    sha256 = intent.getStringExtra(EXTRA_SHA256).orEmpty().lowercase(),
                    size = intent.getLongExtra(EXTRA_SIZE, -1L),
                    fileName = intent.getStringExtra(EXTRA_FILE).orEmpty(),
                    title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                )
                startInForeground(job.title)
                if (job.id.isEmpty() || cancelFlags.containsKey(job.id)) {
                    stopIfIdle()
                    return START_NOT_STICKY
                }
                cancelFlags[job.id] = AtomicBoolean(false)
                running++
                emit(job.id, STATE_QUEUED, partSize(this, job.fileName), job.size, null)
                executor.execute {
                    try {
                        run(job)
                    } finally {
                        main.post {
                            cancelFlags.remove(job.id)
                            running--
                            stopIfIdle()
                        }
                    }
                }
            }
            ACTION_CANCEL -> {
                val id = intent.getStringExtra(EXTRA_ID).orEmpty()
                cancelFlags[id]?.set(true)
                if (running == 0) stopIfIdle()
            }
            else -> stopIfIdle()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cancelFlags.values.forEach { it.set(true) }
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun startInForeground(title: String) {
        val notification = buildNotification(title, 0, 0, null)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun stopIfIdle() {
        if (running <= 0) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun buildNotification(title: String, received: Long, total: Long, jobId: String?): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(if (title.isEmpty()) "کیرو" else title)
            .setContentText("در حال دانلود مدل…")
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (total > 0) {
            val pct = ((received * 100) / total).toInt().coerceIn(0, 100)
            builder.setProgress(100, pct, false).setSubText("$pct%")
        } else {
            builder.setProgress(0, 0, true)
        }
        if (jobId != null) {
            val cancel = Intent(this, ModelDownloadService::class.java).setAction(ACTION_CANCEL).putExtra(EXTRA_ID, jobId)
            val pi = PendingIntent.getService(
                this, jobId.hashCode(), cancel,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(0, "لغو", pi)
        }
        return builder.build()
    }

    private fun run(job: Job) {
        val cancelFlag = cancelFlags[job.id] ?: return
        val dir = modelsDir(this)
        val dest = File(dir, job.fileName)
        val part = File(dir, job.fileName + PART_SUFFIX)
        if (!isSafeFileName(job.fileName) || !job.url.startsWith("https://")) {
            return emit(job.id, STATE_ERROR, 0, job.size, "bad_request")
        }
        if (dest.isFile && job.size > 0 && dest.length() == job.size) {
            return emit(job.id, STATE_DONE, job.size, job.size, null)
        }
        val remaining = if (job.size > 0) job.size - part.length() else 0L
        if (remaining > 0 && StatFs(dir.path).availableBytes < remaining + SPACE_MARGIN) {
            return emit(job.id, STATE_ERROR, part.length(), job.size, "no_space")
        }

        var attempt = 0
        while (true) {
            if (cancelFlag.get()) return emit(job.id, STATE_CANCELLED, part.length(), job.size, null)
            try {
                transfer(job, part, cancelFlag)
                break
            } catch (e: CancelledException) {
                return emit(job.id, STATE_CANCELLED, part.length(), job.size, null)
            } catch (e: FatalDownloadException) {
                return emit(job.id, STATE_ERROR, part.length(), job.size, e.message)
            } catch (e: IOException) {
                attempt++
                if (attempt > MAX_RETRIES) return emit(job.id, STATE_ERROR, part.length(), job.size, "network")
                emit(job.id, STATE_RETRYING, part.length(), job.size, "network")
                try {
                    Thread.sleep(2000L * attempt)
                } catch (ie: InterruptedException) {
                    return emit(job.id, STATE_CANCELLED, part.length(), job.size, null)
                }
            }
        }

        if (job.size > 0 && part.length() != job.size) {
            part.delete()
            return emit(job.id, STATE_ERROR, 0, job.size, "size_mismatch")
        }
        emit(job.id, STATE_VERIFYING, part.length(), job.size, null)
        val digest = try {
            sha256(part, cancelFlag)
        } catch (e: CancelledException) {
            return emit(job.id, STATE_CANCELLED, part.length(), job.size, null)
        } catch (e: IOException) {
            return emit(job.id, STATE_ERROR, part.length(), job.size, "io")
        }
        if (job.sha256.isNotEmpty() && digest != job.sha256) {
            part.delete()
            return emit(job.id, STATE_ERROR, 0, job.size, "checksum")
        }
        if (dest.exists()) dest.delete()
        if (!part.renameTo(dest)) return emit(job.id, STATE_ERROR, part.length(), job.size, "io")
        emit(job.id, STATE_DONE, dest.length(), dest.length(), null)
    }

    private fun transfer(job: Job, part: File, cancelFlag: AtomicBoolean) {
        var offset = part.length()
        if (job.size > 0 && offset == job.size) return
        if (job.size > 0 && offset > job.size) {
            part.delete()
            offset = 0
        }
        val conn = openFollowingRedirects(job.url, offset)
        try {
            val code = conn.responseCode
            val append = when (code) {
                HttpURLConnection.HTTP_PARTIAL -> true
                HttpURLConnection.HTTP_OK -> false
                416 -> {
                    // Range not satisfiable: the partial file is already complete or corrupt.
                    if (job.size > 0 && part.length() == job.size) return
                    part.delete()
                    throw IOException("range")
                }
                in 400..499 -> throw FatalDownloadException("http_$code")
                else -> throw IOException("http_$code")
            }
            if (!append) offset = 0
            val total = if (job.size > 0) job.size else offset + conn.contentLengthLong
            FileOutputStream(part, append).use { out ->
                conn.inputStream.use { input ->
                    val buffer = ByteArray(256 * 1024)
                    var received = offset
                    var lastEmit = 0L
                    var lastNotify = 0L
                    while (true) {
                        if (cancelFlag.get()) throw CancelledException()
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        received += n
                        val now = System.currentTimeMillis()
                        if (now - lastEmit > 400) {
                            lastEmit = now
                            emit(job.id, STATE_RUNNING, received, total, null)
                        }
                        if (now - lastNotify > 1000) {
                            lastNotify = now
                            notifications.notify(NOTIFICATION_ID, buildNotification(job.title, received, total, job.id))
                        }
                    }
                    out.fd.sync()
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun openFollowingRedirects(start: String, offset: Long): HttpURLConnection {
        var url = URL(start)
        repeat(MAX_REDIRECTS) {
            if (url.protocol != "https" || !isAllowedHost(url.host)) throw FatalDownloadException("blocked_host")
            val conn = url.openConnection() as HttpsURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.setRequestProperty("User-Agent", "Kiro/1.0 (Android)")
            conn.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) conn.setRequestProperty("Range", "bytes=$offset-")
            val code = conn.responseCode
            if (code in 300..399) {
                val location = conn.getHeaderField("Location") ?: throw IOException("redirect")
                conn.disconnect()
                url = URL(url, location)
            } else {
                return conn
            }
        }
        throw IOException("too_many_redirects")
    }

    private fun sha256(file: File, cancelFlag: AtomicBoolean): String {
        val md = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        file.inputStream().use { input ->
            while (true) {
                if (cancelFlag.get()) throw CancelledException()
                val n = input.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun emit(id: String, state: String, received: Long, total: Long, error: String?) {
        val event = mapOf("id" to id, "state" to state, "received" to received, "total" to total, "error" to error)
        main.post { listener?.invoke(event) }
    }

    private class Job(
        val id: String,
        val url: String,
        val sha256: String,
        val size: Long,
        val fileName: String,
        val title: String,
    )

    private class CancelledException : IOException("cancelled")
    private class FatalDownloadException(message: String) : IOException(message)

    companion object {
        const val ACTION_START = "com.silverspider.kiro.download.START"
        const val ACTION_CANCEL = "com.silverspider.kiro.download.CANCEL"
        const val EXTRA_ID = "id"
        const val EXTRA_URL = "url"
        const val EXTRA_SHA256 = "sha256"
        const val EXTRA_SIZE = "size"
        const val EXTRA_FILE = "fileName"
        const val EXTRA_TITLE = "title"

        const val STATE_QUEUED = "queued"
        const val STATE_RUNNING = "running"
        const val STATE_RETRYING = "retrying"
        const val STATE_VERIFYING = "verifying"
        const val STATE_DONE = "done"
        const val STATE_ERROR = "error"
        const val STATE_CANCELLED = "cancelled"

        const val PART_SUFFIX = ".part"
        private const val CHANNEL_ID = "kiro_downloads"
        private const val NOTIFICATION_ID = 4101
        private const val MAX_REDIRECTS = 8
        private const val MAX_RETRIES = 5
        private const val SPACE_MARGIN = 64L * 1024 * 1024

        /** Hosts a model download may touch: Hugging Face and its CDN / Xet storage. */
        private val ALLOWED_SUFFIXES = listOf("huggingface.co", ".huggingface.co", ".hf.co")

        val cancelFlags = ConcurrentHashMap<String, AtomicBoolean>()

        /** Set by MainActivity; receives progress events on the main thread. */
        @Volatile
        var listener: ((Map<String, Any?>) -> Unit)? = null

        fun isAllowedHost(host: String): Boolean {
            val h = host.lowercase()
            return ALLOWED_SUFFIXES.any { suffix -> if (suffix.startsWith(".")) h.endsWith(suffix) else h == suffix }
        }

        fun isSafeFileName(name: String): Boolean =
            name.isNotEmpty() && name.length <= 200 && !name.startsWith(".") &&
                name.all { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }

        fun modelsDir(context: Context): File = File(context.filesDir, "models").apply { mkdirs() }

        fun partSize(context: Context, fileName: String): Long =
            if (isSafeFileName(fileName)) File(modelsDir(context), fileName + PART_SUFFIX).length() else 0L
    }
}
