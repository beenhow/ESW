package com.exam.esw

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生能力桥接：
 * - `esw/open_file`：用系统「打开方式」打开导出到本机的文档（docx / txt），
 *   通过 FileProvider 授予临时读权限，避免 Android 7+ 的 FileUriExposedException。
 * - `esw/ocr`：扫描文档内容，用 ML Kit 离线识别照片中的文字（见 [OcrBridge]）。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "esw/open_file"
    private val ocrBridge by lazy { OcrBridge(this) }
    private val scanBridge by lazy { ScanBridge(this) }
    private val docxPdfBridge by lazy { DocxPdfBridge(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> handleOpen(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OcrBridge.CHANNEL)
            .setMethodCallHandler { call, result -> ocrBridge.handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ScanBridge.CHANNEL)
            .setMethodCallHandler { call, result -> scanBridge.handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DocxPdfBridge.CHANNEL)
            .setMethodCallHandler { call, result -> docxPdfBridge.handle(call, result) }
    }

    /** 相机权限运行时申请的授权结果，转交 ScanBridge 回传给 Dart。 */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        scanBridge.onPermissionResult(requestCode, grantResults)
    }

    private fun handleOpen(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.success(false)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.success(false)
            return
        }
        val mime = when (file.extension.lowercase()) {
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "doc" -> "application/msword"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "txt" -> "text/plain"
            "pdf" -> "application/pdf"
            else -> "*/*"
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            // 设备上没有能打开该类型的应用：交回 Dart 侧兜底（重新打开检测结果页）
            result.success(false)
        } catch (e: Exception) {
            result.success(false)
        }
    }
}
