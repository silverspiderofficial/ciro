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
        worker.execute { runCatching { if (loadedPath != null) LlamaNative.nativeUnload() } }
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
