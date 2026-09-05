package com.example.casla_production

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges CipherLab ReaderConfig broadcast output into Flutter without linking
 * the proprietary Reader SDK. ReaderConfig must be configured to broadcast
 * decoded data using PASS_DATA_2_APP (its documented app-output action).
 *
 * This receiver must remain exported because the Reader Service runs in a
 * separate CipherLab application. The exported broadcast is therefore treated
 * as untrusted input: Android 14+ verifies the originating package, only
 * ReaderConfig-processed Decoder_Data is accepted, and payload shape/size are
 * bounded before anything crosses into Dart.
 */
class CipherLabScannerBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler {
    companion object {
        private const val ACTION_PASS_DATA = "com.cipherlab.barcodebaseapi.PASS_DATA_2_APP"
        private const val EXTRA_DATA = "Decoder_Data"
        private const val EXTRA_CODE_TYPE = "Decoder_CodeType_String"
        private const val EVENT_CHANNEL = "casla/scanner/events"
        private const val CONTROL_CHANNEL = "casla/scanner/control"
    }

    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val controlChannel = MethodChannel(messenger, CONTROL_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null
    private var activityStarted = false
    private var receiverRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_PASS_DATA) return

            val senderPackage = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                sentFromPackage
            } else {
                null
            }
            if (!CipherLabBroadcastPolicy.acceptsSender(Build.VERSION.SDK_INT, senderPackage)) {
                return
            }

            // Deliberately do not fall back to Original_Decoder_Data. CipherLab
            // documents Decoder_Data as the value after ReaderConfig processing;
            // accepting the original value would bypass those device-side rules.
            val sanitized = CipherLabBroadcastPolicy.sanitizeDecodedData(
                intent.extras?.get(EXTRA_DATA),
            ) ?: return

            eventSink?.success(
                mapOf(
                    "rawValue" to sanitized,
                    "symbology" to CipherLabBroadcastPolicy.sanitizeSymbology(
                        intent.extras?.get(EXTRA_CODE_TYPE),
                    ),
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
            "isAvailable" -> result.success(isCipherLabDevice())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        updateRegistration()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
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

    private fun updateRegistration() {
        val shouldRegister = activityStarted && eventSink != null && isCipherLabDevice()
        if (shouldRegister) registerReceiver() else unregisterReceiver()
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_PASS_DATA)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Reader Service is external to this APK, so NOT_EXPORTED would stop
            // real hardware scans. Sender verification is applied in onReceive
            // where Android exposes the initial sender identity (API 34+).
            activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        runCatching { activity.unregisterReceiver(receiver) }
        receiverRegistered = false
    }

    private fun isCipherLabDevice(): Boolean {
        return Build.MANUFACTURER.contains("cipherlab", ignoreCase = true) ||
            Build.BRAND.contains("cipherlab", ignoreCase = true) ||
            Build.MODEL.contains("RS38", ignoreCase = true)
    }
}
