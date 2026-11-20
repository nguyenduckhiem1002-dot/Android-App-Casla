// SAP sends no explicit Role claim (see ZA_MOB_LoginResult) — the app derives
// it from the FuncID permission set login/refresh return. These tests exercise
// that derivation directly, against the same SapPermission / SapWorkContext
// shapes SapAuthController parses off the wire.
//
// The vocabulary here is only what the backend actually issues:
// PP_INITIAL_ASSIGN / PP_CONFIRM / PP_RECALL (the FuncIDs zbp_r_pp_opalloc
// gates assign, confirm and recall on), PP_HIST_SELF and PP_HIST_TEAM (read
// scopes in zcl_pp_work_history) and PP_POS_MANAGE. Nothing else SAP returns
// may influence the role.
//
// Business rule: any one of Giao / Xác nhận / Thu hồi opens Tổng quan, each
// one shows only its own menu, and every one of them needs PP_HIST_TEAM.
// Thu hồi also opens the Xác nhận tab but never enters a confirmed quantity.
// Vị trí alone opens only its tab; with PP_HIST_TEAM it also opens Tổng quan.

import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_auth_controller.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/shared/screens/supervisor_shell.dart';
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

Matcher _throwsMessage(Matcher message) => throwsA(
  isA<Exception>().having((error) => error.toString(), 'message', message),
);

void main() {
  test('work context keeps PlantName for readable setup labels', () {
    final context = SapWorkContext.fromJson({
      'WorkID': 'WORK-01',
      'WorkName': 'May 1',
      'Plant': '6711',
      'PlantName': 'Nhà máy 6711',
      'WorkCenter': 'WC-01',
      'BoPhan': 'Xưởng May',
      'Location': 'Tầng 2',
    });

    expect(context.plantName, 'Nhà máy 6711');
    expect(context.location, 'Tầng 2');
  });

  test('work context keeps WorkCenterName for the Xưởng label', () {
    final context = SapWorkContext.fromJson({
      'WorkID': 'XM2.002',
      'WorkName': 'MAY CHI TIẾT PHỤ-XM2',
      'Plant': '6711',
      'WorkCenter': 'CL100077',
      'WorkCenterName': 'Xưởng may 2',
      'BoPhan': 'MAY CHI TIẾT PHỤ-XM2',
      'Location': 'XM2',
    });

    expect(context.workCenter, 'CL100077');
    expect(context.workCenterName, 'Xưởng may 2');
  });

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

    test('all three operations reach every screen the router gates', () {
      // The router's redirect asks for these by name. If this regresses, a
      // manager lands on the shell and every sub-route bounces back to it.
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [
          _perm('PP_INITIAL_ASSIGN'),
          _perm('PP_CONFIRM'),
          _perm('PP_RECALL'),
          _perm('PP_HIST_TEAM'),
        ],
        workContexts: const [_workContext],
      );

      expect(
        authorization.permissions,
        containsAll([
          Permission.assignQuantity,
          Permission.confirmProduction,
          Permission.recallAssignment,
          Permission.viewTeamProduction,
          Permission.viewEmployeeHistory,
          Permission.viewSyncStatus,
          Permission.switchUser,
        ]),
      );
      expect(supervisorTabIds(authorization.permissions), [
        'overview',
        'assign',
        'confirm',
        'sync',
      ]);
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
          permissions: [_perm('PP_INITIAL_ASSIGN'), _perm('PP_HIST_TEAM')],
          workContexts: const [],
        ),
        _throwsMessage(contains('phạm vi tổ')),
      );
    });

    test('PP_POS_MANAGE adds the Vị trí tab next to an operation', () {
      final supervisor = AuthRepositoryImpl.parseAuthorization(
        permissions: [
          _perm('PP_CONFIRM'),
          _perm('PP_HIST_TEAM'),
          _perm('PP_POS_MANAGE'),
        ],
        workContexts: const [_workContext],
      );
      expect(supervisorTabIds(supervisor.permissions), [
        'overview',
        'confirm',
        'positions',
        'sync',
      ]);
    });
  });

  group('SAP session authorization — Vị trí (PP_POS_MANAGE)', () {
    test('alone it opens only the Vị trí tab', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_POS_MANAGE')],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.supervisor);
      expect(supervisorTabIds(authorization.permissions), ['positions']);
      expect(
        authorization.permissions,
        isNot(contains(Permission.viewTeamProduction)),
      );
    });

    test('PP_HIST_SELF does not open Tổng quan for it', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_POS_MANAGE'), _perm('PP_HIST_SELF')],
        workContexts: const [_workContext],
      );

      expect(supervisorTabIds(authorization.permissions), ['positions']);
    });

    test('with PP_HIST_TEAM it also opens a read-only Tổng quan', () {
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [_perm('PP_POS_MANAGE'), _perm('PP_HIST_TEAM')],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.supervisor);
      expect(supervisorTabIds(authorization.permissions), [
        'overview',
        'positions',
      ]);
      expect(
        authorization.permissions,
        contains(Permission.viewEmployeeHistory),
      );
      expect(
        authorization.permissions.intersection({
          Permission.assignQuantity,
          Permission.confirmProduction,
          Permission.recallAssignment,
          Permission.viewSyncStatus,
        }),
        isEmpty,
        reason: 'Vị trí grants no Giao/Xác nhận/Thu hồi menu',
      );
    });

    test('still needs a work context', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('PP_POS_MANAGE'), _perm('PP_HIST_TEAM')],
          workContexts: const [],
        ),
        _throwsMessage(contains('phạm vi tổ')),
      );
    });

    test('does not excuse an operation from needing PP_HIST_TEAM', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('PP_POS_MANAGE'), _perm('PP_RECALL')],
          workContexts: const [_workContext],
        ),
        _throwsMessage(allOf(contains('PP_HIST_TEAM'), contains('PP_RECALL'))),
      );
    });
  });

  group('SAP session authorization — one operation, one menu', () {
    // Each operation FuncID alone is enough to open Tổng quan, and unlocks
    // only its own menu or button.
    const cases = <String, ({Permission granted, List<String> tabs})>{
      'PP_INITIAL_ASSIGN': (
        granted: Permission.assignQuantity,
        tabs: ['overview', 'assign', 'sync'],
      ),
      'PP_CONFIRM': (
        granted: Permission.confirmProduction,
        tabs: ['overview', 'confirm', 'sync'],
      ),
      // Thu hồi has no tab of its own. It shares the Xác nhận tab to scan a
      // worker, then may only recall there (see the assignment detail tests).
      'PP_RECALL': (
        granted: Permission.recallAssignment,
        tabs: ['overview', 'confirm', 'sync'],
      ),
    };
    const operations = {
      Permission.assignQuantity,
      Permission.confirmProduction,
      Permission.recallAssignment,
    };

    for (final MapEntry(key: funcId, value: expected) in cases.entries) {
      test('$funcId + PP_HIST_TEAM opens Tổng quan with only its menu', () {
        final authorization = AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm(funcId), _perm('PP_HIST_TEAM')],
          workContexts: const [_workContext],
        );

        expect(authorization.role, UserRole.supervisor);
        expect(
          authorization.permissions.intersection(operations),
          {expected.granted},
          reason: 'one operation must not unlock the other two',
        );
        expect(supervisorTabIds(authorization.permissions), expected.tabs);
      });

      test('$funcId without PP_HIST_TEAM is rejected with a clear message', () {
        expect(
          () => AuthRepositoryImpl.parseAuthorization(
            // PP_HIST_SELF does not stand in for the team scope.
            permissions: [_perm(funcId), _perm('PP_HIST_SELF')],
            workContexts: const [_workContext],
          ),
          _throwsMessage(allOf(contains('PP_HIST_TEAM'), contains(funcId))),
        );
      });
    }

    test('the message names every operation the account holds', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization(
          permissions: [_perm('PP_INITIAL_ASSIGN'), _perm('PP_RECALL')],
          workContexts: const [_workContext],
        ),
        _throwsMessage(
          allOf(
            contains('Giao'),
            contains('Thu hồi'),
            isNot(contains('PP_CONFIRM')),
          ),
        ),
      );
    });

    test('FuncIDs outside the three operations do not open Tổng quan', () {
      // PP_TRANSFER / PP_REVERSE exist in SAP but have no menu in the app.
      final authorization = AuthRepositoryImpl.parseAuthorization(
        permissions: [
          _perm('PP_TRANSFER'),
          _perm('PP_REVERSE'),
          _perm('PP_HIST_TEAM'),
        ],
        workContexts: const [_workContext],
      );

      expect(authorization.role, UserRole.worker);
      expect(
        authorization.permissions,
        isNot(contains(Permission.viewTeamProduction)),
      );
    });
  });

  group('SAP session authorization — recall without password', () {
    Set<Permission> permissionsOf(List<String> funcIds) =>
        AuthRepositoryImpl.parseAuthorization(
          permissions: [for (final id in funcIds) _perm(id)],
          workContexts: const [_workContext],
        ).permissions;

    test('PP_RECALL_NOPASS with PP_RECALL offers the tick box', () {
      final permissions = permissionsOf([
        'PP_RECALL',
        'PP_RECALL_NOPASS',
        'PP_HIST_TEAM',
      ]);

      expect(permissions, contains(Permission.recallAssignment));
      expect(permissions, contains(Permission.recallWithoutPassword));
    });

    test('PP_RECALL alone keeps asking for the worker password', () {
      final permissions = permissionsOf(['PP_RECALL', 'PP_HIST_TEAM']);

      expect(permissions, isNot(contains(Permission.recallWithoutPassword)));
    });

    test('without PP_RECALL it grants nothing', () {
      // SAP gates recall on PP_RECALL first, so the add-on alone cannot
      // recall anything and must not show a tick box that would be refused.
      final permissions = permissionsOf([
        'PP_CONFIRM',
        'PP_RECALL_NOPASS',
        'PP_HIST_TEAM',
      ]);

      expect(permissions, isNot(contains(Permission.recallWithoutPassword)));
      expect(permissions, isNot(contains(Permission.recallAssignment)));
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
