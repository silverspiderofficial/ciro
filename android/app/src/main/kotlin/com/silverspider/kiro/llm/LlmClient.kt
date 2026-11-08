package com.silverspider.kiro.llm

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException

/**
 * UI-process side of the LLM IPC. Application scoped so an Activity recreation does not drop
 * the binding. All callbacks run on the main thread.
 */
object LlmClient {

    private val main = Handler(Looper.getMainLooper())
    private val incoming = Messenger(Handler(Looper.getMainLooper()) { msg -> onReply(msg); true })
    private var appContext: Context? = null
    private var service: Messenger? = null
    private var bound = false
    private val queue = ArrayList<Message>()
    private val pendingCalls = HashMap<Int, (Map<String, Any?>) -> Unit>()
    private val activeGenerations = HashSet<Int>()
    private val activeImages = HashSet<Int>()
    private var nextInternalId = 1_000_000

    /** Receives streaming events: token / done / error / connected / process_died. */
    var eventSink: ((Map<String, Any?>) -> Unit)? = null

    /** Receives image events: progress / done / error, each with "id". */
    var imageSink: ((Map<String, Any?>) -> Unit)? = null

    val isConnected: Boolean get() = service != null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = Messenger(binder)
            val pending = ArrayList(queue)
            queue.clear()
            pending.forEach { sendNow(it) }
            emit(mapOf("event" to "connected"))
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // The ":ai" process died (OOM or native crash). Android re-creates it and calls
            // onServiceConnected again because we stay bound with BIND_AUTO_CREATE.
            service = null
            failAllPending("process_died")
            emit(mapOf("event" to "process_died"))
        }

        override fun onBindingDied(name: ComponentName?) {
            service = null
            failAllPending("process_died")
            emit(mapOf("event" to "process_died"))
            val ctx = appContext ?: return
            runCatching { ctx.unbindService(this) }
            bound = false
            bind(ctx)
        }
    }

    fun bind(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        if (bound) return
        bound = ctx.bindService(Intent(ctx, LlmService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    fun load(path: String, nCtx: Int, threads: Int, force: Boolean, done: (Map<String, Any?>) -> Unit) {
        val id = nextInternalId++
        pendingCalls[id] = done
        send(LlmIpc.MSG_LOAD, id, Bundle().apply {
            putString(LlmIpc.KEY_PATH, path)
            putInt(LlmIpc.KEY_N_CTX, nCtx)
            putInt(LlmIpc.KEY_THREADS, threads)
            putBoolean(LlmIpc.KEY_FORCE, force)
        })
    }

    fun unload(done: (Map<String, Any?>) -> Unit) {
        val id = nextInternalId++
        pendingCalls[id] = done
        send(LlmIpc.MSG_UNLOAD, id, Bundle())
    }

    fun status(done: (Map<String, Any?>) -> Unit) {
        val id = nextInternalId++
        pendingCalls[id] = done
        send(LlmIpc.MSG_STATUS, id, Bundle())
    }

    fun generate(
        requestId: Int,
        roles: List<String>,
        contents: List<String>,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        repeatPenalty: Double,
    ) {
        activeGenerations.add(requestId)
        send(LlmIpc.MSG_GENERATE, requestId, Bundle().apply {
            putStringArray(LlmIpc.KEY_ROLES, roles.toTypedArray())
            putStringArray(LlmIpc.KEY_CONTENTS, contents.toTypedArray())
            putInt(LlmIpc.KEY_MAX_TOKENS, maxTokens)
            putFloat(LlmIpc.KEY_TEMPERATURE, temperature.toFloat())
            putFloat(LlmIpc.KEY_TOP_P, topP.toFloat())
            putInt(LlmIpc.KEY_TOP_K, topK)
            putFloat(LlmIpc.KEY_REPEAT_PENALTY, repeatPenalty.toFloat())
        })
    }

    fun generateImage(requestId: Int, args: Map<String, Any?>) {
        activeImages.add(requestId)
        send(LlmIpc.MSG_IMAGE_GENERATE, requestId, Bundle().apply {
            putString(LlmIpc.KEY_PROMPT, args["prompt"] as? String ?: "")
            putString(LlmIpc.KEY_NEGATIVE, args["negative"] as? String ?: "")
            putString(LlmIpc.KEY_MODEL, args["model"] as? String ?: "")
            putString(LlmIpc.KEY_TAESD, args["taesd"] as? String ?: "")
            putString(LlmIpc.KEY_OUT, args["out"] as? String ?: "")
            putInt(LlmIpc.KEY_WIDTH, (args["width"] as? Number)?.toInt() ?: 512)
            putInt(LlmIpc.KEY_HEIGHT, (args["height"] as? Number)?.toInt() ?: 512)
            putInt(LlmIpc.KEY_STEPS, (args["steps"] as? Number)?.toInt() ?: 0)
            putFloat(LlmIpc.KEY_CFG, (args["cfg"] as? Number)?.toFloat() ?: 0f)
            putLong(LlmIpc.KEY_SEED, (args["seed"] as? Number)?.toLong() ?: -1L)
            putInt(LlmIpc.KEY_THREADS, (args["threads"] as? Number)?.toInt() ?: 4)
            putBoolean(LlmIpc.KEY_FORCE, args["force"] as? Boolean ?: false)
        })
    }

    fun cancelImage(requestId: Int) {
        send(LlmIpc.MSG_IMAGE_CANCEL, requestId, Bundle())
    }

    fun unloadImage(done: (Map<String, Any?>) -> Unit) {
        val id = nextInternalId++
        pendingCalls[id] = done
        send(LlmIpc.MSG_IMAGE_UNLOAD, id, Bundle())
    }

    fun cancel(requestId: Int) {
        send(LlmIpc.MSG_CANCEL, requestId, Bundle())
    }

    private fun send(what: Int, id: Int, data: Bundle) {
        val msg = Message.obtain(null, what).apply {
            arg1 = id
            this.data = data
            replyTo = incoming
        }
        if (service == null) {
            queue.add(msg)
            appContext?.let { bind(it) }
        } else {
            sendNow(msg)
        }
    }

    private fun sendNow(msg: Message) {
        try {
            service?.send(msg) ?: queue.add(msg)
        } catch (e: RemoteException) {
            service = null
            failAllPending("process_died")
            emit(mapOf("event" to "process_died"))
        }
    }

    private fun onReply(msg: Message) {
        val id = msg.arg1
        val data = msg.data ?: Bundle()
        when (msg.what) {
            LlmIpc.MSG_TOKEN -> emit(mapOf("event" to "token", "id" to id, "text" to data.getString(LlmIpc.KEY_TEXT)))
            LlmIpc.MSG_DONE -> {
                activeGenerations.remove(id)
                val stats = data.getDoubleArray(LlmIpc.KEY_STATS) ?: DoubleArray(5)
                emit(mapOf(
                    "event" to "done",
                    "id" to id,
                    "status" to data.getInt(LlmIpc.KEY_STATUS),
                    "promptTokens" to stats.getOrElse(0) { 0.0 }.toInt(),
                    "reusedTokens" to stats.getOrElse(1) { 0.0 }.toInt(),
                    "generatedTokens" to stats.getOrElse(2) { 0.0 }.toInt(),
                    "prefillMs" to stats.getOrElse(3) { 0.0 },
                    "generateMs" to stats.getOrElse(4) { 0.0 },
                ))
            }
            LlmIpc.MSG_IMAGE_PROGRESS -> emitImage(mapOf(
                "event" to "progress",
                "id" to id,
                "phase" to data.getString(LlmIpc.KEY_PHASE),
                "step" to data.getInt(LlmIpc.KEY_STEP),
                "steps" to data.getInt(LlmIpc.KEY_STEPS),
            ))
            LlmIpc.MSG_IMAGE_DONE -> {
                activeImages.remove(id)
                emitImage(mapOf(
                    "event" to "done",
                    "id" to id,
                    "path" to data.getString(LlmIpc.KEY_PATH),
                    "seed" to data.getLong(LlmIpc.KEY_SEED),
                    "millis" to data.getLong(LlmIpc.KEY_MILLIS),
                ))
            }
            LlmIpc.MSG_IMAGE_ERROR -> {
                activeImages.remove(id)
                emitImage(mapOf(
                    "event" to "error",
                    "id" to id,
                    "code" to data.getString(LlmIpc.KEY_CODE),
                    "availBytes" to data.getLong(LlmIpc.KEY_AVAIL),
                    "needBytes" to data.getLong(LlmIpc.KEY_NEED),
                ))
            }
            LlmIpc.MSG_CHAT_UNLOADED -> emit(mapOf("event" to "unloaded_by_studio"))
            LlmIpc.MSG_LOADED -> complete(id, mapOf(
                "ok" to true,
                "path" to data.getString(LlmIpc.KEY_PATH),
                "description" to data.getString(LlmIpc.KEY_DESCRIPTION),
            ))
            LlmIpc.MSG_UNLOADED -> complete(id, mapOf("ok" to true))
            LlmIpc.MSG_STATUS_REPLY -> complete(id, mapOf(
                "ok" to true,
                "loaded" to data.getBoolean(LlmIpc.KEY_LOADED),
                "path" to data.getString(LlmIpc.KEY_PATH),
                "description" to data.getString(LlmIpc.KEY_DESCRIPTION),
            ))
            LlmIpc.MSG_ERROR -> {
                val error = mapOf(
                    "ok" to false,
                    "code" to data.getString(LlmIpc.KEY_CODE),
                    "message" to data.getString(LlmIpc.KEY_MESSAGE),
                    "availBytes" to data.getLong(LlmIpc.KEY_AVAIL),
                    "needBytes" to data.getLong(LlmIpc.KEY_NEED),
                )
                if (pendingCalls.containsKey(id)) {
                    complete(id, error)
                } else {
                    activeGenerations.remove(id)
                    emit(error + mapOf("event" to "error", "id" to id))
                }
            }
        }
    }

    private fun complete(id: Int, result: Map<String, Any?>) {
        pendingCalls.remove(id)?.invoke(result)
    }

    private fun failAllPending(code: String) {
        val calls = HashMap(pendingCalls)
        pendingCalls.clear()
        calls.values.forEach { it(mapOf("ok" to false, "code" to code, "message" to code)) }
        val gens = ArrayList(activeGenerations)
        activeGenerations.clear()
        gens.forEach { emit(mapOf("event" to "error", "id" to it, "code" to code, "message" to code)) }
        val images = ArrayList(activeImages)
        activeImages.clear()
        images.forEach { emitImage(mapOf("event" to "error", "id" to it, "code" to code)) }
    }

    private fun emitImage(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) imageSink?.invoke(event) else main.post { imageSink?.invoke(event) }
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) eventSink?.invoke(event) else main.post { eventSink?.invoke(event) }
    }
}
