package com.example.casla_production

/**
 * Pure policy for the untrusted CipherLab broadcast boundary.
 *
 * Kept Android-free so sender and payload rules can be unit-tested without an
 * emulator. Android 13 and below cannot expose the original broadcast sender
 * identity to a runtime receiver, so those versions remain a documented legacy
 * trust boundary. Android 14+ must identify CipherLab Reader Service.
 */
internal object CipherLabBroadcastPolicy {
    const val VERIFY_SENDER_FROM_API = 34
    const val MAX_BARCODE_CHARACTERS = 4096
    const val MAX_BARCODE_BYTES = 8192
    const val MAX_SYMBOLOGY_CHARACTERS = 64

    private const val READER_SERVICE_PACKAGE = "com.cipherlab.clbarcodeservice"

    fun acceptsSender(apiLevel: Int, senderPackage: String?): Boolean {
        if (apiLevel < VERIFY_SENDER_FROM_API) return true
        return senderPackage == READER_SERVICE_PACKAGE
    }

    fun sanitizeDecodedData(value: Any?): String? {
        val raw = valueAsString(
            value = value,
            maxCharacters = MAX_BARCODE_CHARACTERS,
            maxBytes = MAX_BARCODE_BYTES,
        ) ?: return null

        val sanitized = raw.trim().trimEnd('\u0000').trimEnd()
        if (sanitized.isEmpty() || sanitized.length > MAX_BARCODE_CHARACTERS) return null
        if ('\u0000' in sanitized) return null
        return sanitized
    }

    fun sanitizeSymbology(value: Any?): String? {
        val raw = valueAsString(
            value = value,
            maxCharacters = MAX_SYMBOLOGY_CHARACTERS,
            maxBytes = MAX_SYMBOLOGY_CHARACTERS * 4,
        ) ?: return null
        return raw.trim().takeIf { it.isNotEmpty() }
    }

    private fun valueAsString(
        value: Any?,
        maxCharacters: Int,
        maxBytes: Int,
    ): String? {
        val raw = when (value) {
            is String -> value
            is ByteArray -> {
                if (value.size > maxBytes) return null
                value.toString(Charsets.UTF_8)
            }
            else -> return null
        }

        if (raw.length > maxCharacters) return null
        return raw
    }
}
