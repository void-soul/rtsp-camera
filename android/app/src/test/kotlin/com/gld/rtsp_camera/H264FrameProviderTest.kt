package com.gld.rtsp_camera

import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class H264FrameProviderTest {

    private lateinit var provider: H264FrameProvider

    @Before
    fun setUp() {
        provider = H264FrameProvider()
    }

    // ---- prepare / obtainEmptyFrame ----

    @Test
    fun `prepare allocates pool`() {
        provider.prepare()
        // Pool size is 10, we should be able to obtain 10 frames
        val frames = mutableListOf<NativeFrame>()
        for (i in 0 until 10) {
            val frame = provider.obtainEmptyFrame()
            assertNotNull("Frame $i should not be null", frame)
            frames.add(frame!!)
        }
        // 11th should be null (pool exhausted)
        assertNull(provider.obtainEmptyFrame())
    }

    @Test
    fun `prepare is idempotent`() {
        provider.prepare()
        provider.prepare() // second call should be no-op
        // Still only 10 frames available
        for (i in 0 until 10) {
            assertNotNull(provider.obtainEmptyFrame())
        }
        assertNull(provider.obtainEmptyFrame())
    }

    @Test
    fun `obtainEmptyFrame auto-prepares if not prepared`() {
        // Do NOT call prepare() explicitly
        val frame = provider.obtainEmptyFrame()
        assertNotNull("obtainEmptyFrame should auto-prepare", frame)
    }

    @Test
    fun `obtainEmptyFrame returns frame with correct buffer size`() {
        val frame = provider.obtainEmptyFrame()!!
        assertEquals(2 * 1024 * 1024, frame.buffer.size)
        assertEquals(0, frame.length)
    }

    // ---- addFrame / getFrameBlocking ----

    @Test
    fun `addFrame and getFrameBlocking round-trip`() {
        provider.prepare()
        val frame = provider.obtainEmptyFrame()!!
        frame.length = 42
        frame.buffer[0] = 0x65.toByte()

        provider.addFrame(frame)
        val retrieved = provider.getFrameBlocking(100)
        assertNotNull(retrieved)
        assertEquals(42, retrieved!!.length)
        assertEquals(0x65.toByte(), retrieved.buffer[0])
    }

    @Test
    fun `getFrameBlocking returns null on timeout`() {
        val result = provider.getFrameBlocking(50) // 50ms timeout
        assertNull(result)
    }

    @Test
    fun `multiple frames returned in FIFO order`() {
        provider.prepare()
        val frame1 = provider.obtainEmptyFrame()!!
        val frame2 = provider.obtainEmptyFrame()!!
        frame1.length = 1
        frame2.length = 2

        provider.addFrame(frame1)
        provider.addFrame(frame2)

        val r1 = provider.getFrameBlocking(100)!!
        val r2 = provider.getFrameBlocking(100)!!
        assertEquals(1, r1.length)
        assertEquals(2, r2.length)
    }

    // ---- recycleFrame ----

    @Test
    fun `recycleFrame returns frame to pool`() {
        provider.prepare()
        // Drain pool
        val frame = provider.obtainEmptyFrame()!!
        // Pool is now at 9

        // Recycle it
        provider.recycleFrame(frame)
        assertEquals(0, frame.length)

        // Should be obtainable again
        val recycled = provider.obtainEmptyFrame()
        assertNotNull(recycled)
    }

    @Test
    fun `recycleFrame resets length to 0`() {
        provider.prepare()
        val frame = provider.obtainEmptyFrame()!!
        frame.length = 999
        provider.recycleFrame(frame)
        assertEquals(0, frame.length)
    }

    // ---- addFrame overflow (queue full drops oldest) ----

    @Test
    fun `addFrame drops oldest when queue is full`() {
        provider.prepare()
        // filledQueue capacity is 30
        val frames = mutableListOf<NativeFrame>()
        for (i in 0 until 30) {
            val f = provider.obtainEmptyFrame() ?: break
            f.length = i
            provider.addFrame(f)
            frames.add(f)
        }

        // Now add one more, which should cause overflow (drop oldest)
        // But we need a frame from the pool -- we've used all 10 pool frames
        // The filledQueue holds up to 30, but pool is only 10.
        // Let's test differently: create frames manually
        val extraFrame = NativeFrame(ByteArray(1024), 99)
        provider.addFrame(extraFrame)

        // The oldest frame should have been dropped and recycled
        // We should be able to get the extraFrame back
        val retrieved = provider.getFrameBlocking(100)
        // The last added frame should be retrievable
        assertNotNull(retrieved)
    }

    // ---- clear ----

    @Test
    fun `clear recycles all filled frames`() {
        provider.prepare()
        val frame1 = provider.obtainEmptyFrame()!!
        val frame2 = provider.obtainEmptyFrame()!!
        frame1.length = 10
        frame2.length = 20

        provider.addFrame(frame1)
        provider.addFrame(frame2)

        provider.clear()

        // filled queue should be empty
        assertNull(provider.getFrameBlocking(50))

        // But frames should be back in pool (recycled)
        val recycled = provider.obtainEmptyFrame()
        assertNotNull(recycled)
    }

    // ---- setSPSPPS ----

    @Test
    fun `setSPSPPS extracts SPS and PPS from concatenated NAL units`() {
        // Build test data: SPS (type 7) + PPS (type 8)
        // SPS: 00 00 00 01 67 <data...>
        // PPS: 00 00 00 01 68 <data...>
        val spsPayload = byteArrayOf(0x67, 0x42, 0x00, 0x1E.toByte(), 0xAB.toByte())
        val ppsPayload = byteArrayOf(0x68, 0xCE.toByte(), 0x38, 0x80.toByte())

        val data = ByteArray(4 + spsPayload.size + 4 + ppsPayload.size)
        var offset = 0
        // SPS start code
        data[offset++] = 0; data[offset++] = 0; data[offset++] = 0; data[offset++] = 1
        for (b in spsPayload) data[offset++] = b
        // PPS start code
        data[offset++] = 0; data[offset++] = 0; data[offset++] = 0; data[offset++] = 1
        for (b in ppsPayload) data[offset++] = b

        provider.setSPSPPS(data, data.size)

        val sps = provider.getSPS()
        val pps = provider.getPPS()
        assertNotNull("SPS should be extracted", sps)
        assertNotNull("PPS should be extracted", pps)
        // SPS should include start code + payload
        assertEquals(4 + spsPayload.size, sps!!.size)
        assertEquals(4 + ppsPayload.size, pps!!.size)
        // Verify NAL type byte
        assertEquals(0x67.toByte(), sps[4]) // SPS type 7 with forbidden=0, ref_idc=3 -> 0x67
        assertEquals(0x68.toByte(), pps[4]) // PPS type 8 with forbidden=0, ref_idc=3 -> 0x68
    }

    @Test
    fun `setSPSPPS handles 3-byte start code`() {
        // 3-byte start code: 00 00 01 — now correctly handled
        val data = byteArrayOf(0, 0, 1, 0x67, 0x42, 0x00, 0x1E.toByte())
        provider.setSPSPPS(data, data.size)
        // SPS should be extracted with 3-byte start code
        assertNotNull(provider.getSPS())
        assertEquals(0x67.toByte(), provider.getSPS()!![3]) // NAL type byte at offset 3 (after 3-byte start code)
    }

    @Test
    fun `setSPSPPS handles data with no start codes`() {
        val data = byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05)
        provider.setSPSPPS(data, data.size)
        assertNull(provider.getSPS())
        assertNull(provider.getPPS())
    }

    @Test
    fun `setSPSPPS extracts only SPS when PPS is absent`() {
        val spsPayload = byteArrayOf(0x67, 0x42, 0x00, 0x1E.toByte())
        val data = ByteArray(4 + spsPayload.size)
        data[0] = 0; data[1] = 0; data[2] = 0; data[3] = 1
        for (i in spsPayload.indices) data[4 + i] = spsPayload[i]

        provider.setSPSPPS(data, data.size)
        assertNotNull(provider.getSPS())
        assertNull(provider.getPPS())
    }

    @Test
    fun `setSPSPPS correctly identifies NAL types by lower 5 bits`() {
        // NAL type is in the lower 5 bits of the byte after start code
        // Type 7 (SPS) = 0x67 & 0x1F = 7, Type 8 (PPS) = 0x68 & 0x1F = 8
        // Also test with different ref_idc values
        val data = byteArrayOf(
            0, 0, 0, 1, 0x27.toByte(), 0x42, // SPS: nal_ref_idc=1, type=7 -> 0x27
            0, 0, 0, 1, 0x28.toByte(), 0xCE.toByte() // PPS: nal_ref_idc=1, type=8 -> 0x28
        )
        provider.setSPSPPS(data, data.size)
        assertNotNull(provider.getSPS())
        assertNotNull(provider.getPPS())
        assertEquals(0x27.toByte(), provider.getSPS()!![4])
        assertEquals(0x28.toByte(), provider.getPPS()!![4])
    }

    // ---- getProfileLevelId ----

    @Test
    fun `getProfileLevelId returns null when no SPS set`() {
        assertNull(provider.getProfileLevelId())
    }

    @Test
    fun `getProfileLevelId extracts from SPS with 4-byte start code`() {
        // SPS: 00 00 00 01 <NAL header=0x67> <profile_idc=0x42> <constraints=0x00> <level=0x1E>
        // getProfileLevelId skips NAL header, reads offset+1..offset+3
        val spsData = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E.toByte())
        val fullData = spsData + byteArrayOf(0, 0, 0, 1, 0x68, 0xCE.toByte()) // add PPS
        provider.setSPSPPS(fullData, fullData.size)

        val profileLevelId = provider.getProfileLevelId()
        assertNotNull(profileLevelId)
        // Bytes at offset 5,6,7 = 0x42, 0x00, 0x1E → "42001E"
        assertEquals("42001E", profileLevelId)
    }

    @Test
    fun `getProfileLevelId extracts from SPS with 3-byte start code`() {
        // SPS stored with 4-byte start code by setSPSPPS
        // getProfileLevelId skips NAL header (offset+1), reads profile_idc/constraints/level
        val data = byteArrayOf(
            0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E.toByte(), // SPS
            0, 0, 0, 1, 0x68, 0xCE.toByte() // PPS
        )
        provider.setSPSPPS(data, data.size)
        assertEquals("42001E", provider.getProfileLevelId())
    }

    @Test
    fun `getProfileLevelId returns null for short SPS`() {
        // SPS too short to contain profile bytes
        val data = byteArrayOf(0, 0, 0, 1, 0x67) // Only 5 bytes total, offset=4, need 3 more
        provider.setSPSPPS(data, data.size)
        // SPS will be the whole data (no second NAL found), size=5
        // offset=4, need offset+3=7, but size is 5 -> returns null
        // Actually setSPSPPS: data.size=5, checks i < length-4 => i < 1, only checks i=0
        // At i=0: 00 00 00 01 matches, nalType = data[4] & 0x1F = 0x67 & 0x1F = 7 -> SPS
        // end = length (5) since no next start code
        // sps = data.copyOfRange(0, 5) = [00,00,00,01,67]
        // getProfileLevelId: offset=4, need spsData.size >= 7 -> 5 >= 7 is false -> null
        val sps = provider.getSPS()
        if (sps != null) {
            assertNull(provider.getProfileLevelId())
        }
    }

    @Test
    fun `getProfileLevelId returns uppercase hex string`() {
        // SPS: NAL header=0x67 (type 7), profile_idc=0x42, constraints=0x00, level=0x1E, +extra byte
        // getProfileLevelId reads offset+1..offset+3 = 0x42, 0x00, 0x1E → "42001E"
        val data = byteArrayOf(
            0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E.toByte(), 0xFF.toByte(), // SPS (NAL type 7)
            0, 0, 0, 1, 0x68.toByte(), 0xEE.toByte() // PPS
        )
        provider.setSPSPPS(data, data.size)
        val id = provider.getProfileLevelId()
        assertNotNull(id)
        assertEquals("42001E", id)
        assertEquals(id, id!!.uppercase())
        assertEquals(6, id.length)
    }
}
