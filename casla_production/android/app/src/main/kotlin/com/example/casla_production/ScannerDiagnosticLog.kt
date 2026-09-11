package com.example.casla_production

/**
 * Fixed labels and bounded metadata only: diagnostics must never contain
 * decoded QR/credential text.
 *
 * [record]'s optional `detail` is for values that are safe to show verbatim —
 * currently only the rejected sender's package name (device/app identity,
 * the same category already exposed via `manufacturer`/`installedReaderServices`
 * in `PdaScannerBridge.diagnostics()`, never scan content). It is whitelisted
 * to characters a package name can actually contain and capped short, so even
 * a malformed sender identity cannot smuggle arbitrary text into the log.
 */
internal object ScannerDiagnosticLog {
    enum class Event {
        RECEIVER_REGISTERED, RECEIVER_UNREGISTERED, LISTEN_START, LISTEN_STOP,
        BROADCAST_RECEIVED, UNKNOWN_ACTION, SENDER_UNAVAILABLE, SENDER_REJECTED,
        SENDER_ACCEPTED_BY_UID,
        EXTRAS_MISSING, PAYLOAD_REJECTED, NO_DART_LISTENER, FORWARDED_TO_DART,
    }
    private val entries = java.util.ArrayDeque<String>()
    private const val CAPACITY = 120
    private const val MAX_DETAIL_LENGTH = 100
    private val detailPattern = Regex("[^A-Za-z0-9._:]")

    private fun sanitizeDetail(detail: String): String =
        detail.replace(detailPattern, "?").take(MAX_DETAIL_LENGTH)

    @Synchronized
    fun record(
        event: Event,
        length: Int? = null,
        detail: String? = null,
        uid: Int? = null,
    ): String {
        val line = buildString {
            append(System.currentTimeMillis())
            append(' ')
            append(event.name)
            if (length != null) append(" length=").append(length)
            if (uid != null && uid >= 0) append(" uid=").append(uid)
            if (detail != null) append(" sender=").append(sanitizeDetail(detail))
        }
        if (entries.size >= CAPACITY) entries.removeFirst()
        entries.addLast(line)
        return line
    }

    @Synchronized
    fun snapshot(): List<String> = entries.toList()

    @Synchronized
    fun clear() = entries.clear()
}
