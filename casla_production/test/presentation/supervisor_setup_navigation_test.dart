import 'dart:async';

import 'package:casla_production/app/router/app_router.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/account/screens/supervisor_shift_setup_screen.dart';
import 'package:casla_production/features/supervisor/screens/s07_create_assignment_wizard_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

const _work = UserWorkContext(
  workId: 'setup-navigation-work',
  workName: 'Test work center',
  plant: '6711',
  workCenter: '67110021',
);
final _shift = SapShift(
  workCenter: '67110021',
  shiftId: 'DAY',
  validFrom: DateTime(2020),
  shiftName: 'Ca sáng',
  startTime: '06:00:00',
  endTime: '14:00:00',
  endDayOffset: 0,
  timeZone: 'UTC+7',
  validTo: null,
  isActive: 'A',
);

class _Shifts extends SapShiftController {
  _Shifts() : super(SapODataClient(baseUrl: 'https://example.invalid/'));

  @override
  Future<List<SapShift>> getShifts({
    required String workCenter,
    DateTime? onDate,
  }) async => [_shift];
}

// Keep the real local save, expiry and notification path. Only authentication
// and the remote shift catalogue are fixtures; no SAP request is sent.
class _SupervisorState extends AppState {
  Future<void>? lastSave;

  @override
  Future<void> completeSupervisorSetup({
    required UserWorkContext workContext,
    required SapShift shift,
    required DateTime businessDate,
  }) => lastSave = super.completeSupervisorSetup(
    workContext: workContext,
    shift: shift,
    businessDate: businessDate,
  );

  @override
  UserSession get currentSession => const UserSession(
    id: 'setup-navigation-user',
    maNv: 'manager-test',
    fullName: 'Quản lý thử nghiệm',
    teamName: 'Test',
    role: UserRole.supervisor,
    permissions: {Permission.viewTeamProduction, Permission.assignQuantity},
    toIds: ['setup-navigation-work'],
    workContexts: [_work],
  );

  @override
  bool get isLoggedIn => true;

  @override
  UserRole get currentRole => UserRole.supervisor;

  @override
  SapShiftController get shiftController => _Shifts();
}

const _namedWork = UserWorkContext(
  workId: '6711_CLXM1VLT_MAY1_KQ3',
  workName: 'Tổ May 1 - Máy KQ-3',
  plant: '6711',
  plantName: 'Nhà máy sản xuất Bình Minh',
  workCenter: '67110021',
  location: 'Khu xưởng may tầng 2 - Bình Minh',
);

class _LabelsState extends _SupervisorState {
  // Login returned the Bộ phận without its Work Center yet.
  UserWorkContext work = const UserWorkContext(
    workId: '6711_CLXM1VLT_MAY1_KQ3',
    workName: 'Tổ May 1 - Máy KQ-3',
    plant: '6711',
  );
  final refreshCompleter = Completer<bool>();
  int refreshCount = 0;

  @override
  UserSession get currentSession => UserSession(
    id: 'setup-navigation-user',
    maNv: 'manager-test',
    fullName: 'Quản lý thử nghiệm',
    teamName: 'Test',
    role: UserRole.supervisor,
    permissions: const {Permission.assignQuantity},
    refreshToken: 'test-refresh-token',
    workContexts: [work],
  );

  @override
  Future<bool> refreshWorkContexts() {
    refreshCount++;
    return refreshCompleter.future;
  }

  void receiveNames() {
    work = _namedWork;
    notifyListeners();
  }
}

void main() {
  useInMemoryDatabase();

  for (final refreshSucceeds in [true, false]) {
    testWidgets('setup shows work center and full location after refresh '
        '(success: $refreshSucceeds)', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => CaslaDatabase.instance.ready);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(connectivity, null));
      final appState = _LabelsState();
      final container = ProviderContainer(
        overrides: [appStateProvider.overrideWith((ref) => appState)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SupervisorShiftSetupScreen()),
        ),
      );
      await tester.pump();
      expect(appState.refreshCount, 1);
      if (refreshSucceeds) appState.receiveNames();
      appState.refreshCompleter.complete(refreshSucceeds);
      await tester.pumpAndSettle();
      final workshop = '${_namedWork.workCenter} (${_namedWork.location})';
      if (!refreshSucceeds) {
        expect(
          find.text('Tài khoản chưa được cấp Xưởng làm việc trên SAP.'),
          findsOneWidget,
        );
        // A later auth refresh must repaint this already mounted screen.
        appState.receiveNames();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(workshop).last);
        await tester.pumpAndSettle();
      }
      expect(find.text('Nhà máy'), findsNothing);
      expect(find.text(workshop), findsOneWidget);
      // A Xưởng with one Bộ phận selects it; the label is code - name only.
      final department = find.text(
        '${_namedWork.workId} - ${_namedWork.workName}',
      );
      expect(department, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(department);
      expect(paragraph.didExceedMaxLines, isFalse);
      final field = find.byType(DropdownButtonFormField<UserWorkContext>);
      final fieldRect = tester.getRect(field);
      final textRect = tester.getRect(department);
      expect(fieldRect.contains(textRect.topLeft), isTrue);
      expect(fieldRect.contains(textRect.bottomRight), isTrue);
      expect(appState.refreshCount, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => CaslaDatabase.instance.close());
      await tester.pump();
    });
  }

  for (final entry in ['login redirect', 'overview', 'assignment']) {
    testWidgets('Continue exits setup ($entry)', (tester) async {
      final reopened = entry != 'login redirect';
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => CaslaDatabase.instance.ready);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // The assignment form now listens to the PDA while it is visible.
      for (final name in ['casla/scanner/control', 'casla/scanner/events']) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (_) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          null,
        ),
      );
      final appState = _SupervisorState();
      final container = ProviderContainer(
        overrides: [appStateProvider.overrideWith((ref) => appState)],
      );
      final router = container.read(routerProvider);
      addTearDown(() {
        router.dispose();
        container.dispose();
      });
      if (reopened) {
        await tester.runAsync(
          () => appState.completeSupervisorSetup(
            workContext: _work,
            shift: _shift,
            businessDate: DateTime.now(),
          ),
        );
        router.go('/supervisor');
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      State? assignmentState;
      if (entry == 'assignment') {
        unawaited(router.push<void>('/supervisor/create_assignment'));
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        assignmentState = tester.state(
          find.byType(S07CreateAssignmentWizardScreen),
        );
      }
      if (reopened) {
        unawaited(router.push<void>('/supervisor-setup', extra: true));
      }
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(SupervisorShiftSetupScreen), findsOneWidget);
      await tester.ensureVisible(find.text('Tiếp tục'));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Tiếp tục'));
        await appState.lastSave;
      });
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(appState.needsSupervisorSetup, isFalse);
      expect(find.byType(SupervisorShiftSetupScreen), findsNothing);
      if (entry == 'assignment') {
        expect(
          tester.state(find.byType(S07CreateAssignmentWizardScreen)),
          same(assignmentState),
        );
      } else {
        expect(router.routeInformationProvider.value.uri.path, '/supervisor');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Drain native SQLite work started by the overview streams before the
      // fake-async test zone checks for pending database-lock timers. Several
      // overview watchers can queue behind one another, so let each finish.
      for (var drain = 0; drain < 5; drain++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.runAsync(() => CaslaDatabase.instance.close());
      await tester.pump();
    });
  }
}
