package com.example.casla_production

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.view.KeyEvent

class MainActivity : FlutterActivity() {
    private var scannerBridge: PdaScannerBridge? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        scannerBridge?.noteKeyEvent(event)
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        scannerBridge = PdaScannerBridge(
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
