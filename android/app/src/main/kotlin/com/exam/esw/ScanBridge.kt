package com.exam.esw

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 扫描文档的几何处理：文本区域边界检测 + 四角透视校正。
 *
 * 设计原则：
 *  1. 完全本地计算，不依赖 Google Play 服务、不引入 OpenCV（包体代价过大）。
 *  2. 边界检测用「梯度投影」：文字/纸张边缘产生强梯度，行、列方向投影的峰值即内容边界，
 *     对试卷、书页这类横向排版文档非常有效，且计算量只有一次全图扫描。
 *  3. 检测失败或结果不可信时回退到「整图内缩 2%」，交回界面由用户手动拖角，
 *     绝不因检测失败而阻塞扫描。
 */
class ScanBridge(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "esw/scan"
        private const val DETECT_MAX_SIDE = 720
        private const val INSET_RATIO = 0.02
        private const val REQ_CAMERA = 0x5CA9
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPermission: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "detectQuad" -> detectQuad(call.argument<String>("path"), result)
            "warpQuad" -> warpQuad(call, result)
            "requestCameraPermission" -> requestCameraPermission(result)
            "sensorOrientation" -> result.success(readSensorOrientation())
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------- 相机权限 / 传感器方向

    /**
     * 运行时申请 CAMERA 权限。
     *
     * 自定义实时预览页直接由应用打开相机（不再借道系统相机 App），
     * 因此必须由本应用自己持有 CAMERA 权限；image_picker 走系统相机 Intent
     * 的那套「无需权限」路径在这里不成立。
     */
    private fun requestCameraPermission(result: MethodChannel.Result) {
        val granted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.CAMERA),
            REQ_CAMERA,
        )
    }

    /** MainActivity.onRequestPermissionsResult 转发到此，回传授权结果。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_CAMERA) return
        val result = pendingPermission
        pendingPermission = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        mainHandler.post { result?.success(granted) }
    }

    /**
     * 后置摄像头的 SENSOR_ORIENTATION（顺时针角度）。
     *
     * 图像流（imageStream）给到 Dart 的是传感器原始方向的画面，
     * 需要按该角度顺时针旋转才能与预览画面（已摆正）对齐；
     * 页面内已锁定竖屏，因此无需再叠加屏幕旋转补偿。
     */
    private fun readSensorOrientation(): Int {
        return try {
            val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val ids = manager.cameraIdList
            val backId = ids.firstOrNull { id ->
                manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: ids.firstOrNull()
            if (backId == null) {
                90
            } else {
                val value = manager.getCameraCharacteristics(backId)
                    .get(CameraCharacteristics.SENSOR_ORIENTATION)
                value ?: 90
            }
        } catch (e: Throwable) {
            90
        }
    }

    // ---------------------------------------------------------------- 边界检测

    private fun detectQuad(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank() || !File(path).exists()) {
            result.error("not_found", "图片不存在", null)
            return
        }
        runAsync(result) {
            val src = decodeSampled(path, DETECT_MAX_SIDE)
            val quad = findContentQuad(src)
            val payload = HashMap<String, Any>()
            payload["quad"] = quad
            payload["imageWidth"] = src.width
            payload["imageHeight"] = src.height
            src.recycle()
            payload
        }
    }

    /**
     * 返回归一化四角坐标 [x0,y0, x1,y1, x2,y2, x3,y3]，
     * 顺序为左上、右上、右下、左下，取值 0..1。
     */
    private fun findContentQuad(src: Bitmap): List<Double> {
        val w = src.width
        val h = src.height
        val fallback = insetQuad(INSET_RATIO)
        if (w < 32 || h < 32) return fallback

        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)

        // 灰度化 + 梯度强度（|dx| + |dy|，Sobel 的轻量近似）
        val gray = IntArray(w * h)
        for (i in pixels.indices) {
            val p = pixels[i]
            gray[i] = (((p shr 16 and 0xFF) * 299 + (p shr 8 and 0xFF) * 587 + (p and 0xFF) * 114) / 1000)
        }

        val rowScore = DoubleArray(h)
        val colScore = DoubleArray(w)
        var total = 0.0
        for (y in 1 until h - 1) {
            val base = y * w
            for (x in 1 until w - 1) {
                val c = base + x
                val dx = abs(gray[c + 1] - gray[c - 1])
                val dy = abs(gray[c + w] - gray[c - w])
                val s = (dx + dy).toDouble()
                if (s <= 0.0) continue
                rowScore[y] += s
                colScore[x] += s
                total += s
            }
        }
        if (total <= 0.0) return fallback

        val meanRow = total / max(1, w - 2) / max(1, h - 2)
        val rowThreshold = meanRow * 1.15
        val colThreshold = meanRow * 1.15

        val top = scanFromStart(rowScore, rowThreshold, (h * INSET_RATIO).toInt(), (h * 0.55).toInt())
        val bottom = scanFromEnd(rowScore, rowThreshold, (h * (1 - INSET_RATIO)).toInt(), (h * 0.45).toInt())
        val left = scanFromStart(colScore, colThreshold, (w * INSET_RATIO).toInt(), (w * 0.55).toInt())
        val right = scanFromEnd(colScore, colThreshold, (w * (1 - INSET_RATIO)).toInt(), (w * 0.45).toInt())

        if (top < 0 || bottom < 0 || left < 0 || right < 0) return fallback
        if (bottom - top < h * 0.30 || right - left < w * 0.30) return fallback

        // 内容区填满画面时（>97%）等价于没检测到边界，交回默认内缩
        val areaRatio = ((bottom - top).toDouble() / h) * ((right - left).toDouble() / w)
        if (areaRatio > 0.97) return fallback

        val l = left.toDouble() / w
        val t = top.toDouble() / h
        val r = right.toDouble() / w
        val b = bottom.toDouble() / h
        return listOf(l, t, r, t, r, b, l, b)
    }

    private fun scanFromStart(score: DoubleArray, threshold: Double, from: Int, to: Int): Int {
        var i = max(0, from)
        val end = min(score.size - 1, to)
        while (i <= end) {
            if (score[i] > threshold) return i
            i++
        }
        return -1
    }

    private fun scanFromEnd(score: DoubleArray, threshold: Double, from: Int, to: Int): Int {
        var i = min(score.size - 1, from)
        val end = max(0, to)
        while (i >= end) {
            if (score[i] > threshold) return i
            i--
        }
        return -1
    }

    private fun insetQuad(ratio: Double): List<Double> =
        listOf(ratio, ratio, 1 - ratio, ratio, 1 - ratio, 1 - ratio, ratio, 1 - ratio)

    // ---------------------------------------------------------------- 透视校正

    private fun warpQuad(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank() || !File(path).exists()) {
            result.error("not_found", "图片不存在", null)
            return
        }
        val raw = call.argument<List<Any?>>("quad")
        if (raw == null || raw.size != 8) {
            result.error("bad_args", "四角坐标必须为 8 个数值", null)
            return
        }
        val quad = raw.map { (it as? Number)?.toDouble() ?: Double.NaN }
        if (quad.any { it.isNaN() }) {
            result.error("bad_args", "四角坐标非法", null)
            return
        }
        val maxSide = call.argument<Int>("maxSide") ?: 2600

        runAsync(result) {
            val src = decodeOriented(path)
            val w = src.width.toDouble()
            val h = src.height.toDouble()

            val px = floatArrayOf(
                (quad[0].coerceIn(0.0, 1.0) * (w - 1)).toFloat(),
                (quad[1].coerceIn(0.0, 1.0) * (h - 1)).toFloat(),
                (quad[2].coerceIn(0.0, 1.0) * (w - 1)).toFloat(),
                (quad[3].coerceIn(0.0, 1.0) * (h - 1)).toFloat(),
                (quad[4].coerceIn(0.0, 1.0) * (w - 1)).toFloat(),
                (quad[5].coerceIn(0.0, 1.0) * (h - 1)).toFloat(),
                (quad[6].coerceIn(0.0, 1.0) * (w - 1)).toFloat(),
                (quad[7].coerceIn(0.0, 1.0) * (h - 1)).toFloat(),
            )

            var outW = max(hypot((px[2] - px[0]).toDouble(), (px[3] - px[1]).toDouble()),
                hypot((px[4] - px[6]).toDouble(), (px[5] - px[7]).toDouble())).roundToInt()
            var outH = max(hypot((px[6] - px[0]).toDouble(), (px[7] - px[1]).toDouble()),
                hypot((px[4] - px[2]).toDouble(), (px[5] - px[3]).toDouble())).roundToInt()
            outW = outW.coerceIn(64, 6000)
            outH = outH.coerceIn(64, 6000)

            val longest = max(outW, outH)
            if (longest > maxSide) {
                val k = maxSide.toDouble() / longest
                outW = max(64, (outW * k).roundToInt())
                outH = max(64, (outH * k).roundToInt())
            }

            val dst = floatArrayOf(0f, 0f, outW - 1f, 0f, outW - 1f, outH - 1f, 0f, outH - 1f)
            val matrix = Matrix()
            val mapped = matrix.setPolyToPoly(px, 0, dst, 0, 4)
            if (!mapped) {
                src.recycle()
                throw IllegalStateException("透视变换矩阵计算失败")
            }
            val out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            canvas.drawColor(android.graphics.Color.WHITE)
            canvas.drawBitmap(src, matrix, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
            src.recycle()

            val dir = File(activity.cacheDir, "scan_crop").apply { mkdirs() }
            val target = File(dir, "crop_${System.currentTimeMillis()}.jpg")
            FileOutputStream(target).use { fos ->
                out.compress(Bitmap.CompressFormat.JPEG, 92, fos)
            }
            val payload = HashMap<String, Any>()
            payload["path"] = target.absolutePath
            payload["width"] = out.width
            payload["height"] = out.height
            out.recycle()
            payload
        }
    }

    // ---------------------------------------------------------------- 位图工具

    /** 按长边上限降采样解码，并按 EXIF 方向摆正，供边界检测使用（不需要高分辨率）。 */
    private fun decodeSampled(path: String, maxSide: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        var longest = max(bounds.outWidth, bounds.outHeight)
        while (longest / sample > maxSide * 2) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val raw = BitmapFactory.decodeFile(path, opts)
            ?: throw IllegalStateException("图片解码失败")
        return applyExif(raw, path)
    }

    /** 全分辨率解码并摆正，供最终裁切使用。 */
    private fun decodeOriented(path: String): Bitmap {
        val raw = BitmapFactory.decodeFile(path)
            ?: throw IllegalStateException("图片解码失败")
        return applyExif(raw, path)
    }

    private fun applyExif(src: Bitmap, path: String): Bitmap {
        val orientation = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
            else -> return src
        }
        val rotated = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
        if (rotated != src) src.recycle()
        return rotated
    }

    private fun runAsync(result: MethodChannel.Result, work: () -> Map<String, Any>) {
        Thread {
            try {
                val payload = work()
                mainHandler.post { result.success(payload) }
            } catch (e: Throwable) {
                mainHandler.post { result.error("scan_failed", e.message ?: "处理失败", null) }
            }
        }.start()
    }
}
