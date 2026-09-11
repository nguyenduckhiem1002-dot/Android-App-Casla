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

    /** Why a broadcast was let through, or turned away. */
    enum class SenderVerdict(val accepted: Boolean) {
        /** `getSentFromPackage()` named a reader service that owns this action. */
        ACCEPTED_BY_PACKAGE(true),

        /** The sending uid resolves to a reader service that owns this action. */
        ACCEPTED_BY_UID(true),

        /**
         * Unattributed, but the sender is an OS-image (privileged) uid. See the
         * residual-risk note on [verifySender].
         */
        ACCEPTED_UNATTRIBUTED_SYSTEM(true),

        /**
         * API 34+, but the platform gave neither a package nor a uid — observed
         * on a Zebra TC22 delivering DataWedge's own broadcast. There being
         * nothing left to check is treated the same as [ACCEPTED_LEGACY]: no
         * weaker than the pre-34 boundary this app already ships with, just
         * arrived at on a device that happens to run API 34.
         */
        ACCEPTED_NO_ATTRIBUTION(true),

        /** Pre-API-34: the platform offers no sender identity at all. */
        ACCEPTED_LEGACY(true),

        /** No configured vendor owns this action. */
        REJECTED_UNKNOWN_ACTION(false),

        /** A package was named, and it is not this action's vendor. */
        REJECTED_PACKAGE(false),

        /** Nothing identified the sender and it is an ordinary app uid. */
        REJECTED_UNATTRIBUTED(false),
    }

    /** Android's first non-system application uid, and the per-user uid stride. */
    const val FIRST_APPLICATION_UID = 10000
    private const val PER_USER_UID_RANGE = 100000

    /**
     * True for OS-image uids (system, radio, nfc, and the privileged apps that
     * ship in the system image) as opposed to installed third-party apps.
     *
     * Multi-user devices offset uids per user, so the app id has to be taken
     * modulo the per-user range before comparing.
     */
    fun isPrivilegedUid(uid: Int): Boolean =
        uid >= 0 && (uid % PER_USER_UID_RANGE) < FIRST_APPLICATION_UID

    /**
     * Decides whether a broadcast on [action] really came from that vendor's
     * reader service.
     *
     * Android below [VERIFY_SENDER_FROM_API] exposes no sender identity to a
     * runtime receiver at all, so those versions are accepted on the payload
     * rules alone — the documented legacy boundary.
     *
     * From API 34 the platform *may* name the sender, and when it does the
     * package must belong to the vendor that owns the action; a package cannot
     * borrow another vendor's action. But on real hardware it frequently does
     * not: a Zebra TC22 on Android 14 delivers DataWedge's output broadcast
     * with `getSentFromPackage()` null, because DataWedge ships as a privileged
     * system app. Rejecting those made the scanner unusable on the exact
     * devices this app is deployed to.
     *
     * So an unattributed broadcast falls back to the sending uid: first by
     * resolving it to package names and matching the vendor allowlist, and
     * failing that by requiring the uid to be privileged. An ordinary installed
     * app cannot obtain a privileged uid, so a third-party spoofer is still
     * turned away — but a compromised system component would not be, which is
     * the same posture Android 13 and older already have. `android/SCANNER_SECURITY.md`
     * records this as residual risk rather than a solved problem.
     *
     * A TC22 running DataWedge went one step further still: neither
     * `getSentFromPackage()` nor `getSentFromUid()` carried anything (`senderUid`
     * negative here means "the platform gave nothing," not "checked and found
     * an ordinary app"). At that point there is nothing left to verify against,
     * so it is accepted on the same basis as [SenderVerdict.ACCEPTED_LEGACY] —
     * this is the point where continuing to require *some* attribution on API
     * 34+ would leave this specific hardware strictly worse off than Android
     * 13, for a check that has nothing left to check. A *known*, non-privileged,
     * non-vendor uid is still rejected: that is the actual spoofing case this
     * function exists to catch.
     */
    fun verifySender(
        apiLevel: Int,
        action: String?,
        senderPackage: String?,
        senderUid: Int = -1,
        uidPackages: List<String> = emptyList(),
    ): SenderVerdict {
        val vendor = findVendorForAction(action)
            ?: return SenderVerdict.REJECTED_UNKNOWN_ACTION
        if (apiLevel < VERIFY_SENDER_FROM_API) return SenderVerdict.ACCEPTED_LEGACY

        if (senderPackage != null) {
            return if (senderPackage in vendor.senderPackages) {
                SenderVerdict.ACCEPTED_BY_PACKAGE
            } else {
                SenderVerdict.REJECTED_PACKAGE
            }
        }

        if (uidPackages.any { it in vendor.senderPackages }) {
            return SenderVerdict.ACCEPTED_BY_UID
        }
        if (isPrivilegedUid(senderUid)) return SenderVerdict.ACCEPTED_UNATTRIBUTED_SYSTEM
        // senderUid < 0 here means Android supplied no uid either, not that a
        // uid was checked and found unprivileged — those are different findings
        // and must not share a verdict.
        if (senderUid < 0) return SenderVerdict.ACCEPTED_NO_ATTRIBUTION
        return SenderVerdict.REJECTED_UNATTRIBUTED
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
