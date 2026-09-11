package com.example.casla_production

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges a PDA reader service's broadcast output into Flutter without linking
 * any proprietary SDK. Each supported vendor is configured on the device to
 * broadcast decoded data using its documented app-output action; this receiver
 * normalizes every one of them into the same event shape.
 *
 * The receiver must remain exported because reader services run in separate
 * applications. The exported broadcast is therefore treated as untrusted input:
 * Android 14+ verifies the originating package against the vendor that owns the
 * action, only documented processed-data extras are read, and payload
 * shape/size are bounded before anything crosses into Dart.
 *
 * When no vendor here matches, the app is not stuck: the Dart-side keyboard
 * wedge reader handles any PDA whose scanner is left in its default
 * "type the barcode" mode.
 */
class PdaScannerBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    companion object {
        private const val EVENT_CHANNEL = "casla/scanner/events"
        private const val CONTROL_CHANNEL = "casla/scanner/control"

        /**
         * Field-diagnostic tag. Enable with:
         *   adb shell setprop log.tag.CaslaScan VERBOSE
         * or just read it: `adb logcat -s CaslaScan`.
         *
         * Logs fixed decision codes and payload lengths only.
         */
        private const val TAG = "CaslaScan"

    }

    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null
    private var activityStarted = false
    private var receiverRegistered = false
    private var keyDownEvents = 0L
    private var multipleKeyEvents = 0L

    private fun record(event: ScannerDiagnosticLog.Event, length: Int? = null, detail: String? = null) {
        Log.i(TAG, ScannerDiagnosticLog.record(event, length, detail))
    }

    fun noteKeyEvent(event: KeyEvent) {
        if (!activityStarted || eventSink == null) return
        if (event.action == KeyEvent.ACTION_DOWN) keyDownEvents++
        if (event.action == KeyEvent.ACTION_MULTIPLE) multipleKeyEvents++
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action
            record(ScannerDiagnosticLog.Event.BROADCAST_RECEIVED)

            if (action == null) return
            val vendor = ScannerBroadcastPolicy.findVendorForAction(action)
            if (vendor == null) {
                record(ScannerDiagnosticLog.Event.UNKNOWN_ACTION)
                return
            }

            val senderPackage = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                sentFromPackage
            } else {
                null
            }
            if (!ScannerBroadcastPolicy.acceptsSender(Build.VERSION.SDK_INT, action, senderPackage)) {
                // The actual sender package, not the scan payload — safe to log verbatim
                // (sanitized/bounded in ScannerDiagnosticLog) so a real-world reject can be
                // diagnosed from a copied trace instead of guessing at an allowlist addition.
                record(
                    if (senderPackage == null) ScannerDiagnosticLog.Event.SENDER_UNAVAILABLE
                    else ScannerDiagnosticLog.Event.SENDER_REJECTED,
                    detail = senderPackage,
                )
                return
            }

            val extras = intent.extras
            if (extras == null) {
                record(ScannerDiagnosticLog.Event.EXTRAS_MISSING)
                return
            }
            val sanitized = vendor.dataExtras
                .asSequence()
                .mapNotNull { key ->
                    val raw = extras.get(key)
                    ScannerBroadcastPolicy.sanitizeDecodedData(raw)
                }
                .firstOrNull()
            if (sanitized == null) {
                record(ScannerDiagnosticLog.Event.PAYLOAD_REJECTED)
                return
            }

            val symbology = vendor.symbologyExtras
                .asSequence()
                .mapNotNull { key -> ScannerBroadcastPolicy.sanitizeSymbology(extras.get(key)) }
                .firstOrNull()

            val sink = eventSink
            if (sink == null) {
                record(ScannerDiagnosticLog.Event.NO_DART_LISTENER, sanitized.length)
                return
            }
            record(ScannerDiagnosticLog.Event.FORWARDED_TO_DART, sanitized.length)
            sink.success(
                mapOf(
                    "rawValue" to sanitized,
                    "symbology" to symbology,
                    "source" to "hardware",
                    "timestampMs" to System.currentTimeMillis(),
                ),
            )
        }
    }

    init {
        eventChannel.setStreamHandler(this)
        controlChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {
                val available = hasBroadcastScanner()
                Log.i(
                    TAG,
                    "isAvailable=$available make=${Build.MANUFACTURER}/${Build.BRAND} " +
                        "model=${Build.MODEL} readerServices=${installedReaderServices()}",
                )
                result.success(available)
            }
            "diagnostics" -> result.success(diagnostics())
            "clearDiagnostics" -> {
                ScannerDiagnosticLog.clear()
                keyDownEvents = 0
                multipleKeyEvents = 0
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        record(ScannerDiagnosticLog.Event.LISTEN_START)
        updateRegistration()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        record(ScannerDiagnosticLog.Event.LISTEN_STOP)
        updateRegistration()
    }

    fun onStart() {
        activityStarted = true
        updateRegistration()
    }

    fun onStop() {
        activityStarted = false
        unregisterReceiver()
    }

    fun dispose() {
        unregisterReceiver()
        eventSink = null
        eventChannel.setStreamHandler(null)
        controlChannel.setMethodCallHandler(null)
    }

    /**
     * Field-support payload for the Account screen. Everything here is device
     * metadata the technician can already read off the handset; no scan data.
     */
    private fun diagnostics(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "androidSdk" to Build.VERSION.SDK_INT,
        "recognizedVendor" to ScannerBroadcastPolicy.isPdaVendor(Build.MANUFACTURER, Build.BRAND),
        "installedReaderServices" to installedReaderServices().toList(),
        "broadcastActions" to ScannerBroadcastPolicy.broadcastActions,
        "receiverRegistered" to receiverRegistered,
        "nativeKeyDownEvents" to keyDownEvents,
        "nativeMultipleKeyEvents" to multipleKeyEvents,
        "recentEvents" to ScannerDiagnosticLog.snapshot(),
    )

    private fun installedReaderServices(): Set<String> {
        val packageManager = activity.packageManager
        return ScannerBroadcastPolicy.readerServicePackages.filter { candidate ->
            runCatching {
                packageManager.getPackageInfo(candidate, 0)
                true
            }.getOrDefault(false)
        }.toSet()
    }

    /**
     * True when this handset looks like a data-capture device: either the
     * make is a known PDA vendor, or one of their reader services is installed.
     *
     * Model strings are intentionally not consulted. Dart treats this as a
     * hint, not a verdict — the keyboard wedge stays armed either way, and a
     * technician can override the mode from the Account screen.
     */
    private fun hasBroadcastScanner(): Boolean {
        if (ScannerBroadcastPolicy.isPdaVendor(Build.MANUFACTURER, Build.BRAND)) return true
        return installedReaderServices().isNotEmpty()
    }

    private fun updateRegistration() {
        val shouldRegister = activityStarted && eventSink != null
        Log.i(
            TAG,
            "updateRegistration started=$activityStarted listening=${eventSink != null} " +
                "-> ${if (shouldRegister) "register" else "unregister"}",
        )
        if (shouldRegister) registerReceiver() else unregisterReceiver()
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            ScannerBroadcastPolicy.broadcastActions.forEach(::addAction)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Reader services live outside this APK, so NOT_EXPORTED would stop
            // real hardware scans. Sender verification is applied in onReceive
            // where Android exposes the initial sender identity (API 34+).
            activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
        record(ScannerDiagnosticLog.Event.RECEIVER_REGISTERED)
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        runCatching { activity.unregisterReceiver(receiver) }
        receiverRegistered = false
        record(ScannerDiagnosticLog.Event.RECEIVER_UNREGISTERED)
    }
}
