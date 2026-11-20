// Main Application Entry
// Sets up Riverpod, Router, and Theme

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/casla_theme.dart';
import 'core/auth/session_manager.dart';
import 'core/config/app_config.dart';
import 'core/database/casla_database.dart';
import 'core/utils/device_info.dart';
import 'app/router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = FlutterError.presentError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    );
    return true;
  };
  ErrorWidget.builder = (details) => Material(
    color: Colors.white,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ứng dụng gặp lỗi không mong muốn. Vui lòng thử lại.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red),
            ),
            // A debug build names the fault on the device itself: its
            // Dart output does not always reach logcat on the floor.
            if (kDebugMode) ...[
              const SizedBox(height: 8),
              SelectableText(
                details.exceptionAsString(),
                textAlign: TextAlign.left,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.black87,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  // Warm the device-id cache so the synchronous `DeviceInfoHelper.deviceId`
  // getter returns a real identifier to every write path from the first record on.
  await DeviceInfoHelper.getDeviceId();

  // Open (and on first launch, create) the SQLite store before any widget
  // queries it, so the first frame renders against real data rather than an
  // empty snapshot that fills in a tick later.
  await CaslaDatabase.instance.ready;

  runApp(const ProviderScope(child: CaslaApp()));
}

final appStateProvider = ChangeNotifierProvider<AppState>((ref) => AppState());

class CaslaApp extends ConsumerStatefulWidget {
  const CaslaApp({super.key});

  @override
  ConsumerState<CaslaApp> createState() => _CaslaAppState();
}

class _CaslaAppState extends ConsumerState<CaslaApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // A PDA left on overnight comes back with yesterday's working date; every
    // return to the foreground re-checks it against the clock.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(appStateProvider).handleAppResumed(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: AppConfig.appName,
      theme: CaslaTheme.light,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
