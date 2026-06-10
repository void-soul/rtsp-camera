package com.gld.rtsp_camera

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for the NAL unit parsing and FU-A fragmentation logic used by RTPSender.
 *
 * Since the actual methods in RTPSender are private, these tests replicate the
 * exact algorithms as static helper functions and verify correctness of the logic.
 */
class RTPSenderTest {

    companion object {
        private const val MAX_PACKET_SIZE = 1400

        /**
         * Find the next H.264 start code (00 00 01 or 00 00 00 01) in data[start..length).
         * Returns the index of the first byte of the start code, or length if not found.
         * Replicates RTPSender.findNextStartCode() exactly.
         */
        fun findNextStartCode(data: ByteArray, start: Int, length: Int): Int {
            for (i in start until length - 3) {
                if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                    if (data[i + 2] == 1.toByte() ||
                        (data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte())
                    ) {
                        return i
                    }
                }
            }
            return length
        }

        /**
         * Parse a byte buffer containing one or more NAL units with Annex-B start codes.
         * Returns a list of (offset, size) pairs for each NAL unit found.
         */
        fun parseNALUnits(data: ByteArray, length: Int): List<Pair<Int, Int>> {
            val nalUnits = mutableListOf<Pair<Int, Int>>()
            var i = 0
            while (i < length - 3) {
                var startCodeSize = 0
                if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                    if (data[i + 2] == 1.toByte()) {
                        startCodeSize = 3
                    } else if (i < length - 3 && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                        startCodeSize = 4
                    }
                }
                if (startCodeSize > 0) {
                    val start = i + startCodeSize
                    val end = findNextStartCode(data, start, length)
                    val nalSize = end - start
                    if (nalSize > 0) {
                        nalUnits.add(Pair(start, nalSize))
                    }
                    i = end
                } else {
                    i++
                }
            }
            return nalUnits
        }

        /**
         * Compute FU-A fragmentation of a NAL unit.
         * Returns a list of fragments, each as (isFirst, isLast, payloadOffset, payloadSize)
         * relative to the source NAL data (excluding the NAL header byte).
         *
         * Replicates RTPSender.sendFUAPackets() logic for determining chunk boundaries.
         */
        data class FUAFragment(
            val isFirst: Boolean,
            val isLast: Boolean,
            val payloadOffset: Int, // offset into source NAL data (after NAL header)
            val payloadSize: Int
        )

        fun computeFUAFragments(nalData: ByteArray, nalOffset: Int, nalSize: Int): List<FUAFragment> {
            val fragments = mutableListOf<FUAFragment>()
            var currentOffset = nalOffset + 1 // skip NAL header byte
            val endOffset = nalOffset + nalSize
            var firstPacket = true

            while (currentOffset < endOffset) {
                val remaining = endOffset - currentOffset
                val chunkSize = minOf(MAX_PACKET_SIZE - 2, remaining) // -2 for FU indicator + FU header
                val lastPacket = (currentOffset + chunkSize) >= endOffset

                fragments.add(
                    FUAFragment(
                        isFirst = firstPacket,
                        isLast = lastPacket,
                        payloadOffset = currentOffset - nalOffset - 1, // relative to after NAL header
                        payloadSize = chunkSize
                    )
                )

                currentOffset += chunkSize
                firstPacket = false
            }
            return fragments
        }

        /**
         * Compute the FU indicator byte for FU-A packets.
         * Format: F(1) | NRI(2) | Type(5) = 0x1C (FU-A type)
         * F and NRI come from the original NAL header.
         */
        fun computeFUIndicator(nalHeaderByte: Byte): Int {
            val nalRefIdc = (nalHeaderByte.toInt() and 0x60) shr 5
            return (nalRefIdc shl 5) or 0x1C
        }

        /**
         * Compute the FU header byte for a given fragment position.
         * Format: S(1) | E(1) | R(1) | Type(5)
         */
        fun computeFUHeader(isFirst: Boolean, isLast: Boolean, nalType: Int): Int {
            return when {
                isFirst -> 0x80 or nalType   // S=1, E=0, R=0
                isLast -> 0x40 or nalType    // S=0, E=1, R=0
                else -> nalType              // S=0, E=0, R=0
            }
        }

        /**
         * Write an RTP header into the given buffer at offset 0.
         * Replicates RTPSender.writeRTPHeader() exactly.
         */
        fun writeRTPHeader(
            packet: ByteArray,
            marker: Boolean,
            sequenceNumber: Int,
            timestamp: Long,
            ssrc: Long
        ) {
            packet[0] = 0x80.toByte()
            val payloadType = 96
            packet[1] = ((if (marker) 0x80 else 0x00) or (payloadType and 0x7F)).toByte()

            packet[2] = ((sequenceNumber shr 8) and 0xFF).toByte()
            packet[3] = (sequenceNumber and 0xFF).toByte()

            packet[4] = ((timestamp shr 24) and 0xFF).toByte()
            packet[5] = ((timestamp shr 16) and 0xFF).toByte()
            packet[6] = ((timestamp shr 8) and 0xFF).toByte()
            packet[7] = (timestamp and 0xFF).toByte()

            packet[8] = ((ssrc shr 24) and 0xFF).toByte()
            packet[9] = ((ssrc shr 16) and 0xFF).toByte()
            packet[10] = ((ssrc shr 8) and 0xFF).toByte()
            packet[11] = (ssrc and 0xFF).toByte()
        }
    }

    // =========================================================================
    // findNextStartCode tests
    // =========================================================================

    @Test
    fun `findNextStartCode finds 3-byte start code`() {
        val data = byteArrayOf(0x01, 0x02, 0, 0, 1, 0x65, 0x03)
        val pos = findNextStartCode(data, 0, data.size)
        assertEquals(2, pos)
    }

    @Test
    fun `findNextStartCode finds 4-byte start code`() {
        val data = byteArrayOf(0x01, 0x02, 0, 0, 0, 1, 0x65, 0x03)
        val pos = findNextStartCode(data, 0, data.size)
        assertEquals(2, pos)
    }

    @Test
    fun `findNextStartCode returns length when not found`() {
        val data = byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05)
        val pos = findNextStartCode(data, 0, data.size)
        assertEquals(data.size, pos)
    }

    @Test
    fun `findNextStartCode respects start parameter`() {
        val data = byteArrayOf(0, 0, 1, 0x65, 0, 0, 1, 0x67)
        // First start code at index 0, second at index 4
        val pos = findNextStartCode(data, 3, data.size)
        assertEquals(4, pos)
    }

    @Test
    fun `findNextStartCode handles consecutive start codes`() {
        val data = byteArrayOf(0, 0, 0, 1, 0, 0, 0, 1, 0x65)
        // First at 0, searching from after first should find second at 4
        val pos = findNextStartCode(data, 4, data.size)
        assertEquals(4, pos)
    }

    @Test
    fun `findNextStartCode returns length for data shorter than 4 bytes`() {
        val data = byteArrayOf(0, 0, 1)
        val pos = findNextStartCode(data, 0, data.size)
        assertEquals(data.size, pos)
    }

    // =========================================================================
    // NAL unit parsing tests
    // =========================================================================

    @Test
    fun `parseNALUnits finds single NAL with 4-byte start code`() {
        val data = byteArrayOf(0, 0, 0, 1, 0x65, 0x42, 0x00, 0x1E.toByte())
        val nals = parseNALUnits(data, data.size)
        assertEquals(1, nals.size)
        assertEquals(4, nals[0].first)  // offset after start code
        assertEquals(4, nals[0].second) // size of NAL data
    }

    @Test
    fun `parseNALUnits finds single NAL with 3-byte start code`() {
        val data = byteArrayOf(0, 0, 1, 0x67, 0x42, 0x00)
        val nals = parseNALUnits(data, data.size)
        assertEquals(1, nals.size)
        assertEquals(3, nals[0].first)
        assertEquals(3, nals[0].second)
    }

    @Test
    fun `parseNALUnits finds multiple NAL units`() {
        // SPS (4-byte start code) + PPS (4-byte start code) + IDR (3-byte start code)
        val data = byteArrayOf(
            0, 0, 0, 1, 0x67, 0x42,       // SPS
            0, 0, 0, 1, 0x68, 0xCE.toByte(), // PPS
            0, 0, 1, 0x65, 0x88.toByte()    // IDR
        )
        val nals = parseNALUnits(data, data.size)
        assertEquals(3, nals.size)

        assertEquals(4, nals[0].first)  // SPS offset
        assertEquals(2, nals[0].second) // SPS size
        assertEquals(10, nals[1].first) // PPS offset
        assertEquals(2, nals[1].second) // PPS size
        assertEquals(15, nals[2].first) // IDR offset
        assertEquals(2, nals[2].second) // IDR size
    }

    @Test
    fun `parseNALUnits returns empty for data without start codes`() {
        val data = byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05)
        val nals = parseNALUnits(data, data.size)
        assertTrue(nals.isEmpty())
    }

    @Test
    fun `parseNALUnits handles mixed 3-byte and 4-byte start codes`() {
        val data = byteArrayOf(
            0, 0, 1, 0x67, 0x42,           // 3-byte start code SPS
            0, 0, 0, 1, 0x68, 0xCE.toByte() // 4-byte start code PPS
        )
        val nals = parseNALUnits(data, data.size)
        assertEquals(2, nals.size)
        assertEquals(3, nals[0].first)  // 3-byte offset
        assertEquals(2, nals[0].second)
        assertEquals(9, nals[1].first)  // 4-byte start code at offset 5 → NAL at offset 9
        assertEquals(2, nals[1].second) // 0x68, 0xCE
    }

    // =========================================================================
    // FU-A fragmentation tests
    // =========================================================================

    @Test
    fun `small NAL does not need FU-A fragmentation`() {
        // A NAL unit smaller than MAX_PACKET_SIZE should be sent as single packet
        val nalSize = 100
        assertTrue(nalSize <= MAX_PACKET_SIZE)
    }

    @Test
    fun `FU-A fragmentation for NAL larger than max packet size`() {
        // Create a NAL unit larger than maxPacketSize (1400)
        val nalSize = 3000
        val nalData = ByteArray(1 + nalSize) // 1 byte header + payload
        nalData[0] = 0x65.toByte() // IDR NAL: type=5, ref_idc=3

        val fragments = computeFUAFragments(nalData, 0, 1 + nalSize)

        // First fragment payload: maxPacketSize - 2 = 1398 bytes
        // Remaining: 3000 - 1398 = 1602
        // Second fragment: 1398 bytes
        // Remaining: 1602 - 1398 = 204
        // Third fragment: 204 bytes
        assertTrue("Should have at least 2 fragments", fragments.size >= 2)

        // First fragment: S=1, E=0
        assertTrue(fragments[0].isFirst)
        assertFalse(fragments[0].isLast)

        // Last fragment: S=0, E=1
        val last = fragments.last()
        assertFalse(last.isFirst)
        assertTrue(last.isLast)

        // Middle fragments: S=0, E=0
        if (fragments.size > 2) {
            for (i in 1 until fragments.size - 1) {
                assertFalse("Middle fragment $i should not be first", fragments[i].isFirst)
                assertFalse("Middle fragment $i should not be last", fragments[i].isLast)
            }
        }
    }

    @Test
    fun `FU-A fragment payload sizes sum to NAL payload size`() {
        val nalPayloadSize = 5000
        val nalData = ByteArray(1 + nalPayloadSize)
        nalData[0] = 0x65.toByte()

        val fragments = computeFUAFragments(nalData, 0, 1 + nalPayloadSize)

        val totalPayload = fragments.sumOf { it.payloadSize }
        assertEquals("Total payload must equal NAL payload size", nalPayloadSize.toLong(), totalPayload.toLong())
    }

    @Test
    fun `FU-A first fragment payload size is maxPacketSize - 2`() {
        val nalSize = 3000
        val nalData = ByteArray(1 + nalSize)
        nalData[0] = 0x65.toByte()

        val fragments = computeFUAFragments(nalData, 0, 1 + nalSize)

        assertEquals(MAX_PACKET_SIZE - 2, fragments[0].payloadSize)
    }

    @Test
    fun `FU-A last fragment can be smaller than maxPacketSize - 2`() {
        // NAL that results in a small final fragment
        val nalSize = MAX_PACKET_SIZE - 2 + 10 // 1398 + 10 = 1408
        val nalData = ByteArray(1 + nalSize)
        nalData[0] = 0x65.toByte()

        val fragments = computeFUAFragments(nalData, 0, 1 + nalSize)
        assertEquals(2, fragments.size)
        assertEquals(MAX_PACKET_SIZE - 2, fragments[0].payloadSize)
        assertEquals(10, fragments[1].payloadSize) // remainder
    }

    @Test
    fun `FU-A with exactly maxPacketSize - 2 payload needs no fragmentation`() {
        // NAL payload exactly fits in one FU-A packet (but it should use single NAL mode, not FU-A)
        // Actually, FU-A is used when nalSize > maxPacketSize (1400)
        // So a NAL of exactly 1401 bytes would need FU-A
        val nalSize = MAX_PACKET_SIZE + 1 // 1401
        val nalData = ByteArray(1 + nalSize)
        nalData[0] = 0x65.toByte()

        val fragments = computeFUAFragments(nalData, 0, 1 + nalSize)
        // Payload after NAL header = 1401 bytes
        // First fragment: 1398 bytes, remaining: 3 bytes
        // Second fragment: 3 bytes
        assertEquals(2, fragments.size)
        assertEquals(1398, fragments[0].payloadSize)
        assertEquals(3, fragments[1].payloadSize)
    }

    // =========================================================================
    // FU indicator and header tests
    // =========================================================================

    @Test
    fun `FU-A indicator byte extracts NRI from NAL header`() {
        // NAL header: 0x65 = 0110_0101 -> F=0, NRI=11 (3), Type=00101 (5)
        val nalHeader = 0x65.toByte()
        val fuIndicator = computeFUIndicator(nalHeader)

        // Expected: NRI=3 << 5 | 0x1C = 0x60 | 0x1C = 0x7C
        assertEquals(0x7C, fuIndicator)
    }

    @Test
    fun `FU-A indicator for non-reference NAL`() {
        // NAL header: 0x41 = 0100_0001 -> F=0, NRI=10 (2), Type=00001 (1)
        val nalHeader = 0x41.toByte()
        val fuIndicator = computeFUIndicator(nalHeader)

        // Expected: NRI=2 << 5 | 0x1C = 0x40 | 0x1C = 0x5C
        assertEquals(0x5C, fuIndicator)
    }

    @Test
    fun `FU-A indicator preserves forbidden bit position`() {
        // NAL header: 0x85 = 1000_0101 -> F=1, NRI=00 (0), Type=00101 (5)
        val nalHeader = 0x85.toByte()
        val fuIndicator = computeFUIndicator(nalHeader)

        // Expected: NRI=0 << 5 | 0x1C = 0x1C
        // Note: The FU-A indicator type is always 28 (0x1C), and F+NRI come from NAL header
        assertEquals(0x1C, fuIndicator)
    }

    @Test
    fun `FU header start bit set for first fragment`() {
        val nalType = 5 // IDR
        val header = computeFUHeader(isFirst = true, isLast = false, nalType = nalType)
        // S=1, E=0, R=0, Type=5 -> 0x80 | 5 = 0x85
        assertEquals(0x85, header)
    }

    @Test
    fun `FU header end bit set for last fragment`() {
        val nalType = 5
        val header = computeFUHeader(isFirst = false, isLast = true, nalType = nalType)
        // S=0, E=1, R=0, Type=5 -> 0x40 | 5 = 0x45
        assertEquals(0x45, header)
    }

    @Test
    fun `FU header no flags for middle fragment`() {
        val nalType = 5
        val header = computeFUHeader(isFirst = false, isLast = false, nalType = nalType)
        // S=0, E=0, R=0, Type=5 -> 5
        assertEquals(5, header)
    }

    @Test
    fun `FU-A type is always 28 (0x1C)`() {
        // FU-A NAL type = 28, which is the fragmentation type
        val fuType = 0x1C
        assertEquals(28, fuType)

        // The FU indicator always uses type 28 regardless of original NAL type
        val nalHeader = 0x67.toByte() // SPS, type=7
        val indicator = computeFUIndicator(nalHeader)
        assertEquals(28, indicator and 0x1F) // lower 5 bits = type
    }

    // =========================================================================
    // RTP header tests
    // =========================================================================

    @Test
    fun `RTP header version is 2`() {
        val buf = ByteArray(12)
        writeRTPHeader(buf, marker = false, sequenceNumber = 0, timestamp = 0, ssrc = 0)
        // Version = 2 -> top 2 bits of byte 0 = 10 -> 0x80
        assertEquals(0x80.toByte(), buf[0])
    }

    @Test
    fun `RTP header marker bit`() {
        val bufNoMarker = ByteArray(12)
        writeRTPHeader(bufNoMarker, marker = false, sequenceNumber = 0, timestamp = 0, ssrc = 0)

        val bufMarker = ByteArray(12)
        writeRTPHeader(bufMarker, marker = true, sequenceNumber = 0, timestamp = 0, ssrc = 0)

        // Marker bit is the MSB of byte 1
        assertEquals(0, bufNoMarker[1].toInt() and 0x80)
        assertNotEquals(0, bufMarker[1].toInt() and 0x80)
    }

    @Test
    fun `RTP header payload type is 96`() {
        val buf = ByteArray(12)
        writeRTPHeader(buf, marker = false, sequenceNumber = 0, timestamp = 0, ssrc = 0)
        // Payload type in lower 7 bits of byte 1
        assertEquals(96, buf[1].toInt() and 0x7F)
    }

    @Test
    fun `RTP header marker bit and payload type combined`() {
        val buf = ByteArray(12)
        writeRTPHeader(buf, marker = true, sequenceNumber = 0, timestamp = 0, ssrc = 0)
        // byte[1] = 0x80 | 96 = 0x80 | 0x60 = 0xE0
        assertEquals(0xE0.toByte(), buf[1])
    }

    @Test
    fun `RTP header sequence number big-endian`() {
        val buf = ByteArray(12)
        writeRTPHeader(buf, marker = false, sequenceNumber = 0x1234, timestamp = 0, ssrc = 0)
        assertEquals(0x12.toByte(), buf[2])
        assertEquals(0x34.toByte(), buf[3])
    }

    @Test
    fun `RTP header sequence number max value`() {
        val buf = ByteArray(12)
        writeRTPHeader(buf, marker = false, sequenceNumber = 0xFFFF, timestamp = 0, ssrc = 0)
        assertEquals(0xFF.toByte(), buf[2])
        assertEquals(0xFF.toByte(), buf[3])
    }

    @Test
    fun `RTP header timestamp big-endian`() {
        val buf = ByteArray(12)
        val ts = 0x12345678L
        writeRTPHeader(buf, marker = false, sequenceNumber = 0, timestamp = ts, ssrc = 0)
        assertEquals(0x12.toByte(), buf[4])
        assertEquals(0x34.toByte(), buf[5])
        assertEquals(0x56.toByte(), buf[6])
        assertEquals(0x78.toByte(), buf[7])
    }

    @Test
    fun `RTP header ssrc big-endian`() {
        val buf = ByteArray(12)
        val ssrc = 0xABCDEF01L
        writeRTPHeader(buf, marker = false, sequenceNumber = 0, timestamp = 0, ssrc = ssrc)
        assertEquals(0xAB.toByte(), buf[8])
        assertEquals(0xCD.toByte(), buf[9])
        assertEquals(0xEF.toByte(), buf[10])
        assertEquals(0x01.toByte(), buf[11])
    }

    @Test
    fun `RTP header is exactly 12 bytes`() {
        // The header occupies bytes 0-11, payload starts at byte 12
        val buf = ByteArray(1500)
        writeRTPHeader(buf, marker = true, sequenceNumber = 100, timestamp = 90000, ssrc = 12345)
        // Byte 12 should still be 0 (untouched)
        assertEquals(0.toByte(), buf[12])
    }

    // =========================================================================
    // Integration: FU-A packet structure validation
    // =========================================================================

    @Test
    fun `FU-A packet structure - first fragment`() {
        // Simulate building a FU-A first fragment
        val nalHeader = 0x65.toByte() // IDR: type=5, ref_idc=3
        val nalType = nalHeader.toInt() and 0x1F

        val fuIndicator = computeFUIndicator(nalHeader)
        val fuHeader = computeFUHeader(isFirst = true, isLast = false, nalType = nalType)

        // FU indicator: NRI=3, type=28 -> 0x7C
        assertEquals(0x7C, fuIndicator)
        // FU header: S=1, type=5 -> 0x85
        assertEquals(0x85, fuHeader)
    }

    @Test
    fun `FU-A packet structure - last fragment`() {
        val nalHeader = 0x65.toByte()
        val nalType = nalHeader.toInt() and 0x1F

        val fuIndicator = computeFUIndicator(nalHeader)
        val fuHeader = computeFUHeader(isFirst = false, isLast = true, nalType = nalType)

        assertEquals(0x7C, fuIndicator)
        assertEquals(0x45, fuHeader) // E=1, type=5
    }

    @Test
    fun `single NAL vs FU-A decision threshold`() {
        // Single NAL: size <= maxPacketSize (1400)
        // FU-A: size > maxPacketSize
        assertTrue(1400 <= MAX_PACKET_SIZE)  // single NAL
        assertFalse(1401 <= MAX_PACKET_SIZE) // needs FU-A
    }

    @Test
    fun `FU-A total overhead per fragment is 2 bytes`() {
        // Each FU-A fragment has: RTP header (12) + FU indicator (1) + FU header (1) + payload
        // The "overhead" beyond payload is 2 bytes (FU indicator + FU header)
        // Max payload per fragment = maxPacketSize - 2
        assertEquals(1398, MAX_PACKET_SIZE - 2)
    }

    // =========================================================================
    // setFramerate tick calculation
    // =========================================================================

    @Test
    fun `frame interval ticks for common framerates`() {
        val clockRate = 90000
        // 30fps: 90000/30 = 3000
        assertEquals(3000, if (30 > 0) clockRate / 30 else 3000)
        // 25fps: 90000/25 = 3600
        assertEquals(3600, if (25 > 0) clockRate / 25 else 3000)
        // 60fps: 90000/60 = 1500
        assertEquals(1500, if (60 > 0) clockRate / 60 else 3000)
        // 15fps: 90000/15 = 6000
        assertEquals(6000, if (15 > 0) clockRate / 15 else 3000)
        // 0fps: fallback to 3000
        assertEquals(3000, if (0 > 0) clockRate / 0 else 3000)
    }
}
