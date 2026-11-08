package com.silverspider.kiro.studio

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/** Gallery export, battery state and picked-image import for the Studio. All I/O off the UI thread. */
object StudioMedia {

    class MediaException(val code: String) : IOException(code)

    fun battery(context: Context): Map<String, Any?> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return mapOf("level" to -1, "charging" to true)
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val charging = plugged != 0 || status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to if (level < 0) -1 else level * 100 / scale, "charging" to charging)
    }

    /** Copies [path] into Pictures/Kiro or Movies/Kiro. Returns the content Uri as a string. */
    fun saveToGallery(context: Context, path: String, video: Boolean, name: String): String {
        val src = File(path)
        if (!src.isFile) throw MediaException("not_found")
        val safeName = name.filter { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }.ifEmpty { src.name }
        val mime = if (video) "video/mp4" else if (safeName.endsWith(".jpg", true)) "image/jpeg" else "image/png"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = if (video) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, (if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/Kiro")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(collection, values) ?: throw MediaException("io")
            try {
                resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                    ?: throw MediaException("io")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                throw MediaException("io")
            }
            return uri.toString()
        }
        // Android 8-9: public directory (needs WRITE_EXTERNAL_STORAGE, requested by the activity).
        @Suppress("DEPRECATION")
        val base = Environment.getExternalStoragePublicDirectory(if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES)
        val dir = File(base, "Kiro")
        if (!dir.isDirectory && !dir.mkdirs()) throw MediaException("permission")
        val target = File(dir, safeName)
        try {
            src.inputStream().use { input -> FileOutputStream(target).use { input.copyTo(it) } }
        } catch (e: IOException) {
            throw MediaException("permission")
        }
        runCatching {
            @Suppress("DEPRECATION")
            context.sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(target)))
        }
        return target.absolutePath
    }

    /** Copies a picked image (content Uri) into [destDir]; at most 30 MB. Returns the new path. */
    fun importImage(context: Context, uri: Uri, destDir: String): String {
        val dir = File(destDir)
        if (!dir.isDirectory && !dir.mkdirs()) throw MediaException("io")
        val mime = context.contentResolver.getType(uri).orEmpty()
        val ext = when {
            mime.contains("png") -> "png"
            mime.contains("webp") -> "webp"
            else -> "jpg"
        }
        val target = File(dir, "import_${System.currentTimeMillis()}.$ext")
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(target).use { out ->
                    val buf = ByteArray(256 * 1024)
                    var total = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_IMPORT_BYTES) throw MediaException("too_large")
                        out.write(buf, 0, n)
                    }
                }
            } ?: throw MediaException("io")
        } catch (e: MediaException) {
            target.delete()
            throw e
        } catch (e: Exception) {
            target.delete()
            throw MediaException("io")
        }
        return target.absolutePath
    }

    private const val MAX_IMPORT_BYTES = 30L * 1024 * 1024
}
