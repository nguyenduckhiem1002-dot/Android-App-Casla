// SAP no longer sends an explicit Role claim (see ZA_MOB_LoginResult) — the
// app derives it from the FuncID permission set login/refresh return. These
// tests exercise that derivation directly, against the same SapPermission /
// SapWorkContext shapes SapAuthController parses off the wire.
//
// Two roles reach the app now: the full supervisor set (write access, scoped
// by Work Context) and a bare PP_HIST_SELF/PP_HIST_TEAM account (read-only
// history — see zcl_pp_work_history), which needs no Work Context since
// getWorkHistory resolves scope server-side.

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
  group('SAP session authorization — supervisor', () {
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
      // VIEW_TEAM_PRODUCTION alone is also not a recognized history
      // permission, so this must still be rejected outright, not silently
      // downgraded to worker.
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('VIEW_TEAM_PRODUCTION')],
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

  group('SAP session authorization — worker (read-only history)', () {
    test('PP_HIST_SELF alone maps to worker, no work context required', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_HIST_SELF')],
        workContexts: const [],
      );

      expect(authorization.role, UserRole.worker);
      expect(
        authorization.permissions,
        contains(Permission.viewOwnProductionHistory),
      );
      expect(authorization.workContexts, isEmpty);
    });

    test('PP_HIST_TEAM alone also maps to worker', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_HIST_TEAM')],
        workContexts: const [],
      );

      expect(authorization.role, UserRole.worker);
      expect(
        authorization.permissions,
        contains(Permission.viewTeamProductionHistory),
      );
    });

    test('a worker session never picks up leftover supervisor claims', () {
      // Only VIEW_TEAM_PRODUCTION present, not the full supervisor set — a
      // worker account should not read as partially-supervisor.
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_HIST_SELF'), _perm('VIEW_TEAM_PRODUCTION')],
        workContexts: const [],
      );

      expect(authorization.role, UserRole.worker);
    });
  });

  group('SAP session authorization — rejected', () {
    test('an account with neither permission set is rejected', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('VIEW_OWN_PRODUCTION')],
          workContexts: const [],
        ),
        throwsException,
      );
    });

    test('no permissions at all is rejected', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: const [],
          workContexts: const [],
        ),
        throwsException,
      );
    });
  });
}
