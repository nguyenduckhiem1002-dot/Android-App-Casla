import 'dart:async';

import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/data/sap/sap_auth_controller.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/account/screens/mandatory_password_change_screen.dart';
import 'package:casla_production/features/account/widgets/change_password_dialog.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/database_test_harness.dart';

class _Session extends AppState {
  bool loggedIn = true;
  int logouts = 0;

  @override
  UserSession? get currentSession => loggedIn
      ? const UserSession(
          id: 'mandatory-test',
          maNv: 'test',
          fullName: 'Test',
          teamName: '',
          role: UserRole.supervisor,
          permissions: {},
          toIds: [],
          accessToken: 'test-token',
          passwordChangeRequired: true,
        )
      : null;

  @override
  Future<void> logout() async {
    logouts++;
    loggedIn = false;
    notifyListeners();
  }
}

class _Auth extends SapAuthController {
  _Auth() : super(SapODataClient(baseUrl: 'https://example.invalid/'));
  Completer<void> response = Completer<void>();
  int calls = 0;

  @override
  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
    required String deviceId,
  }) {
    calls++;
    return response.future;
  }
}

void main() {
  useInMemoryDatabase();

  for (final signOut in [false, true]) {
    testWidgets('mandatory change exits to login (signOut: $signOut)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _Session();
      final auth = _Auth();
      final router = GoRouter(
        initialLocation: '/password-change-required',
        refreshListenable: session,
        redirect: (_, state) =>
            !session.loggedIn && state.matchedLocation != '/login'
            ? '/login'
            : null,
        routes: [
          GoRoute(
            path: '/password-change-required',
            builder: (_, _) => const MandatoryPasswordChangeScreen(),
          ),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Scaffold(body: Text('LOGIN DESTINATION')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith((_) => session),
            passwordChangeControllerProvider.overrideWithValue(auth),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      // System Back must not bypass the mandatory password gate.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3));
      if (signOut) {
        await tester.tap(find.text('Đăng xuất'));
        await tester.pumpAndSettle();
        expect(session.logouts, 1);
        expect(auth.calls, 0);
        expect(find.text('LOGIN DESTINATION'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        return;
      }
      await tester.enterText(find.byType(TextField).at(0), 'Old-test-123');
      await tester.enterText(find.byType(TextField).at(1), 'New-test-123');
      await tester.enterText(find.byType(TextField).at(2), 'New-test-123');
      await tester.pump();
      await tester.ensureVisible(find.text('Xác nhận đổi mật khẩu'));
      await tester.tap(find.text('Xác nhận đổi mật khẩu'));
      await tester.pump();
      // Exercise a rejected request before retrying successfully.
      expect(auth.calls, 1);
      auth.response.completeError(Exception('Mật khẩu hiện tại không đúng'));
      await tester.pumpAndSettle();
      expect(find.text('Mật khẩu hiện tại không đúng'), findsOneWidget);
      expect(session.logouts, 0);
      auth.response = Completer<void>();
      await tester.tap(find.text('Xác nhận đổi mật khẩu'));
      await tester.pump();
      auth.response.complete();
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(find.text('Đổi mật khẩu thành công'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Đổi mật khẩu thành công'), findsOneWidget);
      await tester.tap(find.text('Đăng nhập lại'));
      await tester.pumpAndSettle();
      expect(session.logouts, 1);
      expect(find.text('LOGIN DESTINATION'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
