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
}
