package com.exam.esw

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * 原排版 docx -> PDF（确定性逐页渲染版）：
 *
 * 事实：WebView 的「初始渲染」一定能被 draw(Canvas) 截到（第一页就是这样截到的），
 * 而滚动之后的重绘在离屏/异步栅格化情况下拿不到内容，于是后面全是空白。
 *
 * 所以这里不再滚动、不再猜延时：每一页都重新加载同一份 HTML，并把该页的内容
 * 偏移（body 负 margin）直接写进 HTML，让目标页在**首次渲染**时就落在视口里，
 * 然后直接截图。页数换时间，但结果确定。
 */
class DocxPdfBridge(private val activity: Activity) {
    companion object {
        const val CHANNEL = "esw/docx_pdf"
        private const val ASSET_DIR = "flutter_assets/assets/docx_pdf"
        // A4 在 96dpi 下的 CSS 尺寸
        private const val PAGE_W = 794
        private const val PAGE_H = 1123
        private const val BASE_URL = "https://esw.local/"
        // 几乎不可见，但必须 > 0：alpha 为 0 时 View 不参与绘制
        private const val GHOST_ALPHA = 0.01f
        // 单页重新加载的超时
        private const val PAGE_TIMEOUT_MS = 40_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var finished = false
    private var visualStateSeq = 0L

    private var pages: List<PdfPage> = emptyList()
    private var pdf: PdfDocument? = null
    private var outPath: String = ""
    private var pendingIndex = -1
    private var pendingRetried = false

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "convert") {
            result.notImplemented()
            return
        }
        val docxPath = call.argument<String>("docxPath")
        val outPath = call.argument<String>("outPath")
        if (docxPath.isNullOrBlank() || outPath.isNullOrBlank()) {
            result.error("bad_args", "docxPath/outPath 不能为空", null)
            return
        }
        activity.runOnUiThread { start(docxPath, outPath, result) }
    }

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    private fun start(docxPath: String, outPath: String, result: MethodChannel.Result) {
        cleanup()
        finished = false
        pages = emptyList()
        pdf = null
        pendingIndex = -1
        this.outPath = outPath
        finalResult = result

        val src = File(docxPath)
        if (!src.exists() || src.length() == 0L) {
            result.error("no_src", "源 docx 不存在", null)
            return
        }

        val web = WebView(activity)
        webView = web
        web.settings.javaScriptEnabled = true
        web.settings.allowFileAccess = false
        web.settings.allowContentAccess = false
        web.settings.useWideViewPort = false
        web.settings.loadWithOverviewMode = false
        web.setInitialScale(100)
        web.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
        web.setBackgroundColor(Color.WHITE)
        web.isHorizontalScrollBarEnabled = false
        web.isVerticalScrollBarEnabled = false
        web.layoutParams = ViewGroup.LayoutParams(PAGE_W, PAGE_H)
        web.translationX = 0f
        web.translationY = 0f
        // 近乎透明地摆在屏幕上：用户看不见，但 View 处于可见状态
        web.alpha = GHOST_ALPHA
        web.setOnTouchListener { _, _ -> true }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                return when (request.url.path) {
                    "/jszip.min.js" -> assetResponse("jszip.min.js", "application/javascript")
                    "/docx-preview.min.js" ->
                        assetResponse("docx-preview.min.js", "application/javascript")
                    "/docx" -> WebResourceResponse(
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                        null,
                        FileInputStream(src),
                    )
                    else -> null
                }
            }
        }
        web.addJavascriptInterface(object {
            /** 首次加载完成：量取总高度与切页位置。 */
            @JavascriptInterface
            fun onRendered() {
                activity.runOnUiThread { beginExport(web) }
            }

            /** 按页重新加载完成：直接截当前这一页。 */
            @JavascriptInterface
            fun onPageReady() {
                activity.runOnUiThread {
                    val index = pendingIndex
                    if (index < 0) return@runOnUiThread
                    val retried = pendingRetried
                    capturePage(web, index, retried)
                }
            }

            @JavascriptInterface
            fun onError(message: String?) {
                activity.runOnUiThread {
                    finishError(message ?: "docx 渲染失败", finalResult)
                }
            }
        }, "ESW")

        try {
            val root = activity.findViewById<ViewGroup>(android.R.id.content)
            root.addView(web)
            web.loadDataWithBaseURL(
                BASE_URL,
                htmlFor(offset = 0, measure = true),
                "text/html",
                "utf-8",
                null,
            )
        } catch (e: Exception) {
            finishError(e.message ?: "WebView 初始化失败", result)
            return
        }
        mainHandler.postDelayed({
            finishError("docx 转 PDF 超时", result)
        }, 600_000)
    }

    private var finalResult: MethodChannel.Result? = null

    private fun assetResponse(name: String, mime: String): WebResourceResponse? {
        return try {
            WebResourceResponse(mime, "utf-8", activity.assets.open("$ASSET_DIR/$name"))
        } catch (_: Exception) {
            null
        }
    }

    /** 首次加载后：量取内容高度与切页位置，然后开始逐页渲染。 */
    private fun beginExport(web: WebView) {
        if (finished) return
        web.evaluateJavascript(
            "JSON.stringify({c: window.__eswCuts || [], h: window.__eswHeight || 0})"
        ) { raw ->
            val (cuts, height) = parseLayout(raw)
            val built = buildPages(height, cuts)
            if (built.isEmpty()) {
                finishError("docx 内容为空", finalResult)
                return@evaluateJavascript
            }
            pages = built
            pdf = PdfDocument()
            capturePage(web, 0, false)
        }
    }

    private fun parseLayout(raw: String?): Pair<List<Int>, Int> {
        if (raw.isNullOrBlank() || raw == "null") return emptyList<Int>() to 0
        return try {
            val json = JSONTokener(raw).nextValue() as? String
                ?: return emptyList<Int>() to 0
            val obj = JSONObject(json)
            val arr = obj.optJSONArray("c") ?: JSONArray()
            val cuts = (0 until arr.length())
                .map { i -> arr.optInt(i, -1) }
                .filter { it > 0 }
            cuts to obj.optInt("h", 0)
        } catch (_: Exception) {
            emptyList<Int>() to 0
        }
    }

    /** 一页 PDF 的内容区间（CSS px）。 */
    private data class PdfPage(val top: Int, val height: Int)

    /**
     * 按 A4 高度切页，切点优先落在行（段落 / 表格行）顶端，
     * 避免把一行文字或一条表格行截成两半。
     */
    private fun buildPages(height: Int, cuts: List<Int>): List<PdfPage> {
        if (height <= 0) return emptyList()
        val sorted = cuts.sorted()
        val result = ArrayList<PdfPage>()
        var start = 0
        while (start < height) {
            val end: Int
            if (start + PAGE_H >= height) {
                end = height
            } else {
                val limit = start + PAGE_H
                val snap = sorted.lastOrNull { it > start + PAGE_H / 2 && it <= limit }
                end = snap ?: limit
            }
            if (end <= start) break
            result.add(PdfPage(start, end - start))
            start = end
        }
        return result
    }

    /** 截当前页（页面已按该页偏移渲染完成）。 */
    private fun capturePage(web: WebView, index: Int, retried: Boolean) {
        pendingIndex = -1
        if (finished) return
        val doc = pdf ?: return
        if (index >= pages.size) {
            writePdf(doc, finalResult)
            return
        }
        val page = pages[index]

        var captured = false
        val doCapture = Runnable {
            if (captured || finished) return@Runnable
            captured = true
            try {
                val bitmap = drawPage(web)
                if (index > 0 && !retried && isBlank(bitmap)) {
                    // 理论上不会发生；真发生时同页再渲染一次
                    bitmap.recycle()
                    reloadForPage(web, index, true)
                    return@Runnable
                }
                appendPage(doc, bitmap, page, index)
                if (index + 1 < pages.size) {
                    reloadForPage(web, index + 1, false)
                } else {
                    writePdf(doc, finalResult)
                }
            } catch (e: Exception) {
                finishError(e.message ?: "PDF 页面渲染失败", finalResult)
            }
        }

        web.scrollTo(0, 0)
        try {
            web.postVisualStateCallback(
                ++visualStateSeq,
                object : WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) {
                        mainHandler.post(doCapture)
                    }
                },
            )
        } catch (_: Exception) {
        }
        mainHandler.postDelayed(doCapture, if (index == 0) 300L else 200L)
    }

    /** 重新加载同一份文档，并把目标页偏移预置进 HTML（首帧即目标页）。 */
    private fun reloadForPage(web: WebView, index: Int, retried: Boolean) {
        if (finished) return
        pendingIndex = index
        pendingRetried = retried
        val offset = pages.getOrNull(index)?.top ?: 0
        web.loadDataWithBaseURL(
            BASE_URL,
            htmlFor(offset = offset, measure = false),
            "text/html",
            "utf-8",
            null,
        )
        val watchdogIndex = index
        mainHandler.postDelayed({
            if (!finished && pendingIndex == watchdogIndex) {
                finishError("单页渲染超时", finalResult)
            }
        }, PAGE_TIMEOUT_MS)
    }

    private fun drawPage(web: WebView): Bitmap {
        val bitmap = Bitmap.createBitmap(PAGE_W, PAGE_H, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        web.draw(canvas)
        return bitmap
    }

    private fun appendPage(
        doc: PdfDocument,
        bitmap: Bitmap,
        page: PdfPage,
        pageIndex: Int,
    ) {
        // 末页不足一页：按内容高度裁掉多余部分，避免与下一页重复
        val srcH = minOf(page.height, PAGE_H)
        val dstH = 842f * srcH / PAGE_H
        val info = PdfDocument.PageInfo.Builder(595, 842, pageIndex + 1).create()
        val pdfPage = doc.startPage(info)
        pdfPage.canvas.drawBitmap(
            bitmap,
            Rect(0, 0, PAGE_W, srcH),
            RectF(0f, 0f, 595f, dstH),
            Paint(Paint.FILTER_BITMAP_FLAG),
        )
        doc.finishPage(pdfPage)
        bitmap.recycle()
    }

    private fun writePdf(doc: PdfDocument, result: MethodChannel.Result?) {
        try {
            val out = File(outPath)
            out.parentFile?.mkdirs()
            FileOutputStream(out).use { doc.writeTo(it) }
            doc.close()
            finishOk(result)
        } catch (e: Exception) {
            doc.close()
            finishError(e.message ?: "写出 PDF 失败", result)
        }
    }

    /** 抽样判断是否整页空白（用于极端情况下的重试）。 */
    private fun isBlank(bitmap: Bitmap): Boolean {
        val stepX = 24
        val stepY = 24
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val c = bitmap.getPixel(x, y)
                if (Color.red(c) < 245 || Color.green(c) < 245 || Color.blue(c) < 245) {
                    return false
                }
                x += stepX
            }
            y += stepY
        }
        return true
    }

    private fun finishOk(result: MethodChannel.Result?) {
        if (finished) return
        finished = true
        cleanup()
        try {
            result?.success(true)
        } catch (_: Exception) {
        }
    }

    private fun finishError(message: String, result: MethodChannel.Result?) {
        if (finished) return
        finished = true
        cleanup()
        try {
            result?.error("docx_pdf_failed", message, null)
        } catch (_: Exception) {
        }
    }

    private fun cleanup() {
        mainHandler.removeCallbacksAndMessages(null)
        val w = webView ?: return
        webView = null
        try {
            (w.parent as? ViewGroup)?.removeView(w)
            w.destroy()
        } catch (_: Exception) {
        }
    }

    /**
     * 生成页面 HTML：
     * - offset：把目标页顶端对齐视口顶端（负 margin，写在 head 里，首帧即生效）
     * - measure：首次加载时量取内容高度与切页位置
     */
    private fun htmlFor(offset: Int, measure: Boolean): String {
        val callback = if (measure) "onRendered" else "onPageReady"
        val wait = if (measure) 600 else 250
        val measureJs = if (measure) MEASURE_JS else ""
        return HTML
            .replace("@OFFSET@", offset.toString())
            .replace("@WAIT@", wait.toString())
            .replace("@MEASURE@", measureJs)
            .replace("@CALLBACK@", callback)
    }

    private val HTML = """
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=794, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
html,body{margin:0;padding:0;background:#fff;
  -webkit-print-color-adjust:exact;print-color-adjust:exact;}
/* 目标页偏移：直接写进样式，保证首帧就落在视口里 */
body{margin-top:-@OFFSET@px!important;}
.docx-wrapper{background:#fff!important;padding:0!important;box-shadow:none!important;
  display:block!important;}
.docx-wrapper>section.docx{margin:0!important;box-shadow:none!important;}
/* docx-preview 默认 overflow:hidden + 固定页高，会把超过一页的内容裁掉；
   解除后页面高度等于真实内容高度，才能按 A4 切片分页。 */
section.docx{height:auto!important;min-height:0!important;overflow:visible!important;
  display:block!important;}
.docx article{margin-bottom:0!important;}
</style></head>
<body><div id="host"></div>
<script src="/jszip.min.js"></script>
<script src="/docx-preview.min.js"></script>
<script>
(async function(){
  try{
    var res = await fetch('/docx');
    var buf = await res.arrayBuffer();
    await docx.renderAsync(buf, document.getElementById('host'), null, {
      className:'docx', inWrapper:true, ignoreWidth:false, ignoreHeight:false,
      breakPages:true, renderHeaders:true, renderFooters:true, useBase64URL:true
    });
    await new Promise(function(r){
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){ setTimeout(r, @WAIT@); });
      });
    });
    window.scrollTo(0, 0);
    @MEASURE@
    ESW.@CALLBACK@();
  }catch(e){
    ESW.onError(String((e && e.stack) || e));
  }
})();
</script></body></html>
""".trimIndent()

    private val MEASURE_JS = """
    var host = document.getElementById('host');
    var hostTop = host.getBoundingClientRect().top;
    var els = document.querySelectorAll(
      '.docx p, .docx h1, .docx h2, .docx h3, .docx h4, .docx li, .docx table tr'
    );
    var cuts = [];
    var lastBottom = 0;
    for (var i = 0; i < els.length; i++) {
      var rect = els[i].getBoundingClientRect();
      var top = Math.round(rect.top - hostTop);
      var bottom = Math.round(rect.bottom - hostTop);
      if (top > 0) cuts.push(top);
      if (bottom > lastBottom) lastBottom = bottom;
    }
    window.__eswCuts = cuts;
    window.__eswHeight = Math.round(Math.max(
      host.scrollHeight,
      document.body.scrollHeight,
      document.documentElement.scrollHeight,
      lastBottom
    ));
""".trimIndent()
}
