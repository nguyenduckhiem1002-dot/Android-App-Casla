package com.example.casla_production

/**
 * Pure policy for the untrusted PDA scanner-broadcast boundary.
 *
 * Kept Android-free so vendor, sender and payload rules can be unit-tested
 * without an emulator. Android 13 and below cannot expose the original
 * broadcast sender identity to a runtime receiver, so those versions remain a
 * documented legacy trust boundary. Android 14+ must identify a reader service
 * that belongs to the same vendor as the action being handled.
 *
 * Broadcast output is a per-vendor convenience, not the universal path: the
 * keyboard-wedge reader in Dart covers every PDA regardless of make, and is
 * what the app relies on when no vendor here matches.
 */
internal object ScannerBroadcastPolicy {
    const val VERIFY_SENDER_FROM_API = 34
    const val MAX_BARCODE_CHARACTERS = 4096
    const val MAX_BARCODE_BYTES = 8192
    const val MAX_SYMBOLOGY_CHARACTERS = 64

    /**
     * One vendor's documented "send decoded data to the foreground app"
     * contract. [senderPackages] lists the reader services allowed to emit
     * [action] once Android can attribute the sender.
     */
    data class VendorBroadcast(
        val vendor: String,
        val action: String,
        val dataExtras: List<String>,
        val symbologyExtras: List<String>,
        val senderPackages: Set<String>,
    )

    /**
     * Every extra list is ordered: the first key present on the intent wins.
     *
     * Deliberately no `Original_*` / raw-decoder fallbacks. Vendors document
     * the processed value as the one their on-device configuration produced;
     * reading the raw value instead would bypass those device-side rules.
     */
    val vendorBroadcasts: List<VendorBroadcast> = listOf(
        VendorBroadcast(
            vendor = "CipherLab",
            action = "com.cipherlab.barcodebaseapi.PASS_DATA_2_APP",
            dataExtras = listOf("Decoder_Data"),
            symbologyExtras = listOf("Decoder_CodeType_String"),
            senderPackages = setOf("com.cipherlab.clbarcodeservice"),
        ),
        VendorBroadcast(
            vendor = "Zebra DataWedge",
            action = "com.example.casla_production.SCAN",
            dataExtras = listOf("com.symbol.datawedge.data_string"),
            symbologyExtras = listOf("com.symbol.datawedge.label_type"),
            senderPackages = setOf("com.symbol.datawedge"),
        ),
        VendorBroadcast(
            vendor = "Honeywell",
            action = "com.honeywell.scan.broadcast",
            dataExtras = listOf("data", "SCAN_DATA"),
            symbologyExtras = listOf("codeId", "Symbology"),
            senderPackages = setOf(
                "com.intermec.datacollectionservice",
                "com.honeywell.decode.DecodeService",
                "com.honeywell.scanner.service",
            ),
        ),
        VendorBroadcast(
            vendor = "Newland",
            action = "nlscan.action.SCANNER_RESULT",
            dataExtras = listOf("SCAN_BARCODE1", "SCAN_BARCODE"),
            symbologyExtras = listOf("SCAN_BARCODE_TYPE"),
            senderPackages = setOf("com.nlscan.android.scanner", "com.nlscan.scanner"),
        ),
        VendorBroadcast(
            vendor = "Urovo",
            action = "android.intent.ACTION_DECODE_DATA",
            dataExtras = listOf("barcode_string", "barcode"),
            symbologyExtras = listOf("barcodeType"),
            senderPackages = setOf("com.android.scanner.service", "android"),
        ),
        VendorBroadcast(
            vendor = "Sunmi",
            action = "com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED",
            dataExtras = listOf("data"),
            symbologyExtras = listOf("source_byte"),
            senderPackages = setOf("com.sunmi.scanner"),
        ),
    )

    /** Every action the receiver registers an [android.content.IntentFilter] for. */
    val broadcastActions: List<String> = vendorBroadcasts.map { it.action }.distinct()

    /** Every reader-service package worth probing when detecting a PDA. */
    val readerServicePackages: Set<String> =
        vendorBroadcasts.flatMap { it.senderPackages }.toSet() - "android"

    /**
     * Manufacturer/brand fragments that identify a rugged data-capture device.
     *
     * Matched case-insensitively against Build.MANUFACTURER and Build.BRAND
     * only. Model strings are deliberately not matched: a single hardcoded
     * model locks the app to one SKU, which is exactly what this list replaces.
     */
    val pdaVendorFragments: List<String> = listOf(
        "cipherlab",
        "zebra",
        "symbol",
        "honeywell",
        "intermec",
        "datalogic",
        "urovo",
        "chainway",
        "newland",
        "idata",
        "sunmi",
        "unitech",
        "point mobile",
        "pointmobile",
        "seuic",
        "keyence",
        "bluebird",
        "casio",
        "denso",
    )

    fun findVendorForAction(action: String?): VendorBroadcast? {
        if (action == null) return null
        return vendorBroadcasts.firstOrNull { it.action == action }
    }

    fun isPdaVendor(manufacturer: String?, brand: String?): Boolean {
        val haystack = listOfNotNull(manufacturer, brand).joinToString(" ").lowercase()
        if (haystack.isBlank()) return false
        return pdaVendorFragments.any { it in haystack }
    }

    /**
     * Android below [VERIFY_SENDER_FROM_API] cannot attribute a broadcast, so
     * the payload rules below are the only boundary. From API 34 the sender
     * must be a reader service belonging to the same vendor as the action.
     */
    fun acceptsSender(apiLevel: Int, action: String?, senderPackage: String?): Boolean {
        val vendor = findVendorForAction(action) ?: return false
        if (apiLevel < VERIFY_SENDER_FROM_API) return true
        return senderPackage != null && senderPackage in vendor.senderPackages
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
