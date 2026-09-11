package com.example.casla_production

/** Fixed labels only: diagnostics must never contain decoded QR/credential text. */
internal object ScannerDiagnosticLog {
    enum class Event {
        RECEIVER_REGISTERED, RECEIVER_UNREGISTERED, LISTEN_START, LISTEN_STOP,
        BROADCAST_RECEIVED, UNKNOWN_ACTION, SENDER_UNAVAILABLE, SENDER_REJECTED,
        EXTRAS_MISSING, PAYLOAD_REJECTED, NO_DART_LISTENER, FORWARDED_TO_DART,
    }
    private val entries = java.util.ArrayDeque<String>()
    private const val CAPACITY = 120

    @Synchronized
    fun record(event: Event, length: Int? = null): String {
        val line = "${System.currentTimeMillis()} ${event.name}" +
            (length?.let { " length=$it" } ?: "")
        if (entries.size >= CAPACITY) entries.removeFirst()
        entries.addLast(line)
        return line
    }

    @Synchronized
    fun snapshot(): List<String> = entries.toList()

    @Synchronized
    fun clear() = entries.clear()
}
