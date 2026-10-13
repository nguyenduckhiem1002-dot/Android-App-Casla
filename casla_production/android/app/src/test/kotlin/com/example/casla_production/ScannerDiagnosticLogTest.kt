package com.example.casla_production

import org.junit.Assert.*
import org.junit.Test

class ScannerDiagnosticLogTest {
    @Test fun boundedSnapshotAndClear() {
        ScannerDiagnosticLog.clear()
        repeat(200) { ScannerDiagnosticLog.record(ScannerDiagnosticLog.Event.FORWARDED_TO_DART, it) }
        val entries = ScannerDiagnosticLog.snapshot()
        assertEquals(120, entries.size)
        assertTrue(entries.first().endsWith("length=80"))
        assertTrue(entries.last().endsWith("length=199"))
        ScannerDiagnosticLog.clear()
        assertTrue(ScannerDiagnosticLog.snapshot().isEmpty())
    }

    @Test fun senderDetailIsRecordedVerbatimWhenSafe() {
        ScannerDiagnosticLog.clear()
        ScannerDiagnosticLog.record(
            ScannerDiagnosticLog.Event.SENDER_REJECTED,
            detail = "com.symbol.datawedge",
        )
        assertTrue(
            ScannerDiagnosticLog.snapshot().single()
                .endsWith("SENDER_REJECTED sender=com.symbol.datawedge"),
        )
    }

    @Test fun senderDetailIsSanitizedAndBounded() {
        ScannerDiagnosticLog.clear()
        // A sender identity is never QR content, but it is still untrusted OS-reported
        // text — anything outside [A-Za-z0-9._:] must not reach the exported trace, and
        // an unreasonably long value must not grow the log entry without bound.
        val hostile = "evil pkg; rm -rf /".repeat(20)
        ScannerDiagnosticLog.record(ScannerDiagnosticLog.Event.SENDER_REJECTED, detail = hostile)
        val line = ScannerDiagnosticLog.snapshot().single()
        val recordedDetail = line.substringAfter("sender=")

        assertFalse(recordedDetail.contains(" "))
        assertFalse(recordedDetail.contains(";"))
        assertFalse(recordedDetail.contains("/"))
        assertTrue(recordedDetail.length < hostile.length)
    }
}
