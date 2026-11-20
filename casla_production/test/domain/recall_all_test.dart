// "Thu hồi không mật khẩu" on the worker list: every order/operation the
// selected worker still holds is recalled in full, one password-less recall
// per group, and a refusal on one order must not hide what happened to the
// others.

import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:casla_production/domain/policies/recall_all.dart';
import 'package:casla_production/domain/repositories/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment _lot(
  String id, {
  required String operation,
  double assigned = 100,
  double completed = 0,
  double recalled = 0,
  String position = '',
  int at = 1,
  double? seat,
  AssignmentStatus status = AssignmentStatus.open,
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'CL400111',
  workerName: 'Công nhân',
  teamId: 'WORK-A',
  orderId: 'order-$operation',
  orderCode: '010140000374',
  productionOrder: '010140000374',
  operation: operation,
  productCode: 'SP01',
  productName: 'Sản phẩm',
  uom: 'CHC',
  assignedQuantity: assigned,
  completedQuantity: completed,
  recalledQuantity: recalled,
  businessDate: '2026-11-19',
  shiftId: '1',
  status: status,
  createdBy: 'supervisor',
  idempotencyKey: id,
  syncStatus: SyncStatus.synced,
  createdAtUtc: at,
  positionId: position,
  seatRemaining: seat,
);

class _Call {
  final String assignmentId;
  final double quantity;
  final String? workerPassword;
  final bool withoutWorkerPassword;
  final double? seatCeiling;
  const _Call(
    this.assignmentId,
    this.quantity,
    this.workerPassword,
    this.withoutWorkerPassword,
    this.seatCeiling,
  );
}

class _Recall implements RecallRepository {
  final calls = <_Call>[];

  /// SAP's answer per allocation id; absent means synced.
  final Map<String, MutationReceipt> answers = {};
  final Set<String> throwsFor = {};

  @override
  Future<MutationReceipt> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? workerPassword,
    bool withoutWorkerPassword = false,
    double? seatCeiling,
  }) async {
    calls.add(
      _Call(
        assignmentId,
        quantity,
        workerPassword,
        withoutWorkerPassword,
        seatCeiling,
      ),
    );
    if (throwsFor.contains(assignmentId)) {
      throw Exception('Phân công đã đóng hoặc bị thu hồi.');
    }
    return answers[assignmentId] ??
        MutationReceipt(id: assignmentId, state: MutationDeliveryState.synced);
  }

  @override
  Future<double> getRecalledQuantity(String assignmentId) async => 0;
}

Future<List<RecallAllOutcome>> _run(
  _Recall repo,
  List<RecallAllLine> lines, {
  bool Function()? canContinue,
}) => recallAllWithoutPassword(
  recallRepo: repo,
  lines: lines,
  reasonCode: RecallReason.notFinished.code,
  businessDate: '2026-11-19',
  shiftId: '1',
  createdBy: 'MNV001',
  canContinue: canContinue,
);

void main() {
  group('planRecallAll', () {
    test('one recall per order/operation, each for all that is left', () {
      final lines = planRecallAll([
        _lot('a', operation: '0020', assigned: 1800),
        _lot('b', operation: '0040', assigned: 500, completed: 120),
        _lot('c', operation: '0060', assigned: 300, recalled: 50),
      ]);

      expect(
        [for (final line in lines) '${line.target.id}:${line.quantity}'],
        ['a:1800.0', 'b:380.0', 'c:250.0'],
      );
    });

    test('lots of one seat are one recall, booked on the oldest open '
        'lot', () {
      final older = _lot('older', operation: '0020', assigned: 100, at: 1);
      final newer = _lot('newer', operation: '0020', assigned: 333, at: 2);

      final line = planRecallAll([newer, older]).single;

      expect(line.target.id, 'older');
      expect(line.quantity, 433);
      // Sized by the pile, not by the 100 the booked lot holds on its own.
      expect(line.seatCeiling, 433);
    });

    test('SAP\'s seat balance wins over the lots\' own figures', () {
      // 100 given and over-confirmed, then 700 more: SAP leaves 200.
      final spent = _lot(
        'spent',
        operation: '0020',
        assigned: 100,
        completed: 100,
        at: 1,
        seat: 200,
      );
      final open = _lot(
        'open',
        operation: '0020',
        assigned: 700,
        at: 2,
        seat: 200,
      );

      final line = planRecallAll([spent, open]).single;

      expect(line.quantity, 200);
      expect(line.target.id, 'open');
      expect(line.seatCeiling, 200);
    });

    test('a different position is its own recall', () {
      final lines = planRecallAll([
        _lot('blank', operation: '0020', assigned: 100),
        _lot('tr1', operation: '0020', assigned: 800, position: 'TR1'),
      ]);

      expect(lines.map((line) => line.target.id), ['blank', 'tr1']);
      // A single lot with no settled seat keeps its own ceiling.
      expect(lines.first.seatCeiling, isNull);
    });

    test('orders with nothing left or already closed are left out', () {
      final lines = planRecallAll([
        _lot('done', operation: '0020', assigned: 100, completed: 100),
        _lot('settled', operation: '0040', assigned: 100, seat: 0),
        _lot(
          'recalled',
          operation: '0060',
          assigned: 100,
          status: AssignmentStatus.recalled,
        ),
        _lot('open', operation: '0080', assigned: 40),
      ]);

      expect(lines.single.target.id, 'open');
    });

    test('nothing to recall gives an empty plan', () {
      expect(planRecallAll(const <Assignment>[]), isEmpty);
    });
  });

  group('recallAllWithoutPassword', () {
    final lots = [
      _lot('a', operation: '0020', assigned: 1800),
      _lot('b', operation: '0040', assigned: 500),
      _lot('c', operation: '0060', assigned: 300),
    ];

    test('sends every order as a password-less recall', () async {
      final repo = _Recall();

      final outcomes = await _run(repo, planRecallAll(lots));

      expect(repo.calls.map((call) => call.assignmentId), ['a', 'b', 'c']);
      expect(repo.calls.map((call) => call.quantity), [1800, 500, 300]);
      expect(repo.calls.every((call) => call.withoutWorkerPassword), isTrue);
      expect(repo.calls.every((call) => call.workerPassword == null), isTrue);
      expect(outcomes.every((outcome) => outcome.synced), isTrue);
    });

    test('a refusal about one order does not stop the others', () async {
      final repo = _Recall()
        ..answers['b'] = const MutationReceipt(
          id: 'b',
          state: MutationDeliveryState.discarded,
          code: 'RECALL_QUANTITY_EXCEEDED',
          message: 'Không được thu hồi vượt mức. Tối đa thu hồi được 200 CHC.',
        );

      final outcomes = await _run(repo, planRecallAll(lots));

      expect(repo.calls.map((call) => call.assignmentId), ['a', 'b', 'c']);
      expect(outcomes.map((outcome) => outcome.saved), [true, false, true]);
      expect(outcomes[1].skipped, isFalse);
      expect(outcomes[1].receipt!.code, 'RECALL_QUANTITY_EXCEEDED');
    });

    test('a refusal about the account stops the run', () async {
      final repo = _Recall()
        ..answers['a'] = const MutationReceipt(
          id: 'a',
          state: MutationDeliveryState.discarded,
          code: 'RECALL_NOPASS_NOT_ALLOWED',
        );

      final outcomes = await _run(repo, planRecallAll(lots));

      // The two others would be refused for the same reason: not sent.
      expect(repo.calls.map((call) => call.assignmentId), ['a']);
      expect(outcomes.map((outcome) => outcome.skipped), [false, true, true]);
      expect(outcomes.any((outcome) => outcome.saved), isFalse);
    });

    test('a recall the device refuses to store is reported, the rest '
        'go on', () async {
      final repo = _Recall()..throwsFor.add('a');

      final outcomes = await _run(repo, planRecallAll(lots));

      expect(outcomes.first.error, isA<Exception>());
      expect(outcomes.first.saved, isFalse);
      expect(outcomes.skip(1).every((outcome) => outcome.synced), isTrue);
    });

    test('a queued recall counts as saved, not as synced', () async {
      final repo = _Recall()
        ..answers['a'] = const MutationReceipt(
          id: 'a',
          state: MutationDeliveryState.queued,
          code: 'ERR_NETWORK',
        );

      final outcomes = await _run(repo, planRecallAll(lots));

      expect(outcomes.first.saved, isTrue);
      expect(outcomes.first.synced, isFalse);
    });

    test('a session that changed mid-run sends nothing further', () async {
      final repo = _Recall();
      var allowed = 1;

      final outcomes = await _run(
        repo,
        planRecallAll(lots),
        canContinue: () => allowed-- > 0,
      );

      expect(repo.calls.map((call) => call.assignmentId), ['a']);
      expect(outcomes.map((outcome) => outcome.skipped), [false, true, true]);
    });
  });
}
