package com.gld.rtsp_camera

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

/**
 * Tests for pure logic in H264Encoder that does not depend on MediaCodec.
 * - NV12 to I420 color format conversion (putI420)
 * - I-Frame interval calculation
 */
class H264EncoderTest {

    companion object {
        /**
         * NV12 to I420 conversion. Replicates H264Encoder.putI420() exactly.
         * NV12: Y plane + interleaved UV plane
         * I420: Y plane + U plane + V plane (separate)
         */
        fun putI420(nv12: ByteArray, buf: ByteBuffer, w: Int, h: Int) {
            val ySize = w * h
            val uvSize = ySize / 4
            // Y plane
            buf.put(nv12, 0, ySize)
            // U plane - extract even-indexed bytes from UV interleaved plane
            for (i in 0 until uvSize) {
                buf.put(nv12[ySize + i * 2])
            }
            // V plane - extract odd-indexed bytes from UV interleaved plane
            for (i in 0 until uvSize) {
                buf.put(nv12[ySize + i * 2 + 1])
            }
        }

        /**
         * I-Frame interval calculation. Replicates H264Encoder logic.
         * iInterval = if (gop > 0) (gop.toFloat() / framerate).coerceAtLeast(1f).toInt() else 1
         */
        fun computeIInterval(gop: Int, framerate: Int): Int {
            return if (gop > 0) (gop.toFloat() / framerate).coerceAtLeast(1f).toInt() else 1
        }
    }

    // =========================================================================
    // NV12 to I420 conversion tests
    // =========================================================================

    @Test
    fun `putI420 copies Y plane unchanged`() {
        val w = 4; val h = 4
        val ySize = w * h // 16
        val uvSize = ySize / 4 // 4
        val totalSize = ySize + uvSize * 2 // 24 (NV12 size)

        // Create NV12 data with distinct Y and UV values
        val nv12 = ByteArray(totalSize)
        // Y plane: 0x10..0x1F
        for (i in 0 until ySize) nv12[i] = (0x10 + i).toByte()
        // UV plane: interleaved U=0xA0..0xA3, V=0xB0..0xB3
        for (i in 0 until uvSize) {
            nv12[ySize + i * 2] = (0xA0 + i).toByte()     // U
            nv12[ySize + i * 2 + 1] = (0xB0 + i).toByte() // V
        }

        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)
        output.flip()

        // Y plane should be identical
        for (i in 0 until ySize) {
            assertEquals("Y[$i]", (0x10 + i).toByte(), output.get(i))
        }
    }

    @Test
    fun `putI420 separates UV planes correctly`() {
        val w = 4; val h = 4
        val ySize = w * h // 16
        val uvSize = ySize / 4 // 4
        val totalSize = ySize + uvSize * 2

        val nv12 = ByteArray(totalSize)
        // Y plane: fill with 0
        for (i in 0 until ySize) nv12[i] = 0
        // UV plane: U values at even indices, V values at odd indices
        for (i in 0 until uvSize) {
            nv12[ySize + i * 2] = (0xA0 + i).toByte()     // U
            nv12[ySize + i * 2 + 1] = (0xB0 + i).toByte() // V
        }

        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)
        output.flip()

        // After Y plane (16 bytes), U plane should have U values
        for (i in 0 until uvSize) {
            assertEquals("U[$i]", (0xA0 + i).toByte(), output.get(ySize + i))
        }
        // After U plane, V plane should have V values
        for (i in 0 until uvSize) {
            assertEquals("V[$i]", (0xB0 + i).toByte(), output.get(ySize + uvSize + i))
        }
    }

    @Test
    fun `putI420 output size equals input size`() {
        val w = 4; val h = 4
        val ySize = w * h
        val uvSize = ySize / 4
        val totalSize = ySize + uvSize * 2

        val nv12 = ByteArray(totalSize)
        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)

        assertEquals(totalSize, output.position())
    }

    @Test
    fun `putI420 works for 2x2 image (minimum chroma block)`() {
        val w = 2; val h = 2
        val ySize = 4
        val uvSize = 1
        val totalSize = 6

        val nv12 = byteArrayOf(
            // Y plane (4 bytes)
            0x10, 0x11, 0x12, 0x13,
            // UV plane (2 bytes: 1 U + 1 V)
            0xA0.toByte(), 0xB0.toByte()
        )

        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)
        output.flip()

        // Y: 0x10, 0x11, 0x12, 0x13
        assertEquals(0x10.toByte(), output.get(0))
        assertEquals(0x11.toByte(), output.get(1))
        assertEquals(0x12.toByte(), output.get(2))
        assertEquals(0x13.toByte(), output.get(3))
        // U: 0xA0
        assertEquals(0xA0.toByte(), output.get(4))
        // V: 0xB0
        assertEquals(0xB0.toByte(), output.get(5))
    }

    @Test
    fun `putI420 works for 8x8 image`() {
        val w = 8; val h = 8
        val ySize = 64
        val uvSize = 16
        val totalSize = ySize + uvSize * 2 // 96

        val nv12 = ByteArray(totalSize)
        // Fill Y with sequential values
        for (i in 0 until ySize) nv12[i] = (i and 0xFF).toByte()
        // Fill UV with pattern
        for (i in 0 until uvSize) {
            nv12[ySize + i * 2] = (0x80 + i).toByte()
            nv12[ySize + i * 2 + 1] = (0xC0 + i).toByte()
        }

        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)
        output.flip()

        // Verify U plane separation
        for (i in 0 until uvSize) {
            assertEquals("U[$i]", (0x80 + i).toByte(), output.get(ySize + i))
        }
        // Verify V plane separation
        for (i in 0 until uvSize) {
            assertEquals("V[$i]", (0xC0 + i).toByte(), output.get(ySize + uvSize + i))
        }
    }

    @Test
    fun `putI420 UV interleaving correctly splits even and odd bytes`() {
        // Specific test for the UV de-interleaving
        val w = 4; val h = 2
        val ySize = 8
        val uvSize = 2 // (4/2) * (2/2) = 2
        val totalSize = ySize + uvSize * 2 // 12

        val nv12 = ByteArray(totalSize)
        // Y plane
        for (i in 0 until ySize) nv12[i] = 0
        // UV: U0=0x55, V0=0xAA, U1=0x66, V1=0xBB
        nv12[8] = 0x55.toByte()  // U0
        nv12[9] = 0xAA.toByte()  // V0
        nv12[10] = 0x66.toByte() // U1
        nv12[11] = 0xBB.toByte() // V1

        val output = ByteBuffer.allocate(totalSize)
        putI420(nv12, output, w, h)
        output.flip()

        // U plane: [0x55, 0x66]
        assertEquals(0x55.toByte(), output.get(ySize))
        assertEquals(0x66.toByte(), output.get(ySize + 1))
        // V plane: [0xAA, 0xBB]
        assertEquals(0xAA.toByte(), output.get(ySize + uvSize))
        assertEquals(0xBB.toByte(), output.get(ySize + uvSize + 1))
    }

    // =========================================================================
    // I-Frame interval calculation tests
    // =========================================================================

    @Test
    fun `I-Interval for 30fps gop60 is 2 seconds`() {
        // gop=60, fps=30 -> 60/30 = 2.0 -> 2
        assertEquals(2, computeIInterval(60, 30))
    }

    @Test
    fun `I-Interval for 30fps gop30 is 1 second`() {
        assertEquals(1, computeIInterval(30, 30))
    }

    @Test
    fun `I-Interval for 30fps gop120 is 4 seconds`() {
        assertEquals(4, computeIInterval(120, 30))
    }

    @Test
    fun `I-Interval for 25fps gop50 is 2 seconds`() {
        // 50/25 = 2.0
        assertEquals(2, computeIInterval(50, 25))
    }

    @Test
    fun `I-Interval for 60fps gop60 is 1 second`() {
        // 60/60 = 1.0
        assertEquals(1, computeIInterval(60, 60))
    }

    @Test
    fun `I-Interval for gop less than framerate is at least 1`() {
        // gop=1, fps=30 -> 1/30 = 0.033 -> coerceAtLeast(1) -> 1
        assertEquals(1, computeIInterval(1, 30))
        // gop=15, fps=30 -> 15/30 = 0.5 -> coerceAtLeast(1) -> 1
        assertEquals(1, computeIInterval(15, 30))
    }

    @Test
    fun `I-Interval for gop 0 defaults to 1`() {
        // gop=0 -> special case -> 1
        assertEquals(1, computeIInterval(0, 30))
    }

    @Test
    fun `I-Interval for gop negative defaults to 1`() {
        assertEquals(1, computeIInterval(-1, 30))
    }

    @Test
    fun `I-Interval floors fractional values`() {
        // gop=7, fps=3 -> 7/3 = 2.33 -> 2
        assertEquals(2, computeIInterval(7, 3))
        // gop=10, fps=3 -> 10/3 = 3.33 -> 3
        assertEquals(3, computeIInterval(10, 3))
    }

    @Test
    fun `I-Interval for common streaming configs`() {
        // 30fps, gop=2*30=60 -> 2s
        assertEquals(2, computeIInterval(60, 30))
        // 30fps, gop=3*30=90 -> 3s
        assertEquals(3, computeIInterval(90, 30))
        // 25fps, gop=2*25=50 -> 2s
        assertEquals(2, computeIInterval(50, 25))
        // 60fps, gop=2*60=120 -> 2s
        assertEquals(2, computeIInterval(120, 60))
    }
}
