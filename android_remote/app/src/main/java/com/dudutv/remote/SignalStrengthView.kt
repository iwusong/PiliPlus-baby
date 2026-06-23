package com.dudutv.remote

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import kotlin.math.min

class SignalStrengthView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    var rssi: Int = -100
        set(value) {
            field = value
            invalidate()
        }

    private val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFF00B37E.toInt()
    }
    private val inactivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFFD0D8E0.toInt()
    }

    private val barCount = 4
    private val barGap = 3f
    private val barWidth = 4f
    private val cornerRadius = 1.5f

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val level = signalLevel(rssi)
        val h = height.toFloat()
        val maxH = h * 0.85f
        val startX = (width - barCount * barWidth - (barCount - 1) * barGap) / 2f

        for (i in 0 until barCount) {
            val barH = maxH * (i + 1) / barCount
            val x = startX + i * (barWidth + barGap)
            val top = h - barH
            val paint = if (i < level) activePaint else inactivePaint
            canvas.drawRoundRect(x, top, x + barWidth, h, cornerRadius, cornerRadius, paint)
        }
    }

    private fun signalLevel(rssi: Int): Int = when {
        rssi >= -55 -> 4
        rssi >= -70 -> 3
        rssi >= -85 -> 2
        rssi >= -100 -> 1
        else -> 0
    }
}
