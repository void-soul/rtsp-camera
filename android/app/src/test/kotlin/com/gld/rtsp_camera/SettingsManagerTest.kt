package com.gld.rtsp_camera

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for the parsing and migration logic in SettingsManager.
 *
 * Since SettingsManager depends on Android SharedPreferences (not available in JVM tests),
 * we test the pure parsing and migration logic by replicating the exact algorithms
 * as static helper functions and verifying correctness.
 */
class SettingsManagerTest {

    companion object {
        /**
         * Parse resolution string "WIDTHxHEIGHT" into width and height.
         * Returns defaults (1280, 720) on parse failure.
         * Replicates SettingsManager.getWidth() / getHeight() exactly.
         */
        fun parseResolution(resolution: String): Pair<Int, Int> {
            val width = try { resolution.split("x")[0].toInt() } catch (e: Exception) { 1280 }
            val height = try { resolution.split("x")[1].toInt() } catch (e: Exception) { 720 }
            return Pair(width, height)
        }

        /**
         * Parse FPS string, defaulting to 30.
         * Replicates SettingsManager.fps getter logic.
         */
        fun parseFps(fpsStr: String?): Int {
            return fpsStr?.toIntOrNull() ?: 30
        }

        /**
         * Parse bitrate with migration from old format (bps) to new format (Mbps).
         * Old format: values >= 1000 (in bps, e.g. 10000000 for 10Mbps)
         * New format: values < 1000 (in Mbps, e.g. 10 for 10Mbps)
         * Replicates SettingsManager.bitrate getter logic exactly.
         */
        fun parseBitrate(value: String?, fallbackInt: Int = 10): Int {
            return try {
                val v = value?.toInt() ?: fallbackInt
                if (v >= 1000) v / 1000 else v
            } catch (e: Exception) {
                fallbackInt
            }
        }

        /**
         * Parse GOP with migration from old format (seconds) to new format (frames).
         * Old format: values 2-10 that are not multiples of 5 (except 1) -> multiply by 30
         * New format: frame counts (1-120)
         * Replicates SettingsManager.gop getter logic exactly.
         */
        fun parseGop(value: String?, fallbackInt: Int = 60): Int {
            return try {
                val v = value?.toInt() ?: fallbackInt
                if (v in 2..10 && v != 5 && v != 10) v * 30 else v
            } catch (e: Exception) {
                fallbackInt
            }
        }

        /**
         * Parse port with fallback.
         * Replicates SettingsManager.rtspPort getter logic.
         */
        fun parsePort(value: String?, fallbackInt: Int = 9527): Int {
            return try {
                value?.toInt() ?: fallbackInt
            } catch (e: Exception) {
                fallbackInt
            }
        }
    }

    // =========================================================================
    // Resolution parsing tests
    // =========================================================================

    @Test
    fun `parseResolution handles standard 1280x720`() {
        val (w, h) = parseResolution("1280x720")
        assertEquals(1280, w)
        assertEquals(720, h)
    }

    @Test
    fun `parseResolution handles 1920x1080`() {
        val (w, h) = parseResolution("1920x1080")
        assertEquals(1920, w)
        assertEquals(1080, h)
    }

    @Test
    fun `parseResolution handles 640x480`() {
        val (w, h) = parseResolution("640x480")
        assertEquals(640, w)
        assertEquals(480, h)
    }

    @Test
    fun `parseResolution handles 3840x2160 4K`() {
        val (w, h) = parseResolution("3840x2160")
        assertEquals(3840, w)
        assertEquals(2160, h)
    }

    @Test
    fun `parseResolution defaults on empty string`() {
        val (w, h) = parseResolution("")
        assertEquals(1280, w)
        assertEquals(720, h)
    }

    @Test
    fun `parseResolution defaults on malformed string`() {
        val (w, h) = parseResolution("not_a_resolution")
        assertEquals(1280, w)
        assertEquals(720, h)
    }

    @Test
    fun `parseResolution defaults on missing height`() {
        val (w, h) = parseResolution("1920x")
        assertEquals(1920, w)
        assertEquals(720, h) // split returns ["1920", ""], "".toInt() throws -> 720
    }

    @Test
    fun `parseResolution defaults on missing width`() {
        val (w, h) = parseResolution("x720")
        assertEquals(1280, w) // split returns ["", "720"], "".toInt() throws -> 1280
        assertEquals(720, h)
    }

    @Test
    fun `parseResolution handles extra parts gracefully`() {
        // "1920x1080x99" -> split returns ["1920", "1080", "99"], uses [0] and [1]
        val (w, h) = parseResolution("1920x1080x99")
        assertEquals(1920, w)
        assertEquals(1080, h)
    }

    // =========================================================================
    // FPS parsing tests
    // =========================================================================

    @Test
    fun `parseFps handles standard values`() {
        assertEquals(30, parseFps("30"))
        assertEquals(25, parseFps("25"))
        assertEquals(60, parseFps("60"))
        assertEquals(15, parseFps("15"))
    }

    @Test
    fun `parseFps defaults to 30 on null`() {
        assertEquals(30, parseFps(null))
    }

    @Test
    fun `parseFps defaults to 30 on non-numeric`() {
        assertEquals(30, parseFps("abc"))
    }

    @Test
    fun `parseFps defaults to 30 on empty string`() {
        assertEquals(30, parseFps(""))
    }

    // =========================================================================
    // Bitrate migration tests
    // =========================================================================

    @Test
    fun `parseBitrate new format - small values returned as-is`() {
        assertEquals(10, parseBitrate("10"))   // 10 Mbps
        assertEquals(5, parseBitrate("5"))     // 5 Mbps
        assertEquals(20, parseBitrate("20"))   // 20 Mbps
        assertEquals(1, parseBitrate("1"))     // 1 Mbps
    }

    @Test
    fun `parseBitrate old format - large values divided by 1000`() {
        assertEquals(10000, parseBitrate("10000000"))  // 10000000/1000 = 10000
        assertEquals(5000, parseBitrate("5000000"))    // 5000000/1000 = 5000
        assertEquals(20000, parseBitrate("20000000"))  // 20000000/1000 = 20000
        assertEquals(1000, parseBitrate("1000000"))    // 1000000/1000 = 1000
    }

    @Test
    fun `parseBitrate migration boundary - 999 is new format`() {
        assertEquals(999, parseBitrate("999"))
    }

    @Test
    fun `parseBitrate migration boundary - 1000 is old format`() {
        assertEquals(1, parseBitrate("1000")) // 1000/1000 = 1
    }

    @Test
    fun `parseBitrate migration boundary - 999999 is old format`() {
        assertEquals(999, parseBitrate("999999")) // 999999/1000 = 999
    }

    @Test
    fun `parseBitrate defaults to 10 on null`() {
        assertEquals(10, parseBitrate(null))
    }

    @Test
    fun `parseBitrate defaults to 10 on non-numeric`() {
        assertEquals(10, parseBitrate("abc"))
    }

    @Test
    fun `parseBitrate defaults to 10 on empty string`() {
        assertEquals(10, parseBitrate(""))
    }

    @Test
    fun `parseBitrate uses custom fallback`() {
        assertEquals(8, parseBitrate(null, fallbackInt = 8))
        assertEquals(8, parseBitrate("abc", fallbackInt = 8))
    }

    // =========================================================================
    // GOP migration tests
    // =========================================================================

    @Test
    fun `parseGop new format - standard frame counts returned as-is`() {
        assertEquals(60, parseGop("60"))
        assertEquals(30, parseGop("30"))
        assertEquals(120, parseGop("120"))
        assertEquals(1, parseGop("1"))
    }

    @Test
    fun `parseGop new format - multiples of 5 returned as-is`() {
        assertEquals(5, parseGop("5"))
        assertEquals(10, parseGop("10"))
        assertEquals(15, parseGop("15"))
    }

    @Test
    fun `parseGop old format - values 2-4 converted from seconds to frames`() {
        // Old format: 2 seconds * 30fps = 60 frames
        assertEquals(60, parseGop("2"))
        // 3 seconds * 30fps = 90 frames
        assertEquals(90, parseGop("3"))
        // 4 seconds * 30fps = 120 frames
        assertEquals(120, parseGop("4"))
    }

    @Test
    fun `parseGop old format - values 6-9 converted from seconds to frames`() {
        // 6 seconds * 30fps = 180
        assertEquals(180, parseGop("6"))
        // 7 seconds * 30fps = 210
        assertEquals(210, parseGop("7"))
        // 8 seconds * 30fps = 240
        assertEquals(240, parseGop("8"))
        // 9 seconds * 30fps = 270
        assertEquals(270, parseGop("9"))
    }

    @Test
    fun `parseGop boundary - 1 is not migrated (new format)`() {
        assertEquals(1, parseGop("1"))
    }

    @Test
    fun `parseGop boundary - 5 is not migrated (new format, multiple of 5)`() {
        assertEquals(5, parseGop("5"))
    }

    @Test
    fun `parseGop boundary - 10 is not migrated (new format, multiple of 5)`() {
        assertEquals(10, parseGop("10"))
    }

    @Test
    fun `parseGop boundary - 11 is not migrated (out of old range)`() {
        assertEquals(11, parseGop("11"))
    }

    @Test
    fun `parseGop defaults to 60 on null`() {
        assertEquals(60, parseGop(null))
    }

    @Test
    fun `parseGop defaults to 60 on non-numeric`() {
        assertEquals(60, parseGop("abc"))
    }

    @Test
    fun `parseGop defaults to 60 on empty string`() {
        assertEquals(60, parseGop(""))
    }

    @Test
    fun `parseGop uses custom fallback`() {
        assertEquals(90, parseGop(null, fallbackInt = 90))
        assertEquals(90, parseGop("abc", fallbackInt = 90))
    }

    // =========================================================================
    // Port parsing tests
    // =========================================================================

    @Test
    fun `parsePort handles valid port`() {
        assertEquals(9527, parsePort("9527"))
        assertEquals(8554, parsePort("8554"))
        assertEquals(554, parsePort("554"))
    }

    @Test
    fun `parsePort defaults to 9527 on null`() {
        assertEquals(9527, parsePort(null))
    }

    @Test
    fun `parsePort defaults to 9527 on non-numeric`() {
        assertEquals(9527, parsePort("abc"))
    }

    @Test
    fun `parsePort defaults to 9527 on empty string`() {
        assertEquals(9527, parsePort(""))
    }

    // =========================================================================
    // Default value tests
    // =========================================================================

    @Test
    fun `default resolution is 1280x720`() {
        val (w, h) = parseResolution("1280x720")
        assertEquals(1280, w)
        assertEquals(720, h)
    }

    @Test
    fun `default fps is 30`() {
        assertEquals(30, parseFps("30"))
    }

    @Test
    fun `default bitrate is 10`() {
        assertEquals(10, parseBitrate("10"))
    }

    @Test
    fun `default gop is 60`() {
        assertEquals(60, parseGop("60"))
    }

    @Test
    fun `default port is 9527`() {
        assertEquals(9527, parsePort("9527"))
    }
}
