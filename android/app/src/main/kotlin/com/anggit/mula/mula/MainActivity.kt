package com.anggit.mula.mula

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val documentExecutor = Executors.newSingleThreadExecutor()
    private var pendingDocument: MethodChannel.Result? = null
    private var pendingContents: String? = null
    private val documentLimit = 8 * 1024 * 1024

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val alarms = MulaAlarmDiagnostics(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mula/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveBackupDocument" -> {
                        val contents = call.argument<String>("contents")
                        val filename = call.argument<String>("filename")
                        if (contents == null || filename == null || contents.toByteArray(Charsets.UTF_8).size > documentLimit) {
                            result.error("INVALID_DOCUMENT", "Cadangan tidak valid atau melebihi 8 MB.", null)
                        } else {
                            chooseDocument(result, contents, Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/json"
                                putExtra(Intent.EXTRA_TITLE, filename)
                            }, 4011)
                        }
                    }
                    "openBackupDocument" -> chooseDocument(result, null, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
                    }, 4012)
                    else -> if (!alarms.handle(call, result)) result.notImplemented()
                }
            }
    }

    private fun chooseDocument(result: MethodChannel.Result, contents: String?, intent: Intent, code: Int) {
        if (pendingDocument != null) {
            result.error("DOCUMENT_BUSY", "Selesaikan pemilihan berkas yang sedang terbuka.", null)
            return
        }
        pendingDocument = result
        pendingContents = contents
        try {
            startActivityForResult(intent, code)
        } catch (error: Exception) {
            pendingDocument = null
            pendingContents = null
            result.error("DOCUMENT_PICKER", "Pemilih berkas Android tidak tersedia.", null)
        }
    }

    @Deprecated("The Flutter activity forwards platform document picker results through this callback.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4011 && requestCode != 4012) return
        val result = pendingDocument ?: return
        val contents = pendingContents
        pendingDocument = null
        pendingContents = null
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(if (requestCode == 4011) false else null)
            return
        }
        documentExecutor.execute {
            try {
                val value: Any = if (requestCode == 4011) {
                    contentResolver.openOutputStream(uri, "wt")?.use { stream ->
                        stream.write(requireNotNull(contents).toByteArray(Charsets.UTF_8))
                        stream.flush()
                    } ?: throw IllegalStateException("Berkas tidak dapat ditulis.")
                    true
                } else {
                    contentResolver.openInputStream(uri)?.use { stream ->
                        val buffer = ByteArray(8192)
                        val output = ByteArrayOutputStream()
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            if (output.size() + read > documentLimit) throw IllegalArgumentException("Cadangan melebihi 8 MB.")
                            output.write(buffer, 0, read)
                        }
                        val decoder = Charsets.UTF_8.newDecoder()
                        decoder.decode(java.nio.ByteBuffer.wrap(output.toByteArray())).toString()
                    } ?: throw IllegalStateException("Berkas tidak dapat dibaca.")
                }
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("DOCUMENT_IO", error.message ?: "Berkas tidak dapat dibuka.", null) }
            }
        }
    }

    override fun onDestroy() {
        pendingDocument?.error("DOCUMENT_CLOSED", "Pemilihan berkas ditutup. Buka kembali dan coba lagi.", null)
        pendingDocument = null
        pendingContents = null
        documentExecutor.shutdown()
        super.onDestroy()
    }
}
