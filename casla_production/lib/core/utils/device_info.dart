// Core — Device Info Helper
// Provides device ID for audit log entries (Spec 10)

import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class DeviceInfoHelper {
  DeviceInfoHelper._();

  static String? _cachedDeviceId;

  /// Get a stable device identifier for audit logs
  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;

    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        _cachedDeviceId =
            'PDA-${android.model.replaceAll(' ', '-')}-${android.id.substring(0, 4)}';
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        _cachedDeviceId =
            'IOS-${ios.model}-${ios.identifierForVendor?.substring(0, 4) ?? 'XXXX'}';
      } else {
        _cachedDeviceId = 'DEVICE-${Platform.operatingSystem.toUpperCase()}';
      }
    } catch (_) {
      _cachedDeviceId = 'DEVICE-UNKNOWN';
    }

    return _cachedDeviceId!;
  }

  /// Get cached device ID (sync, after first async call)
  static String get deviceId => _cachedDeviceId ?? 'DEVICE-UNKNOWN';
}
