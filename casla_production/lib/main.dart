// Main Application Entry
// Sets up Riverpod, Router, and Theme

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/casla_theme.dart';
import 'core/database/casla_database.dart';
import 'core/auth/session_manager.dart';
import 'domain/entities/entities.dart';
import 'domain/entities/enums.dart';

import 'features/authentication/screens/scan_login_screen.dart';
import 'features/shared/screens/worker_shell.dart';
import 'features/shared/screens/supervisor_shell.dart';
import 'features/worker/screens/record_production_screen.dart';
import 'features/supervisor/screens/create_assignment_screen.dart';
import 'features/supervisor/screens/assignment_detail_screen.dart';
import 'features/supervisor/screens/recall_screen.dart';
import 'features/sync/screens/sync_status_screen.dart';

import 'app/router/app_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Init DB
  CaslaDatabase.instance;
  
  runApp(
    const ProviderScope(
      child: CaslaApp(),
    ),
  );
}

// Simple AppState provider for MVP
final appStateProvider = ChangeNotifierProvider<AppState>((ref) => AppState());

class CaslaApp extends ConsumerWidget {
  const CaslaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Casla Group',
      theme: CaslaTheme.light,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
