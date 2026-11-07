package com.silverspider.kiro.files

import android.content.Context
import android.net.Uri
import android.os.StatFs
import android.provider.OpenableColumns
import com.silverspider.kiro.download.ModelDownloadService
import java.io.File
import java.io.IOException

/** Storage Access Framework helpers: import a .gguf, read/write small text files (skills). */
object DocumentBridge {

    private const val MAX_TEXT_BYTES = 512 * 1024

    class ImportException(val code: String) : IOException(code)

    fun displayName(context: Context, uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) c.getString(idx)?.let { return it }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    }

    private fun size(context: Context, uri: Uri): Long {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0 && !c.isNull(idx)) return c.getLong(idx)
            }
        }
        return -1L
    }

    /** Makes a file name safe for the models directory. */
    fun sanitizeModelName(raw: String): String {
        val base = raw.substringAfterLast('/').substringBeforeLast(".gguf", raw.substringAfterLast('/'))
        val cleaned = base.map { if (it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' || it == '.') it else '_' }
            .joinToString("")
            .trim('.', '_')
            .take(120)
        return (if (cleaned.isEmpty()) "imported" else cleaned) + ".gguf"
    }

    /**
     * Copies a user-picked GGUF into app storage. Runs on a background thread.
     * progress(received, total) is called periodically.
     */
    fun importModel(context: Context, uri: Uri, progress: (Long, Long) -> Unit): Map<String, Any?> {
        val name = sanitizeModelName(displayName(context, uri))
        val total = size(context, uri)
        val dir = ModelDownloadService.modelsDir(context)
        if (total > 0 && StatFs(dir.path).availableBytes < total + 64L * 1024 * 1024) throw ImportException("no_space")
        val dest = File(dir, name)
        if (dest.exists()) throw ImportException("exists")
        val tmp = File(dir, "$name.importing")
        try {
            val input = context.contentResolver.openInputStream(uri) ?: throw ImportException("io")
            input.use { ins ->
                val magic = ByteArray(4)
                var read = 0
                while (read < 4) {
                    val n = ins.read(magic, read, 4 - read)
                    if (n < 0) break
                    read += n
                }
                if (read < 4 || String(magic, Charsets.US_ASCII) != "GGUF") throw ImportException("bad_file")
                tmp.outputStream().use { out ->
                    out.write(magic)
                    val buffer = ByteArray(1024 * 1024)
                    var copied = 4L
                    var last = 0L
                    while (true) {
                        val n = ins.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        copied += n
                        val now = System.currentTimeMillis()
                        if (now - last > 400) {
                            last = now
                            progress(copied, total)
                        }
                    }
                    out.fd.sync()
                }
            }
            if (!tmp.renameTo(dest)) throw ImportException("io")
            return mapOf("path" to dest.absolutePath, "fileName" to name, "size" to dest.length())
        } catch (e: ImportException) {
            tmp.delete()
            throw e
        } catch (e: Exception) {
            tmp.delete()
            throw ImportException("io")
        }
    }

    fun readText(context: Context, uri: Uri): Map<String, Any?> {
        val input = context.contentResolver.openInputStream(uri) ?: throw ImportException("io")
        val bytes = input.use { ins ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val n = ins.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_TEXT_BYTES) throw ImportException("too_large")
            }
            out.toByteArray()
        }
        return mapOf("name" to displayName(context, uri), "content" to String(bytes, Charsets.UTF_8))
    }

    fun writeText(context: Context, uri: Uri, content: String) {
        val out = context.contentResolver.openOutputStream(uri, "wt") ?: throw ImportException("io")
        out.use { it.write(content.toByteArray(Charsets.UTF_8)) }
    }
}
