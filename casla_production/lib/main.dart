// Main Application Entry
// Sets up Riverpod, Router, and Theme

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/casla_theme.dart';
import 'core/auth/session_manager.dart';
import 'core/config/app_config.dart';
import 'core/database/casla_database.dart';
import 'app/router/app_router.dart';

void main() {
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
        child: Text(
          'Ứng dụng gặp lỗi không mong muốn. Vui lòng thử lại.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red),
        ),
      ),
    ),
  );
  // Initialize the local data store before widgets request it.
  CaslaDatabase.instance;

  runApp(const ProviderScope(child: CaslaApp()));
}

final appStateProvider = ChangeNotifierProvider<AppState>((ref) => AppState());

class CaslaApp extends ConsumerWidget {
  const CaslaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: AppConfig.appName,
      theme: CaslaTheme.light,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
