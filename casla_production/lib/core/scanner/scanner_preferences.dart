import '../database/casla_database.dart';

/// How a device should capture barcodes.
///
/// [auto] is the shipping default and needs no setup. The two explicit modes
/// exist because field technicians commissioning a new handset model need a way
/// to force the right behaviour without waiting for an app release — which is
/// exactly what the old hardcoded manufacturer check made impossible.
enum ScannerMode {
  auto,
  hardware,
  camera;

  static ScannerMode fromStorage(String? value) => switch (value?.trim()) {
    'hardware' => ScannerMode.hardware,
    'camera' => ScannerMode.camera,
    _ => ScannerMode.auto,
  };

  String get storageValue => switch (this) {
    ScannerMode.auto => 'auto',
    ScannerMode.hardware => 'hardware',
    ScannerMode.camera => 'camera',
  };

  String get label => switch (this) {
    ScannerMode.auto => 'Tự động',
    ScannerMode.hardware => 'Luôn dùng đầu đọc',
    ScannerMode.camera => 'Luôn dùng camera',
  };

  String get description => switch (this) {
    ScannerMode.auto =>
      'Ưu tiên đầu đọc tích hợp, tự chuyển sang camera nếu máy không có đầu đọc.',
    ScannerMode.hardware =>
      'Chỉ chờ mã từ đầu đọc, không bật camera. Dùng khi máy có đầu đọc nhưng app chưa nhận ra.',
    ScannerMode.camera =>
      'Luôn quét bằng camera. Dùng cho điện thoại thường hoặc khi đầu đọc hỏng.',
  };
}

/// Device-local scanner settings. Not synced to SAP: these describe the
/// handset in the operator's hand, not the business transaction.
abstract interface class ScannerPreferences {
  Future<ScannerMode> readMode();

  Future<void> writeMode(ScannerMode mode);

  /// Whether a hardware scan has ever been received on this device.
  ///
  /// A keyboard-wedge reader is invisible until it first fires, so this is how
  /// the app remembers to open straight into hardware mode from then on
  /// instead of flashing the camera at the operator every time.
  Future<bool> wasHardwareScanSeen();

  Future<void> rememberHardwareScanSeen();
}

class DatabaseScannerPreferences implements ScannerPreferences {
  static const String modeKey = 'scanner_mode';
  static const String hardwareSeenKey = 'scanner_hardware_seen';

  final CaslaDatabase _database;

  DatabaseScannerPreferences({CaslaDatabase? database})
    : _database = database ?? CaslaDatabase.instance;

  @override
  Future<ScannerMode> readMode() async {
    try {
      return ScannerMode.fromStorage(await _database.getLocalSetting(modeKey));
    } catch (_) {
      // A settings read must never be the reason a scan screen fails to open.
      return ScannerMode.auto;
    }
  }

  @override
  Future<void> writeMode(ScannerMode mode) async {
    try {
      await _database.setLocalSetting(modeKey, mode.storageValue);
    } catch (_) {
      // Preference persistence is a convenience, not a business write.
    }
  }

  @override
  Future<bool> wasHardwareScanSeen() async {
    try {
      return await _database.getLocalSetting(hardwareSeenKey) == 'true';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> rememberHardwareScanSeen() async {
    try {
      await _database.setLocalSetting(hardwareSeenKey, 'true');
    } catch (_) {
      // Same reasoning as writeMode.
    }
  }
}

/// In-memory implementation for tests and for the widget preview path.
class InMemoryScannerPreferences implements ScannerPreferences {
  ScannerMode mode;
  bool hardwareSeen;

  InMemoryScannerPreferences({
    this.mode = ScannerMode.auto,
    this.hardwareSeen = false,
  });

  @override
  Future<ScannerMode> readMode() async => mode;

  @override
  Future<void> writeMode(ScannerMode value) async => mode = value;

  @override
  Future<bool> wasHardwareScanSeen() async => hardwareSeen;

  @override
  Future<void> rememberHardwareScanSeen() async => hardwareSeen = true;
}
