import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/work_context_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const session = UserSession(
    id: 'session',
    maNv: 'MGR',
    fullName: 'Manager',
    teamName: 'PP',
    role: UserRole.supervisor,
    permissions: {Permission.assignQuantity},
    workContexts: [
      UserWorkContext(
        workId: 'DEMO_6711_67110021',
        workName: 'Demo',
        plant: '6711',
        workCenter: '67110021',
      ),
      UserWorkContext(
        workId: 'DEMO_6731_67310035',
        workName: 'Other',
        plant: '6731',
        workCenter: '67310035',
      ),
    ],
  );

  test('matches exact Plant and Work Center from the operation QR', () {
    expect(
      resolveWorkContext(
        session: session,
        plant: '6711',
        workCenter: '67110021',
      )?.workId,
      'DEMO_6711_67110021',
    );
  });

  test('does not guess when QR has no context or it is not authorized', () {
    expect(
      resolveWorkContext(session: session, plant: '', workCenter: ''),
      isNull,
    );
    expect(
      resolveWorkContext(
        session: session,
        plant: '9999',
        workCenter: '99990001',
      ),
      isNull,
    );
  });

  group('assignmentWorkScope', () {
    // Two departments of one work center registered under different Plants,
    // as on the account that was refused on the TC22.
    const sewing = UserWorkContext(
      workId: 'XM1.MM',
      workName: 'MAY MIỆNG-XM1',
      plant: '6711',
      workCenter: 'CL100076',
    );
    const programmed = UserWorkContext(
      workId: 'MAY LẬP TRÌNH_ XM1',
      workName: 'MAY LẬP TRÌNH_ XM1',
      plant: '6712',
      workCenter: 'CL100076',
    );
    const otherWorkshop = UserWorkContext(
      workId: 'XM2.001',
      workName: 'Xưởng 2',
      plant: '6712',
      workCenter: 'CL100077',
    );
    const twoDepartments = UserSession(
      id: 'session',
      maNv: 'MGR',
      fullName: 'Manager',
      teamName: 'PP',
      role: UserRole.supervisor,
      permissions: {Permission.assignQuantity},
      workContexts: [sewing, programmed, otherWorkshop],
    );

    test('a label with no exact context uses the selected department', () {
      final scope = assignmentWorkScope(selected: sewing, scanned: null);
      expect(scope.blocked, isFalse);
      expect(scope.context?.workId, 'XM1.MM');
    });

    test('the selected department itself is sent as it is', () {
      final scope = assignmentWorkScope(selected: sewing, scanned: sewing);
      expect(scope.blocked, isFalse);
      expect(scope.context?.workId, 'XM1.MM');
    });

    test('a sibling department of the same work center does not block, and '
        'the selected department is the one sent', () {
      // The label's Plant matches only the department that is not selected.
      final scanned = resolveWorkContext(
        session: twoDepartments,
        plant: '6712',
        workCenter: 'CL100076',
      );
      expect(scanned?.workId, 'MAY LẬP TRÌNH_ XM1');

      final scope = assignmentWorkScope(selected: sewing, scanned: scanned);
      expect(scope.blocked, isFalse);
      expect(scope.context?.workId, 'XM1.MM');
    });

    test('work center is compared without case or padding', () {
      const padded = UserWorkContext(
        workId: 'XM1.X',
        workName: 'X',
        plant: '6712',
        workCenter: ' cl100076 ',
      );
      final scope = assignmentWorkScope(selected: sewing, scanned: padded);
      expect(scope.blocked, isFalse);
      expect(scope.context?.workId, 'XM1.MM');
    });

    test('another work center is refused', () {
      final scope = assignmentWorkScope(
        selected: sewing,
        scanned: otherWorkshop,
      );
      expect(scope.blocked, isTrue);
      expect(scope.context, isNull);
    });

    test('a selection with no work center cannot vouch for a sibling', () {
      const bare = UserWorkContext(workId: 'BARE', workName: 'Bare');
      final scope = assignmentWorkScope(selected: bare, scanned: programmed);
      expect(scope.blocked, isTrue);
    });

    test('no selection with an exact label context is refused', () {
      final scope = assignmentWorkScope(selected: null, scanned: programmed);
      expect(scope.blocked, isTrue);
      expect(scope.context, isNull);
    });

    test('no selection and no label context sends no work id', () {
      final scope = assignmentWorkScope(selected: null, scanned: null);
      expect(scope.blocked, isFalse);
      expect(scope.context, isNull);
    });
  });
}
