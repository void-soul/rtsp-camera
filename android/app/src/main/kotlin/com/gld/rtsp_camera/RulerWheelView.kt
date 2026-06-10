package com.gld.rtsp_camera

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.widget.Scroller
import kotlin.math.abs
import kotlin.math.roundToInt

class RulerWheelView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = 2f
    }
    
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 30f
        textAlign = Paint.Align.CENTER
    }
    
    private var data: List<String> = emptyList()
    private var selectedIndex = -1
    
    // 调小 itemWidth 使其更密集
    private val itemWidth = 50 
    private val lineColor = Color.parseColor("#80FFFFFF")
    private val selectedColor = Color.parseColor("#FFD700")
    
    private val scroller = Scroller(context)
    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            scrollBy(distanceX.toInt(), 0)
            checkSelection(true)
            return true
        }

        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
            scroller.fling(scrollX, 0, (-velocityX).toInt(), 0, -Int.MAX_VALUE, Int.MAX_VALUE, 0, 0)
            invalidate()
            return true
        }
    })

    private fun checkSelection(triggerVibrate: Boolean) {
        if (data.isEmpty() || width == 0) return
        
        val centerX = width / 2
        val virtualX = scrollX + centerX
        val newIndex = (virtualX.toFloat() / itemWidth).roundToInt().coerceIn(0, data.size - 1)
        
        if (newIndex != selectedIndex) {
            selectedIndex = newIndex
            if (triggerVibrate) {
                // 触发物理震动反馈
                performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            }
            onItemSelectedListener?.invoke(selectedIndex, data[selectedIndex])
            invalidate()
        }
    }

    var onItemSelectedListener: ((index: Int, value: String) -> Unit)? = null

    fun setData(newData: List<String>, initialIndex: Int = 0) {
        this.data = newData
        this.selectedIndex = initialIndex
        // 如果 View 已经布局完成，直接跳转
        if (width > 0) {
            scrollToIndex(initialIndex)
        }
    }

    private fun scrollToIndex(index: Int) {
        val centerX = width / 2
        val targetX = index * itemWidth - centerX
        scrollTo(targetX, 0)
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (data.isNotEmpty() && selectedIndex >= 0) {
            scrollToIndex(selectedIndex)
        }
    }

    override fun onDraw(canvas: Canvas) {
        if (data.isEmpty()) return

        val centerX = width / 2
        val currentScrollX = scrollX
        val centerInView = currentScrollX + centerX

        // 只绘制可见区域的刻度
        val startItem = ((centerInView - centerX) / itemWidth).coerceAtLeast(0)
        val endItem = ((centerInView + centerX) / itemWidth).coerceAtMost(data.size - 1)

        for (i in startItem..endItem) {
            val x = i * itemWidth
            val distanceToCenter = abs(x - centerInView)
            val alpha = calculateAlpha(distanceToCenter.toFloat())
            
            if (i % 5 == 0) { // 大刻度
                linePaint.strokeWidth = 4f
                linePaint.color = if (i == selectedIndex) selectedColor else Color.WHITE
                linePaint.alpha = (alpha * 255).toInt()
                
                canvas.drawLine(x.toFloat(), height * 0.6f, x.toFloat(), height * 0.9f, linePaint)
                
                textPaint.color = if (i == selectedIndex) selectedColor else Color.WHITE
                textPaint.alpha = (alpha * 255).toInt()
                canvas.drawText(data[i], x.toFloat(), height * 0.45f, textPaint)
            } else { // 小刻度
                linePaint.strokeWidth = 2f
                linePaint.color = Color.WHITE
                linePaint.alpha = (alpha * 150).toInt()
                canvas.drawLine(x.toFloat(), height * 0.75f, x.toFloat(), height * 0.9f, linePaint)
            }
        }

        // 中心固定红色指示针
        linePaint.color = selectedColor
        linePaint.alpha = 255
        linePaint.strokeWidth = 4f
        canvas.drawLine(centerInView.toFloat(), height * 0.5f, centerInView.toFloat(), height.toFloat(), linePaint)
    }

    private fun calculateAlpha(distance: Float): Float {
        val maxDist = width / 1.5f
        if (distance >= maxDist) return 0f
        return 1.0f - (distance / maxDist)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val result = gestureDetector.onTouchEvent(event)
        if (event.action == MotionEvent.ACTION_UP || event.action == MotionEvent.ACTION_CANCEL) {
            snapToNearest()
        }
        return result
    }

    private fun snapToNearest() {
        if (data.isEmpty()) return
        val centerX = width / 2
        val targetScrollX = selectedIndex * itemWidth - centerX
        val dx = targetScrollX - scrollX
        scroller.startScroll(scrollX, 0, dx, 0, 300)
        invalidate()
    }

    override fun computeScroll() {
        if (scroller.computeScrollOffset()) {
            scrollTo(scroller.currX, 0)
            checkSelection(false) // 惯性滑动不触发高频震动，只在停下时震动由 snap 处理
            invalidate()
        }
    }
}
