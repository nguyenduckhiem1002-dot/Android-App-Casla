package com.example.casla_production

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CipherLabBroadcastPolicyTest {
    @Test
    fun `legacy Android accepts external sender because sender identity is unavailable`() {
        assertTrue(CipherLabBroadcastPolicy.acceptsSender(33, null))
        assertTrue(CipherLabBroadcastPolicy.acceptsSender(32, "other.app"))
    }

    @Test
    fun `Android 14 and newer accepts only known CipherLab sender packages`() {
        assertTrue(
            CipherLabBroadcastPolicy.acceptsSender(
                34,
                "com.cipherlab.clbarcodeservice",
            ),
        )
        assertTrue(
            CipherLabBroadcastPolicy.acceptsSender(
                35,
                "sw.programme.readerconfig",
            ),
        )
        assertFalse(CipherLabBroadcastPolicy.acceptsSender(34, null))
        assertFalse(CipherLabBroadcastPolicy.acceptsSender(34, "com.example.spoofer"))
    }

    @Test
    fun `decoded data accepts only bounded String or ByteArray input`() {
        assertEquals(
            "NV123",
            CipherLabBroadcastPolicy.sanitizeDecodedData("  NV123\u0000  "),
        )
        assertEquals(
            "NV456",
            CipherLabBroadcastPolicy.sanitizeDecodedData("NV456".toByteArray()),
        )
        assertNull(CipherLabBroadcastPolicy.sanitizeDecodedData(12345))
        assertNull(CipherLabBroadcastPolicy.sanitizeDecodedData(null))
    }

    @Test
    fun `decoded data rejects oversized and embedded NUL values`() {
        val tooLong = "A".repeat(CipherLabBroadcastPolicy.MAX_BARCODE_CHARACTERS + 1)
        val tooManyBytes = ByteArray(CipherLabBroadcastPolicy.MAX_BARCODE_BYTES + 1) { 'A'.code.toByte() }

        assertNull(CipherLabBroadcastPolicy.sanitizeDecodedData(tooLong))
        assertNull(CipherLabBroadcastPolicy.sanitizeDecodedData(tooManyBytes))
        assertNull(CipherLabBroadcastPolicy.sanitizeDecodedData("NV12\u00003"))
    }

    @Test
    fun `symbology is bounded and normalized`() {
        assertEquals("QR", CipherLabBroadcastPolicy.sanitizeSymbology(" QR "))
        assertNull(CipherLabBroadcastPolicy.sanitizeSymbology(""))
        assertNull(
            CipherLabBroadcastPolicy.sanitizeSymbology(
                "Q".repeat(CipherLabBroadcastPolicy.MAX_SYMBOLOGY_CHARACTERS + 1),
            ),
        )
    }
}
