package com.exam.esw

import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 扫描文档：本地文字识别桥接（`esw/ocr` 通道）。
 *
 * 使用 Google ML Kit bundled 拉丁文字识别模型：模型随 APK 打包，
 * 不依赖 Google Play 服务、不需要联网，扫描过程完全离线。
 *
 * 返回结构（Dart 侧据此还原页面与段落）：
 * - text：按「块 = 段落、行 = 换行」重排后的纯文本，块之间空一行
 * - blocks：块数量（段落数），供界面提示「识别到 N 个段落」
 */
class OcrBridge(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "esw/ocr"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // 复用同一个识别器，避免每次扫描重复初始化模型（首帧更快）
    private var recognizer: TextRecognizer? = null

    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognizeText" -> recognize(call.argument<String>("path"), result)
            "close" -> {
                recognizer?.close()
                recognizer = null
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun recognize(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "图片路径为空", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("not_found", "图片不存在", null)
            return
        }
        val image = try {
            InputImage.fromFilePath(activity, android.net.Uri.fromFile(file))
        } catch (e: Exception) {
            result.error("bad_image", "图片无法读取: ${e.message}", null)
            return
        }

        val engine = recognizer ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            .also { recognizer = it }

        engine.process(image)
            .addOnSuccessListener { visionText ->
                // 块之间空一行 → 形成自然段落；块内每行一行文本
                val blocks = visionText.textBlocks
                val paragraphs = blocks.mapNotNull { block ->
                    val lineText = block.lines
                        .map { it.text.trim() }
                        .filter { it.isNotEmpty() }
                        .joinToString("\n")
                    lineText.ifBlank { null }
                }
                val payload = HashMap<String, Any>()
                payload["text"] = paragraphs.joinToString("\n\n")
                payload["blocks"] = paragraphs.size
                result.success(payload)
            }
            .addOnFailureListener { e ->
                result.error("ocr_failed", "文字识别失败: ${e.message}", null)
            }
    }
}
