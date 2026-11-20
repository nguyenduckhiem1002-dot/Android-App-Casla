import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/features/supervisor/screens/s10_confirm_scan_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

/// Six workers with work left in the shift: more than four, so the list
/// shows its scrollbar thumb.
final _workers = [
  for (var index = 1; index <= 6; index++)
    {
      'id': 'worker-$index',
      'ma_nv': 'CL40000$index',
      'ten': 'Công nhân $index',
      'bo_phan': 'MAY MIỆNG-XM2',
    },
];

class _Database implements CaslaDatabase {
  @override
  Stream<void> get remotePostings => const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> getWorkersForManualSelection(
    List<String> teamIds, {
    DateTime? now,
  }) async => _workers;

  @override
  Future<Set<String>> getAssignedWorkerIdsForShift({
    required List<String> teamIds,
    required String businessDate,
    required String shiftId,
  }) async => {for (final worker in _workers) worker['id']!};

  @override
  Future<List<Map<String, dynamic>>> getTeamsForScope(
    List<String> teamIds,
  ) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No SAP history (read offline): the list is the workers assigned on the
/// device.
class _State extends ChangeNotifier implements AppState {
  @override
  final _Database db = _Database();
  @override
  UserSession? get currentSession => null;
  @override
  UserWorkContext? get activeWorkContext => null;
  @override
  SapShift get activeShift => SapShift.fromJson({'ShiftID': '1'});
  @override
  DateTime get activeBusinessDate => DateTime(2026, 11, 19);
  @override
  int get sessionGeneration => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // The screen's barcode listener keeps its scanner settings in SQLite.
  useInMemoryDatabase();
  setUp(CaslaDatabase.resetForTesting);

  testWidgets('the worker list scrolls on its own beside the other tabs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => _State())],
        child: MaterialApp(
          // The supervisor shell keeps every tab alive in one route, so
          // another tab's list shares the route's PrimaryScrollController.
          home: Scaffold(
            body: IndexedStack(
              index: 1,
              children: [
                ListView(children: const [Text('Tổng quan')]),
                const S10ConfirmScanScreen(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Công nhân 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The thumb follows the list as it scrolls.
    await tester.drag(find.text('Công nhân 1'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
