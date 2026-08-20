// Core — Network reachability
// Spec: Section 4.7 (Có kết nối lại → worker gửi theo thứ tự nghiệp vụ)
//
// An interface rather than a direct `Connectivity()` call, for two reasons:
// `flutter test` has no platform channel to answer one, and the sync engine's
// retry behaviour is exactly the part worth testing offline.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

abstract class ConnectivityMonitor {
  /// Whether the device currently has a network interface up.
  ///
  /// This is a hint, never a guarantee: a PDA associated with the factory's
  /// Wi-Fi reports online even when the SAP host is unreachable. Callers must
  /// still handle a failed push — this only decides when it is worth trying.
  Future<bool> isOnline();

  /// Emits `true` when an interface comes up and `false` when the last one
  /// drops. Does not replay the current value on subscribe.
  Stream<bool> get onStatusChange;

  Future<void> dispose();
}

class PlatformConnectivityMonitor implements ConnectivityMonitor {
  final Connectivity _connectivity;
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  PlatformConnectivityMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) => _controller.add(_hasInterface(results)),
      // A failing platform channel must not take the sync engine down with it;
      // the engine's periodic poll still drains the queue.
      onError: (_) => _controller.add(true),
    );
  }

  @override
  Future<bool> isOnline() async {
    try {
      return _hasInterface(await _connectivity.checkConnectivity());
    } catch (_) {
      // Unknown beats "offline" here: refusing to try because the plugin
      // misbehaved would strand the queue indefinitely.
      return true;
    }
  }

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  static bool _hasInterface(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}
