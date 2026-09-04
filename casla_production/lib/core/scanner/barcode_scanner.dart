import 'barcode_scan_event.dart';

abstract interface class BarcodeScanner {
  Future<bool> isAvailable();

  Stream<BarcodeScanEvent> get scans;
}
