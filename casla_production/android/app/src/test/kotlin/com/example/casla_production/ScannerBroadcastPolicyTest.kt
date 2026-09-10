package com.example.casla_production

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScannerBroadcastPolicyTest {
    private val cipherLabAction = "com.cipherlab.barcodebaseapi.PASS_DATA_2_APP"
    private val honeywellAction = "com.honeywell.scan.broadcast"

    @Test
    fun `legacy Android accepts a known vendor action because sender identity is unavailable`() {
        assertTrue(ScannerBroadcastPolicy.acceptsSender(33, cipherLabAction, null))
        assertTrue(ScannerBroadcastPolicy.acceptsSender(32, cipherLabAction, "other.app"))
        assertTrue(ScannerBroadcastPolicy.acceptsSender(33, honeywellAction, null))
    }

    @Test
    fun `an unknown action is rejected on every Android version`() {
        assertFalse(ScannerBroadcastPolicy.acceptsSender(30, "com.example.spoof.SCAN", null))
        assertFalse(ScannerBroadcastPolicy.acceptsSender(34, "com.example.spoof.SCAN", "android"))
        assertFalse(ScannerBroadcastPolicy.acceptsSender(34, null, "com.symbol.datawedge"))
    }

    @Test
    fun `Android 14 and newer accepts only the reader service owning that action`() {
        assertTrue(
            ScannerBroadcastPolicy.acceptsSender(
                34,
                cipherLabAction,
                "com.cipherlab.clbarcodeservice",
            ),
        )
        assertTrue(
            ScannerBroadcastPolicy.acceptsSender(
                35,
                honeywellAction,
                "com.intermec.datacollectionservice",
            ),
        )
        assertFalse(
            ScannerBroadcastPolicy.acceptsSender(
                35,
                cipherLabAction,
                "sw.programme.readerconfig",
            ),
        )
        assertFalse(ScannerBroadcastPolicy.acceptsSender(34, cipherLabAction, null))
        assertFalse(ScannerBroadcastPolicy.acceptsSender(34, cipherLabAction, "com.example.spoofer"))
    }

    @Test
    fun `a vendor package cannot borrow another vendor's action`() {
        assertFalse(
            ScannerBroadcastPolicy.acceptsSender(
                34,
                cipherLabAction,
                "com.symbol.datawedge",
            ),
        )
    }

    @Test
    fun `every configured vendor exposes a resolvable action and at least one data extra`() {
        for (vendor in ScannerBroadcastPolicy.vendorBroadcasts) {
            assertNotNull(
                "action ${vendor.action} must resolve back to its vendor",
                ScannerBroadcastPolicy.findVendorForAction(vendor.action),
            )
            assertTrue(
                "${vendor.vendor} must declare a data extra",
                vendor.dataExtras.isNotEmpty(),
            )
            assertTrue(
                "${vendor.vendor} must declare a sender package for API 34+",
                vendor.senderPackages.isNotEmpty(),
            )
        }
    }

    @Test
    fun `broadcast actions are unique so one intent cannot map to two vendors`() {
        val actions = ScannerBroadcastPolicy.vendorBroadcasts.map { it.action }
        assertEquals(actions.size, actions.toSet().size)
    }

    @Test
    fun `PDA detection matches make and brand case-insensitively, never model`() {
        assertTrue(ScannerBroadcastPolicy.isPdaVendor("CipherLab", "CipherLab"))
        assertTrue(ScannerBroadcastPolicy.isPdaVendor("Zebra Technologies", "zebra"))
        assertTrue(ScannerBroadcastPolicy.isPdaVendor("UROVO", null))
        assertTrue(ScannerBroadcastPolicy.isPdaVendor(null, "Honeywell"))

        assertFalse(ScannerBroadcastPolicy.isPdaVendor("samsung", "samsung"))
        assertFalse(ScannerBroadcastPolicy.isPdaVendor(null, null))
        assertFalse(ScannerBroadcastPolicy.isPdaVendor("", "  "))
        // The retired RS38 hardcode lived in the model string; a plain handset
        // reporting that model must no longer be treated as a PDA by itself.
        assertFalse(ScannerBroadcastPolicy.isPdaVendor("Google", "google"))
    }

    @Test
    fun `decoded data accepts only bounded String or ByteArray input`() {
        assertEquals(
            "NV123",
            ScannerBroadcastPolicy.sanitizeDecodedData("  NV123\u0000  "),
        )
        assertEquals(
            "NV456",
            ScannerBroadcastPolicy.sanitizeDecodedData("NV456".toByteArray()),
        )
        assertNull(ScannerBroadcastPolicy.sanitizeDecodedData(12345))
        assertNull(ScannerBroadcastPolicy.sanitizeDecodedData(null))
    }

    @Test
    fun `decoded data rejects oversized and embedded NUL values`() {
        val tooLong = "A".repeat(ScannerBroadcastPolicy.MAX_BARCODE_CHARACTERS + 1)
        val tooManyBytes =
            ByteArray(ScannerBroadcastPolicy.MAX_BARCODE_BYTES + 1) { 'A'.code.toByte() }

        assertNull(ScannerBroadcastPolicy.sanitizeDecodedData(tooLong))
        assertNull(ScannerBroadcastPolicy.sanitizeDecodedData(tooManyBytes))
        assertNull(ScannerBroadcastPolicy.sanitizeDecodedData("NV12\u00003"))
    }

    @Test
    fun `symbology is bounded and normalized`() {
        assertEquals("QR", ScannerBroadcastPolicy.sanitizeSymbology(" QR "))
        assertNull(ScannerBroadcastPolicy.sanitizeSymbology(""))
        assertNull(
            ScannerBroadcastPolicy.sanitizeSymbology(
                "Q".repeat(ScannerBroadcastPolicy.MAX_SYMBOLOGY_CHARACTERS + 1),
            ),
        )
    }
}
