// SAP no longer sends an explicit Role claim (see ZA_MOB_LoginResult) — the
// app derives it from the FuncID permission set login/refresh return. These
// tests exercise that derivation directly, against the same SapPermission /
// SapWorkContext shapes SapAuthController parses off the wire.

import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_auth_controller.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';

SapPermission _perm(String funcId) =>
    SapPermission(funcId: funcId, funcName: funcId, appModule: 'PP');

const _workContext = SapWorkContext(
  workId: 'work-1',
  workName: 'Tổ Cắt 1',
  plant: '1000',
  workCenter: 'WC-01',
  boPhan: 'Xưởng May',
  location: 'Nhà máy 1',
);

void main() {
  group('SAP session authorization', () {
    test('a full supervisor permission set maps to supervisor', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [
          _perm('VIEW_TEAM_PRODUCTION'),
          _perm('ASSIGN_QUANTITY'),
          _perm('RECALL_ASSIGNMENT'),
        ],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.supervisor);
      expect(
        authorization.permissions,
        containsAll([Permission.viewTeamProduction, Permission.assignQuantity]),
      );
      expect(authorization.workContexts, [_workContext]);
    });

    test('does not promote an account missing part of the supervisor set', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('VIEW_TEAM_PRODUCTION')],
          workContexts: const [_workContext],
        ),
        throwsException,
      );
    });

    test('rejects a worker-only permission set entirely', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('VIEW_OWN_PRODUCTION')],
          workContexts: const [_workContext],
        ),
        throwsException,
      );
    });

    test('requires at least one work context even with full permissions', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [
            _perm('VIEW_TEAM_PRODUCTION'),
            _perm('ASSIGN_QUANTITY'),
            _perm('RECALL_ASSIGNMENT'),
          ],
          workContexts: const [],
        ),
        throwsException,
      );
    });
  });
}
