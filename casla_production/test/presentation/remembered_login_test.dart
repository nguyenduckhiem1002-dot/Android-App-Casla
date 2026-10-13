import 'dart:async';

import 'package:casla_production/core/auth/remembered_login.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/authentication/screens/s02b_account_login_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/database_test_harness.dart';

class _LoginState extends AppState {
  final response = Completer<bool>();
  int calls = 0;

  @override
  UserSession get currentSession => const UserSession(
    id: 'saved-account',
    maNv: 'employee-code',
    fullName: 'Test',
    teamName: '',
    role: UserRole.worker,
    permissions: {},
    toIds: [],
  );

  @override
  Future<bool> loginByCredentials(String username, String password) {
    calls++;
    return response.future;
  }
}

void main() {
  useInMemoryDatabase();
  late RememberedLoginStore store;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    store = RememberedLoginStore(const FlutterSecureStorage());
    CaslaDatabase.resetForTesting();
    await CaslaDatabase.instance.ready;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    String? initial,
    _LoginState? state,
  }) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => S02bAccountLoginScreen(initialUsername: initial),
        ),
        GoRoute(
          path: '/history',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rememberedLoginProvider.overrideWithValue(store),
          appStateProvider.overrideWith((_) => state ?? _LoginState()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await flush(tester);
  }

  TextField field(WidgetTester tester, int index) =>
      tester.widget<TextField>(find.byType(TextField).at(index));

  testWidgets(
    'restores both fields, obscures password, clears it on account edit',
    (tester) async {
      await store.save(
        const RememberedLogin(username: 'saved-user', password: 'Fixture-123'),
      );
      await mount(tester);
      expect(field(tester, 0).controller!.text, 'saved-user');
      expect(field(tester, 1).controller!.text, 'Fixture-123');
      expect(field(tester, 1).obscureText, isTrue);
      await tester.enterText(find.byType(TextField).first, 'other-user');
      expect(field(tester, 1).controller!.text, isEmpty);
    },
  );

  testWidgets(
    'initial account never receives a different saved account password',
    (tester) async {
      await store.save(
        const RememberedLogin(username: 'saved-user', password: 'Fixture-123'),
      );
      await mount(tester, initial: 'other-user');
      expect(field(tester, 0).controller!.text, 'other-user');
      expect(field(tester, 1).controller!.text, isEmpty);
    },
  );

  testWidgets(
    'existing username-only preference restores without enabling password save',
    (tester) async {
      await tester.runAsync(
        () => CaslaDatabase.instance.setLocalSetting(
          'remembered_login_username',
          'legacy',
        ),
      );
      await mount(tester);
      expect(field(tester, 0).controller!.text, 'legacy');
      expect(field(tester, 1).controller!.text, isEmpty);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
    },
  );

  testWidgets('unchecking forgets both credentials immediately', (
    tester,
  ) async {
    await store.save(
      const RememberedLogin(username: 'saved-user', password: 'Fixture-123'),
    );
    await mount(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await flush(tester);
    expect(await store.read(), isNull);
    expect(field(tester, 1).controller!.text, isEmpty);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
  });

  for (final accepted in [true, false]) {
    testWidgets('saves only accepted login: $accepted, prevents double submit', (
      tester,
    ) async {
      final state = _LoginState();
      await mount(tester, state: state);
      await tester.enterText(find.byType(TextField).first, 'new-user');
      await tester.enterText(find.byType(TextField).last, ' Fixture-New-123 ');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Đăng nhập'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Đăng nhập'));
      expect(state.calls, 1);
      expect(await store.read(), isNull);
      state.response.complete(accepted);
      await flush(tester);
      final login = await store.read();
      if (accepted) {
        expect(login?.username, 'new-user');
        expect(login?.password, ' Fixture-New-123 ');
        expect(login?.accountId, 'saved-account');
        // A new service instance, as on reopening the app, reads the same pair.
        final reopened = RememberedLoginStore(const FlutterSecureStorage());
        expect((await reopened.read())?.password, ' Fixture-New-123 ');
      } else {
        expect(login, isNull);
      }
      expect(
        await tester.runAsync(
          () => CaslaDatabase.instance.getLocalSetting(
            'remembered_login_password',
          ),
        ),
        isNull,
      );
    });
  }

  test('password change updates remembered account only', () async {
    await store.save(
      const RememberedLogin(
        username: 'login-alias',
        password: 'old-fixture',
        accountId: 'account-a',
      ),
    );
    await store.updatePasswordForAccount('account-b', 'wrong-fixture');
    expect((await store.read())?.password, 'old-fixture');
    await store.updatePasswordForAccount('account-a', 'new-fixture');
    expect((await store.read())?.password, 'new-fixture');
    expect((await store.read())?.username, 'login-alias');
    await store.forget();
    await store.updatePasswordForAccount('account-a', 'must-not-save');
    expect(await store.read(), isNull);
  });

  test('forget is ordered after an in-flight save', () async {
    final saving = store.save(
      const RememberedLogin(username: 'user', password: 'fixture'),
    );
    final forgetting = store.forget();
    await Future.wait([saving, forgetting]);
    expect(await store.read(), isNull);
  });
}
