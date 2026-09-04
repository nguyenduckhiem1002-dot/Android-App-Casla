// SAP sends no explicit Role claim (see ZA_MOB_LoginResult) — the app derives
// it from the FuncID permission set login/refresh return. These tests exercise
// that derivation directly, against the same SapPermission / SapWorkContext
// shapes SapAuthController parses off the wire.
//
// The vocabulary here is only what the backend actually issues:
// PP_INITIAL_ASSIGN (the sole FuncID zbp_r_pp_opalloc gates a write on),
// PP_HIST_SELF and PP_HIST_TEAM (read scopes in zcl_pp_work_history). Nothing
// else SAP returns may influence the role.

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
    test('PP_INITIAL_ASSIGN maps to supervisor', () {
      // The real shape of a manager account: one write FuncID plus both
      // history scopes.
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [
          _perm('PP_HIST_SELF'),
          _perm('PP_HIST_TEAM'),
          _perm('PP_INITIAL_ASSIGN'),
        ],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.supervisor);
      expect(authorization.workContexts, [_workContext]);
    });

    test('a supervisor reaches every screen the router gates', () {
      // The router's redirect asks for these by name. None of them is a SAP
      // FuncID, so they have to come from the role — if this regresses, a
      // manager lands on the shell and every sub-route bounces back to it.
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_INITIAL_ASSIGN')],
        workContexts: const [_workContext],
      );

      expect(
        authorization.permissions,
        containsAll([
          Permission.assignQuantity,
          Permission.recallAssignment,
          Permission.viewTeamProduction,
          Permission.viewEmployeeHistory,
          Permission.viewSyncStatus,
          Permission.switchUser,
        ]),
      );
    });

    test('history scopes are kept alongside the supervisor set', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_INITIAL_ASSIGN'), _perm('PP_HIST_TEAM')],
        workContexts: const [_workContext],
      );

      expect(
        authorization.permissions,
        contains(Permission.viewTeamProductionHistory),
      );
      expect(
        authorization.permissions,
        isNot(contains(Permission.viewOwnProductionHistory)),
      );
    });

    test('requires at least one work context', () {
      // has_work_scope rejects every write outside the account's Plant/
      // WorkCenter, so a supervisor without one has nothing it can do.
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('PP_INITIAL_ASSIGN')],
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

    test('a worker never picks up a supervisor screen gate', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_HIST_SELF'), _perm('PP_HIST_TEAM')],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.worker);
      expect(
        authorization.permissions,
        isNot(contains(Permission.assignQuantity)),
      );
    });
  });

  group('SAP session authorization — rejected', () {
    test('the retired spec vocabulary grants nothing', () {
      // ASSIGN_QUANTITY / VIEW_TEAM_PRODUCTION and friends were never in
      // ztb_mob_func. Matching on them is what mis-filed a manager account as
      // a worker; they must now read as no permission at all.
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [
            _perm('ASSIGN_QUANTITY'),
            _perm('RECALL_ASSIGNMENT'),
            _perm('VIEW_TEAM_PRODUCTION'),
          ],
          workContexts: const [_workContext],
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
