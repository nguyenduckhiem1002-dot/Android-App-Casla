package com.example.casla_production

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var scannerBridge: CipherLabScannerBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        scannerBridge = CipherLabScannerBridge(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onStart() {
        super.onStart()
        scannerBridge?.onStart()
    }

    override fun onStop() {
        scannerBridge?.onStop()
        super.onStop()
    }

    override fun onDestroy() {
        scannerBridge?.dispose()
        scannerBridge = null
        super.onDestroy()
    }
}
