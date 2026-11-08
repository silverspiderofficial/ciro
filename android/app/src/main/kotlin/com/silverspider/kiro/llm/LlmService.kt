package com.silverspider.kiro.llm

import android.app.ActivityManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import com.silverspider.kiro.image.SdNative
import com.silverspider.kiro.image.SdProgress
import java.io.File
import java.io.RandomAccessFile
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Hosts llama.cpp in its own process (android:process=":ai"). If the model runs the device out
 * of memory or native code crashes, only this process dies; the UI gets onServiceDisconnected,
 * shows an error and the binding is re-established automatically.
 */
class LlmService : Service() {

    private lateinit var ipcThread: HandlerThread
    private lateinit var messenger: Messenger
    private lateinit var worker: ExecutorService

    @Volatile private var client: Messenger? = null
    @Volatile private var currentRequest: Int = NO_REQUEST
    @Volatile private var loadedPath: String? = null
    @Volatile private var description: String = ""
    @Volatile private var backendDevices: Int = -1
    @Volatile private var initError: String? = null
    private val cancelled: MutableSet<Int> = Collections.synchronizedSet(HashSet())

    // Image model (stable-diffusion.cpp). Shares the single worker thread with the chat model so
    // only one heavy model is ever in memory.
    @Volatile private var sdHandle: Long = 0L
    @Volatile private var sdKey: String? = null
    @Volatile private var currentImage: Int = NO_REQUEST
    private val imageCancelled: MutableSet<Int> = Collections.synchronizedSet(HashSet())

    override fun onCreate() {
        super.onCreate()
        ipcThread = HandlerThread("kiro-llm-ipc").also { it.start() }
        messenger = Messenger(Handler(ipcThread.looper) { msg -> handle(msg); true })
        // llama.cpp needs a deep stack for some graph builds; give the worker 16 MB.
        worker = Executors.newSingleThreadExecutor { r -> Thread(null, r, "kiro-llm-worker", 16L * 1024 * 1024) }
        worker.execute {
            try {
                LlamaNative.ensureLibrary()
                backendDevices = LlamaNative.nativeInit(applicationInfo.nativeLibraryDir)
            } catch (t: Throwable) {
                initError = t.javaClass.simpleName
                backendDevices = 0
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        if (currentRequest != NO_REQUEST) runCatching { LlamaNative.nativeCancel() }
        val h = sdHandle
        if (currentImage != NO_REQUEST && h != 0L) runCatching { SdNative.nativeCancel(h) }
        worker.execute {
            runCatching { if (loadedPath != null) LlamaNative.nativeUnload() }
            freeImageModel()
        }
        worker.shutdown()
        ipcThread.quitSafely()
        super.onDestroy()
    }

    private fun handle(msg: Message) {
        msg.replyTo?.let { client = it }
        val data = Bundle(msg.data)
        val requestId = msg.arg1
        when (msg.what) {
            LlmIpc.MSG_LOAD -> worker.execute { doLoad(requestId, data) }
            LlmIpc.MSG_UNLOAD -> worker.execute { doUnload(requestId) }
            LlmIpc.MSG_GENERATE -> worker.execute { doGenerate(requestId, data) }
            LlmIpc.MSG_CANCEL -> {
                cancelled.add(requestId)
                if (currentRequest == requestId) runCatching { LlamaNative.nativeCancel() }
            }
            LlmIpc.MSG_IMAGE_GENERATE -> worker.execute { doImage(requestId, data) }
            LlmIpc.MSG_IMAGE_CANCEL -> {
                imageCancelled.add(requestId)
                val h = sdHandle
                if (currentImage == requestId && h != 0L) runCatching { SdNative.nativeCancel(h) }
            }
            LlmIpc.MSG_IMAGE_UNLOAD -> worker.execute {
                freeImageModel()
                reply(LlmIpc.MSG_UNLOADED, requestId, Bundle())
            }
            LlmIpc.MSG_STATUS -> reply(LlmIpc.MSG_STATUS_REPLY, requestId, Bundle().apply {
                putBoolean(LlmIpc.KEY_LOADED, loadedPath != null)
                putString(LlmIpc.KEY_PATH, loadedPath)
                putString(LlmIpc.KEY_DESCRIPTION, description)
            })
        }
    }

    private fun doLoad(requestId: Int, data: Bundle) {
        val path = data.getString(LlmIpc.KEY_PATH).orEmpty()
        val nCtx = data.getInt(LlmIpc.KEY_N_CTX, 4096)
        val threads = data.getInt(LlmIpc.KEY_THREADS, 4)
        val force = data.getBoolean(LlmIpc.KEY_FORCE, false)

        if (backendDevices <= 0) {
            return replyError(requestId, "no_backend", initError ?: "no compute backend")
        }
        // Only one heavy model at a time: always release the current one first.
        freeImageModel()
        if (loadedPath != null) {
            LlamaNative.nativeUnload()
            loadedPath = null
            description = ""
        }
        val file = File(path)
        if (!file.isFile || !file.canRead()) return replyError(requestId, "not_found", path)
        if (!hasGgufMagic(file)) return replyError(requestId, "bad_file", "not a GGUF file")

        val need = estimateRequiredBytes(file.length(), nCtx)
        val avail = availableMemory()
        if (!force && avail in 1 until need) {
            reply(LlmIpc.MSG_ERROR, requestId, Bundle().apply {
                putString(LlmIpc.KEY_CODE, "low_ram")
                putString(LlmIpc.KEY_MESSAGE, "available=$avail needed=$need")
                putLong(LlmIpc.KEY_AVAIL, avail)
                putLong(LlmIpc.KEY_NEED, need)
            })
            return
        }
        val rc = try {
            LlamaNative.nativeLoad(path, nCtx, threads)
        } catch (t: Throwable) {
            return replyError(requestId, "load_failed", t.javaClass.simpleName)
        }
        when (rc) {
            LlamaNative.LOAD_OK -> {
                loadedPath = path
                description = runCatching { LlamaNative.nativeDescription() }.getOrDefault("")
                reply(LlmIpc.MSG_LOADED, requestId, Bundle().apply {
                    putString(LlmIpc.KEY_PATH, path)
                    putString(LlmIpc.KEY_DESCRIPTION, description)
                })
            }
            LlamaNative.LOAD_ERR_CONTEXT -> replyError(requestId, "context_failed", "context allocation failed")
            LlamaNative.LOAD_ERR_NO_BACKEND -> replyError(requestId, "no_backend", "no compute backend")
            else -> replyError(requestId, "load_failed", "model could not be loaded")
        }
    }

    private fun doUnload(requestId: Int) {
        runCatching { LlamaNative.nativeUnload() }
        loadedPath = null
        description = ""
        reply(LlmIpc.MSG_UNLOADED, requestId, Bundle())
    }

    private fun doGenerate(requestId: Int, data: Bundle) {
        if (cancelled.remove(requestId)) {
            reply(LlmIpc.MSG_DONE, requestId, Bundle().apply { putInt(LlmIpc.KEY_STATUS, LlamaNative.GEN_CANCELLED) })
            return
        }
        if (loadedPath == null) return replyError(requestId, "not_loaded", "no model loaded")
        val roles = data.getStringArray(LlmIpc.KEY_ROLES) ?: emptyArray()
        val contents = data.getStringArray(LlmIpc.KEY_CONTENTS) ?: emptyArray()
        if (roles.size != contents.size || roles.isEmpty()) return replyError(requestId, "bad_request", "messages")

        val stats = DoubleArray(5)
        currentRequest = requestId
        val status = try {
            LlamaNative.nativeGenerate(
                roles.map { it.toByteArray(Charsets.UTF_8) }.toTypedArray(),
                contents.map { it.toByteArray(Charsets.UTF_8) }.toTypedArray(),
                data.getInt(LlmIpc.KEY_MAX_TOKENS, 512),
                data.getFloat(LlmIpc.KEY_TEMPERATURE, 0.7f),
                data.getFloat(LlmIpc.KEY_TOP_P, 0.9f),
                data.getInt(LlmIpc.KEY_TOP_K, 40),
                data.getFloat(LlmIpc.KEY_REPEAT_PENALTY, 1.1f),
                TokenCallback { bytes ->
                    val delivered = reply(LlmIpc.MSG_TOKEN, requestId, Bundle().apply {
                        putString(LlmIpc.KEY_TEXT, String(bytes, Charsets.UTF_8))
                    })
                    delivered && !cancelled.contains(requestId)
                },
                stats,
            )
        } catch (t: Throwable) {
            currentRequest = NO_REQUEST
            cancelled.remove(requestId)
            return replyError(requestId, "generate_failed", t.javaClass.simpleName)
        }
        currentRequest = NO_REQUEST
        cancelled.remove(requestId)
        if (status < 0) {
            val code = when (status) {
                LlamaNative.GEN_ERR_PROMPT_TOO_LONG -> "prompt_too_long"
                LlamaNative.GEN_ERR_NOT_LOADED -> "not_loaded"
                LlamaNative.GEN_ERR_BUSY -> "busy"
                LlamaNative.GEN_ERR_TEMPLATE -> "template"
                LlamaNative.GEN_ERR_TOKENIZE -> "tokenize"
                else -> "decode"
            }
            return replyError(requestId, code, "status=$status")
        }
        reply(LlmIpc.MSG_DONE, requestId, Bundle().apply {
            putInt(LlmIpc.KEY_STATUS, status)
            putDoubleArray(LlmIpc.KEY_STATS, stats)
        })
    }

    private fun freeImageModel() {
        val h = sdHandle
        sdHandle = 0L
        sdKey = null
        if (h != 0L) runCatching { SdNative.nativeFree(h) }
    }

    private fun imageError(requestId: Int, code: String, avail: Long = 0L, need: Long = 0L) {
        reply(LlmIpc.MSG_IMAGE_ERROR, requestId, Bundle().apply {
            putString(LlmIpc.KEY_CODE, code)
            putLong(LlmIpc.KEY_AVAIL, avail)
            putLong(LlmIpc.KEY_NEED, need)
        })
    }

    private fun imageProgress(requestId: Int, phase: String, step: Int, steps: Int) {
        reply(LlmIpc.MSG_IMAGE_PROGRESS, requestId, Bundle().apply {
            putString(LlmIpc.KEY_PHASE, phase)
            putInt(LlmIpc.KEY_STEP, step)
            putInt(LlmIpc.KEY_STEPS, steps)
        })
    }

    /** Runs on the worker thread. Every native call is guarded; failures become error replies. */
    private fun doImage(requestId: Int, data: Bundle) {
        if (imageCancelled.remove(requestId)) return imageError(requestId, "cancelled")
        val model = data.getString(LlmIpc.KEY_MODEL).orEmpty()
        val taesd = data.getString(LlmIpc.KEY_TAESD).orEmpty()
        val out = data.getString(LlmIpc.KEY_OUT).orEmpty()
        val prompt = data.getString(LlmIpc.KEY_PROMPT).orEmpty()
        val width = data.getInt(LlmIpc.KEY_WIDTH, 512)
        val height = data.getInt(LlmIpc.KEY_HEIGHT, 512)
        val threads = data.getInt(LlmIpc.KEY_THREADS, 4)
        val force = data.getBoolean(LlmIpc.KEY_FORCE, false)
        val modelFile = File(model)
        if (!modelFile.isFile || !modelFile.canRead()) return imageError(requestId, "not_found")
        if (taesd.isNotEmpty() && !File(taesd).isFile) return imageError(requestId, "not_found")
        if (prompt.isBlank() || out.isEmpty()) return imageError(requestId, "generate_failed")
        try {
            SdNative.ensureLibrary()
        } catch (t: Throwable) {
            return imageError(requestId, "unsupported")
        }

        // One heavy model at a time: the chat model goes first.
        if (loadedPath != null) {
            runCatching { LlamaNative.nativeUnload() }
            loadedPath = null
            description = ""
            reply(LlmIpc.MSG_CHAT_UNLOADED, requestId, Bundle())
        }

        val key = "$model|$taesd|$threads"
        if (sdKey != key) freeImageModel()
        if (sdHandle == 0L) {
            val taesdBytes = if (taesd.isNotEmpty()) File(taesd).length() else 0L
            val need = estimateImageBytes(modelFile.length() + taesdBytes, width, height)
            val avail = availableMemory()
            if (!force && avail in 1 until need) return imageError(requestId, "low_ram", avail, need)
            imageProgress(requestId, "loading", 0, 0)
            val h = try {
                SdNative.nativeLoad(model, taesd, threads)
            } catch (t: Throwable) {
                0L
            }
            if (h == 0L) return imageError(requestId, "load_failed")
            sdHandle = h
            sdKey = key
        }
        if (imageCancelled.remove(requestId)) return imageError(requestId, "cancelled")

        val handle = sdHandle
        val seedOut = LongArray(1)
        val started = System.currentTimeMillis()
        currentImage = requestId
        val rc = try {
            SdNative.nativeGenerate(
                handle, prompt, data.getString(LlmIpc.KEY_NEGATIVE).orEmpty(), width, height,
                data.getInt(LlmIpc.KEY_STEPS, 0), data.getFloat(LlmIpc.KEY_CFG, 0f),
                data.getLong(LlmIpc.KEY_SEED, -1L), out,
                SdProgress { step, steps ->
                    imageProgress(requestId, if (step >= steps && steps > 0) "decoding" else "sampling", step, steps)
                },
                seedOut,
            )
        } catch (t: Throwable) {
            SdNative.ERR_GENERATE
        } finally {
            currentImage = NO_REQUEST
        }
        imageCancelled.remove(requestId)
        when (rc) {
            SdNative.OK -> reply(LlmIpc.MSG_IMAGE_DONE, requestId, Bundle().apply {
                putString(LlmIpc.KEY_PATH, out)
                putLong(LlmIpc.KEY_SEED, seedOut[0])
                putLong(LlmIpc.KEY_MILLIS, System.currentTimeMillis() - started)
            })
            SdNative.ERR_CANCELLED -> imageError(requestId, "cancelled")
            else -> {
                File(out).delete()
                imageError(requestId, "generate_failed")
            }
        }
    }

    private fun replyError(requestId: Int, code: String, message: String) {
        reply(LlmIpc.MSG_ERROR, requestId, Bundle().apply {
            putString(LlmIpc.KEY_CODE, code)
            putString(LlmIpc.KEY_MESSAGE, message)
        })
    }

    /** Returns false when the UI process is gone, which also stops generation. */
    private fun reply(what: Int, requestId: Int, data: Bundle): Boolean {
        val target = client ?: return false
        val msg = Message.obtain(null, what).apply {
            arg1 = requestId
            this.data = data
        }
        return try {
            target.send(msg)
            true
        } catch (e: RemoteException) {
            client = null
            false
        }
    }

    private fun availableMemory(): Long {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return 0L
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return info.availMem
    }

    companion object {
        private const val NO_REQUEST = Int.MIN_VALUE
        private const val HEADROOM_BYTES = 300L * 1024 * 1024

        /**
         * Rough peak RSS: weights (mmap'd, but they are touched on every token) + KV cache
         * (f16, sized by context; larger models have more layers/heads) + compute buffers.
         */
        fun estimateRequiredBytes(fileBytes: Long, nCtx: Int): Long {
            val perTokenKv = if (fileBytes > 1_500_000_000L) 120L * 1024 else 48L * 1024
            return fileBytes + perTokenKv * nCtx.coerceAtLeast(512) + HEADROOM_BYTES
        }

        /**
         * Rough peak RSS for Stable Diffusion: weights + latent/UNet/VAE compute buffers, which
         * grow with the pixel count (about 1 GB at 512x512 for SD 1.x/2.x on CPU).
         */
        fun estimateImageBytes(fileBytes: Long, width: Int, height: Int): Long {
            val pixels = width.toLong().coerceAtLeast(64) * height.toLong().coerceAtLeast(64)
            val compute = 1_000L * 1024 * 1024 * pixels / (512L * 512L)
            return fileBytes + compute + HEADROOM_BYTES
        }

        fun hasGgufMagic(file: File): Boolean = try {
            RandomAccessFile(file, "r").use { raf ->
                val b = ByteArray(4)
                raf.readFully(b)
                b[0] == 'G'.code.toByte() && b[1] == 'G'.code.toByte() &&
                    b[2] == 'U'.code.toByte() && b[3] == 'F'.code.toByte()
            }
        } catch (e: Exception) {
            false
        }
    }
}
