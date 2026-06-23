package com.dudutv.remote

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.util.AttributeSet
import android.util.Log
import android.view.View
import android.widget.FrameLayout

class GlassCardView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    var cornerRadius = 20f
    var borderWidth = 2f
    var borderColor = 0x80B0C8E0.toInt()

    private var blurredBg: Bitmap? = null
    private var blurFailed = false
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = borderWidth
        color = borderColor
    }
    private val clipPath = Path()
    private var pending = true
    private var lastWidth = 0
    private var lastHeight = 0

    init {
        setWillNotDraw(false)
        clipToOutline = false
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        pending = true
        post { refreshBlur() }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        val w = r - l; val h = b - t
        if (w != lastWidth || h != lastHeight) {
            lastWidth = w; lastHeight = h
            clipPath.reset()
            clipPath.addRoundRect(
                RectF(0f, 0f, w.toFloat(), h.toFloat()),
                cornerRadius, cornerRadius, Path.Direction.CW
            )
            pending = true
        }
    }

    fun refreshBlur() {
        if (width <= 0 || height <= 0) { pending = true; return }
        blurredBg?.recycle()
        blurredBg = null

        try {
            val root = rootView
            val myLoc = IntArray(2)
            val rootLoc = IntArray(2)
            getLocationOnScreen(myLoc)
            root.getLocationOnScreen(rootLoc)

            val ox = (myLoc[0] - rootLoc[0]).coerceIn(0, root.width - 1)
            val oy = (myLoc[1] - rootLoc[1]).coerceIn(0, root.height - 1)
            val cw = width.coerceAtMost(root.width - ox)
            val ch = height.coerceAtMost(root.height - oy)
            if (cw <= 0 || ch <= 0) return

            // Capture at full resolution
            val full = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
            root.draw(Canvas(full))
            val crop = Bitmap.createBitmap(full, ox, oy, cw, ch)
            full.recycle()

            // Scale to 50% for performance, blur at that resolution
            val scale = 0.5f
            val sw = (cw * scale).toInt().coerceAtLeast(1)
            val sh = (ch * scale).toInt().coerceAtLeast(1)
            val medium = Bitmap.createScaledBitmap(crop, sw, sh, true)
            crop.recycle()

            // Stronger blur on medium-res image (radius 8 on 0.5x = 16px effective)
            val blurred = stackBlur(medium, 8)
            medium.recycle()

            blurredBg = Bitmap.createScaledBitmap(blurred, cw, ch, true)
            blurred.recycle()

            pending = false
        } catch (e: Exception) {
            Log.w("GlassCardView", "blur failed: ${e.message}")
            blurFailed = true
            pending = false
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (pending && width > 0 && height > 0) refreshBlur()
        canvas.save()
        canvas.clipPath(clipPath)
        if (blurredBg != null) {
            canvas.drawBitmap(blurredBg!!, 0f, 0f, bitmapPaint)
            canvas.drawColor(0x30FFFFFF.toInt())
        } else {
            canvas.drawColor(0xE0FFFFFF.toInt())
        }
        canvas.restore()
        canvas.drawPath(clipPath, borderPaint)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        blurredBg?.recycle()
        blurredBg = null
    }

    private fun stackBlur(src: Bitmap, radius: Int): Bitmap {
        val w = src.width
        val h = src.height
        if (w == 0 || h == 0) return src
        val n = w * h
        val srcPix = IntArray(n)
        val tmpPix = IntArray(n)
        src.getPixels(srcPix, 0, w, 0, 0, w, h)

        // Horizontal
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) {
                var a = 0; var r = 0; var g = 0; var b = 0; var cnt = 0
                for (dx in -radius..radius) {
                    val sx = (x + dx).coerceIn(0, w - 1)
                    val p = srcPix[row + sx]
                    a += (p shr 24) and 0xFF
                    r += (p shr 16) and 0xFF
                    g += (p shr 8) and 0xFF
                    b += p and 0xFF
                    cnt++
                }
                tmpPix[row + x] = ((a / cnt) shl 24) or ((r / cnt) shl 16) or ((g / cnt) shl 8) or (b / cnt)
            }
        }
        // Vertical
        val out = IntArray(n)
        for (x in 0 until w) {
            for (y in 0 until h) {
                var a = 0; var r = 0; var g = 0; var b = 0; var cnt = 0
                for (dy in -radius..radius) {
                    val sy = (y + dy).coerceIn(0, h - 1)
                    val p = tmpPix[sy * w + x]
                    a += (p shr 24) and 0xFF
                    r += (p shr 16) and 0xFF
                    g += (p shr 8) and 0xFF
                    b += p and 0xFF
                    cnt++
                }
                out[y * w + x] = ((a / cnt) shl 24) or ((r / cnt) shl 16) or ((g / cnt) shl 8) or (b / cnt)
            }
        }
        return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
    }
}
