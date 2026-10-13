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
    private val zebraAction = "com.example.casla_production.SCAN"

    private val appUid = ScannerBroadcastPolicy.FIRST_APPLICATION_UID + 123
    private val systemUid = 1000

    private fun verdict(
        apiLevel: Int,
        action: String?,
        senderPackage: String?,
        senderUid: Int = -1,
        uidPackages: List<String> = emptyList(),
    ) = ScannerBroadcastPolicy.verifySender(
        apiLevel = apiLevel,
        action = action,
        senderPackage = senderPackage,
        senderUid = senderUid,
        uidPackages = uidPackages,
    )

    @Test
    fun `legacy Android accepts a known vendor action because sender identity is unavailable`() {
        assertTrue(verdict(33, cipherLabAction, null).accepted)
        assertTrue(verdict(32, cipherLabAction, "other.app").accepted)
        assertTrue(verdict(33, honeywellAction, null).accepted)
    }

    @Test
    fun `an unknown action is rejected on every Android version`() {
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNKNOWN_ACTION,
            verdict(30, "com.example.spoof.SCAN", null),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNKNOWN_ACTION,
            verdict(34, "com.example.spoof.SCAN", "android"),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNKNOWN_ACTION,
            verdict(34, null, "com.symbol.datawedge"),
        )
    }

    @Test
    fun `Android 14 and newer accepts only the reader service owning that action`() {
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.ACCEPTED_BY_PACKAGE,
            verdict(34, cipherLabAction, "com.cipherlab.clbarcodeservice"),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.ACCEPTED_BY_PACKAGE,
            verdict(35, honeywellAction, "com.intermec.datacollectionservice"),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_PACKAGE,
            verdict(35, cipherLabAction, "sw.programme.readerconfig"),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_PACKAGE,
            verdict(34, cipherLabAction, "com.example.spoofer"),
        )
    }

    @Test
    fun `a vendor package cannot borrow another vendor's action`() {
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_PACKAGE,
            verdict(34, cipherLabAction, "com.symbol.datawedge"),
        )
    }

    @Test
    fun `an unattributed broadcast is accepted when its uid resolves to the vendor`() {
        // A Zebra TC22 on Android 14 delivers DataWedge's output broadcast with
        // getSentFromPackage() null. The uid is then the only identity left, and
        // resolving it still proves the sender really is that vendor's service.
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.ACCEPTED_BY_UID,
            verdict(
                34,
                zebraAction,
                senderPackage = null,
                senderUid = appUid,
                uidPackages = listOf("com.symbol.datawedge"),
            ),
        )
    }

    @Test
    fun `an unattributed broadcast from a privileged uid is accepted`() {
        // Reader services ship in the system image. This is the documented
        // residual risk: it is the same posture Android 13 and older already
        // have, not a verified sender.
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.ACCEPTED_UNATTRIBUTED_SYSTEM,
            verdict(34, zebraAction, senderPackage = null, senderUid = systemUid),
        )
    }

    @Test
    fun `an unattributed broadcast from an ordinary app uid is rejected`() {
        // The whole point of the uid fallback: an installed third-party app
        // cannot hold a privileged uid, so it cannot slip through by simply
        // failing to be attributed. A *known* non-privileged uid (appUid, not
        // -1) is what makes this REJECTED rather than ACCEPTED_NO_ATTRIBUTION —
        // see the test below for the case where the platform hands back
        // nothing to check at all.
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNATTRIBUTED,
            verdict(34, zebraAction, senderPackage = null, senderUid = appUid),
        )
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNATTRIBUTED,
            verdict(
                34,
                zebraAction,
                senderPackage = null,
                senderUid = appUid,
                uidPackages = listOf("com.example.spoofer"),
            ),
        )
    }

    @Test
    fun `a uid that resolves to another vendor cannot borrow this action`() {
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.REJECTED_UNATTRIBUTED,
            verdict(
                34,
                cipherLabAction,
                senderPackage = null,
                senderUid = appUid,
                uidPackages = listOf("com.symbol.datawedge"),
            ),
        )
    }

    @Test
    fun `a broadcast with neither package nor uid attribution is accepted on API 34`() {
        // Observed for real on a Zebra TC22: getSentFromPackage() and
        // getSentFromUid() both come back empty for DataWedge's own broadcast.
        // With nothing left to check, this must not be worse than the pre-34
        // boundary the app already ships with.
        assertEquals(
            ScannerBroadcastPolicy.SenderVerdict.ACCEPTED_NO_ATTRIBUTION,
            verdict(34, zebraAction, senderPackage = null, senderUid = -1),
        )
    }

    @Test
    fun `privileged uid detection survives the per-user uid offset`() {
        assertTrue(ScannerBroadcastPolicy.isPrivilegedUid(1000))
        assertTrue(ScannerBroadcastPolicy.isPrivilegedUid(1000 + 100000))
        assertFalse(ScannerBroadcastPolicy.isPrivilegedUid(appUid))
        assertFalse(ScannerBroadcastPolicy.isPrivilegedUid(appUid + 100000))
        assertFalse(ScannerBroadcastPolicy.isPrivilegedUid(-1))
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
