package com.silverspider.kiro

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.silverspider.kiro.device.DeviceInfoProvider
import com.silverspider.kiro.download.ModelDownloadService
import com.silverspider.kiro.files.DocumentBridge
import com.silverspider.kiro.llm.LlmClient
import com.silverspider.kiro.security.SecurityChecks
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var downloadSink: EventChannel.EventSink? = null
    private var llmSink: EventChannel.EventSink? = null

    private var pendingImport: MethodChannel.Result? = null
    private var pendingTextOpen: MethodChannel.Result? = null
    private var pendingTextSave: MethodChannel.Result? = null
    private var pendingSaveContent: String = ""

    private lateinit var importLauncher: ActivityResultLauncher<Array<String>>
    private lateinit var openTextLauncher: ActivityResultLauncher<Array<String>>
    private lateinit var saveTextLauncher: ActivityResultLauncher<String>

    override fun onCreate(savedInstanceState: Bundle?) {
        // Activity result launchers must be registered before the activity is STARTED.
        importLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> onModelPicked(uri) }
        openTextLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> onTextPicked(uri) }
        saveTextLauncher = registerForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { uri -> onTextTarget(uri) }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "kiro/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(DeviceInfoProvider.collect(this))
                "security" -> result.success(SecurityChecks.check(this))
                "setSecure" -> {
                    if (call.argument<Boolean>("enabled") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "requestNotifications" -> result.success(requestNotificationPermission())
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "kiro/llm").setMethodCallHandler { call, result -> onLlmCall(call, result) }
        EventChannel(messenger, "kiro/llm/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                llmSink = events
                LlmClient.eventSink = { event -> llmSink?.success(event) }
            }

            override fun onCancel(arguments: Any?) {
                llmSink = null
                LlmClient.eventSink = null
            }
        })

        MethodChannel(messenger, "kiro/models").setMethodCallHandler { call, result -> onModelsCall(call, result) }
        EventChannel(messenger, "kiro/models/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                downloadSink = events
                ModelDownloadService.listener = { event -> downloadSink?.success(event) }
            }

            override fun onCancel(arguments: Any?) {
                downloadSink = null
                ModelDownloadService.listener = null
            }
        })

        MethodChannel(messenger, "kiro/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "openText" -> {
                    if (pendingTextOpen != null) return@setMethodCallHandler result.error("busy", null, null)
                    pendingTextOpen = result
                    openTextLauncher.launch(arrayOf("text/markdown", "text/plain", "text/x-markdown", "application/octet-stream"))
                }
                "saveText" -> {
                    if (pendingTextSave != null) return@setMethodCallHandler result.error("busy", null, null)
                    pendingTextSave = result
                    pendingSaveContent = call.argument<String>("content").orEmpty()
                    saveTextLauncher.launch(call.argument<String>("name") ?: "skill.md")
                }
                else -> result.notImplemented()
            }
        }

        LlmClient.bind(this)
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) {
            LlmClient.eventSink = null
            ModelDownloadService.listener = null
        }
        io.shutdown()
        super.onDestroy()
    }

    private fun onLlmCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> LlmClient.load(
                call.argument<String>("path").orEmpty(),
                call.argument<Int>("nCtx") ?: 4096,
                call.argument<Int>("threads") ?: 4,
                call.argument<Boolean>("force") ?: false,
            ) { result.success(it) }
            "unload" -> LlmClient.unload { result.success(it) }
            "status" -> LlmClient.status { result.success(it) }
            "connected" -> result.success(LlmClient.isConnected)
            "generate" -> {
                val messages = call.argument<List<Map<String, String>>>("messages").orEmpty()
                LlmClient.generate(
                    requestId = call.argument<Int>("id") ?: 0,
                    roles = messages.map { it["role"].orEmpty() },
                    contents = messages.map { it["content"].orEmpty() },
                    maxTokens = call.argument<Int>("maxTokens") ?: 512,
                    temperature = call.argument<Double>("temperature") ?: 0.7,
                    topP = call.argument<Double>("topP") ?: 0.9,
                    topK = call.argument<Int>("topK") ?: 40,
                    repeatPenalty = call.argument<Double>("repeatPenalty") ?: 1.1,
                )
                result.success(true)
            }
            "cancel" -> {
                LlmClient.cancel(call.argument<Int>("id") ?: 0)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun onModelsCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "dir" -> result.success(ModelDownloadService.modelsDir(this).absolutePath)
            "partSize" -> result.success(ModelDownloadService.partSize(this, call.argument<String>("fileName").orEmpty()))
            "active" -> result.success(ModelDownloadService.cancelFlags.keys().toList())
            "download" -> {
                val intent = Intent(this, ModelDownloadService::class.java)
                    .setAction(ModelDownloadService.ACTION_START)
                    .putExtra(ModelDownloadService.EXTRA_ID, call.argument<String>("id"))
                    .putExtra(ModelDownloadService.EXTRA_URL, call.argument<String>("url"))
                    .putExtra(ModelDownloadService.EXTRA_SHA256, call.argument<String>("sha256"))
                    .putExtra(ModelDownloadService.EXTRA_SIZE, (call.argument<Number>("size") ?: -1).toLong())
                    .putExtra(ModelDownloadService.EXTRA_FILE, call.argument<String>("fileName"))
                    .putExtra(ModelDownloadService.EXTRA_TITLE, call.argument<String>("title"))
                ContextCompat.startForegroundService(this, intent)
                result.success(true)
            }
            "cancel" -> {
                val id = call.argument<String>("id").orEmpty()
                ModelDownloadService.cancelFlags[id]?.set(true)
                result.success(true)
            }
            "deletePart" -> {
                val name = call.argument<String>("fileName").orEmpty()
                if (ModelDownloadService.isSafeFileName(name)) {
                    File(ModelDownloadService.modelsDir(this), name + ModelDownloadService.PART_SUFFIX).delete()
                }
                result.success(true)
            }
            "import" -> {
                if (pendingImport != null) return result.error("busy", null, null)
                pendingImport = result
                importLauncher.launch(arrayOf("application/octet-stream", "*/*"))
            }
            else -> result.notImplemented()
        }
    }

    private fun onModelPicked(uri: Uri?) {
        val result = pendingImport ?: return
        pendingImport = null
        if (uri == null) return result.success(null)
        io.execute {
            try {
                val info = DocumentBridge.importModel(this, uri) { received, total ->
                    main.post {
                        downloadSink?.success(mapOf("id" to "import", "state" to "running", "received" to received, "total" to total))
                    }
                }
                main.post { result.success(info) }
            } catch (e: DocumentBridge.ImportException) {
                main.post { result.error(e.code, null, null) }
            }
        }
    }

    private fun onTextPicked(uri: Uri?) {
        val result = pendingTextOpen ?: return
        pendingTextOpen = null
        if (uri == null) return result.success(null)
        io.execute {
            try {
                val data = DocumentBridge.readText(this, uri)
                main.post { result.success(data) }
            } catch (e: Exception) {
                val code = (e as? DocumentBridge.ImportException)?.code ?: "io"
                main.post { result.error(code, null, null) }
            }
        }
    }

    private fun onTextTarget(uri: Uri?) {
        val result = pendingTextSave ?: return
        pendingTextSave = null
        val content = pendingSaveContent
        pendingSaveContent = ""
        if (uri == null) return result.success(false)
        io.execute {
            try {
                DocumentBridge.writeText(this, uri, content)
                main.post { result.success(true) }
            } catch (e: Exception) {
                main.post { result.error("io", null, null) }
            }
        }
    }

    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4102)
        return granted
    }
}
