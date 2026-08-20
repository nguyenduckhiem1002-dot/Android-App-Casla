import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SAP session authorization', () {
    test('maps explicit role, permissions and team scope', () {
      final authorization = AuthRepositoryImpl.parseAuthorization({
        'Role': 'SUPERVISOR',
        'Permissions': ['VIEW_TEAM_PRODUCTION', 'ASSIGN_QUANTITY'],
        'TeamIds': ['team-1', 'team-2'],
      });

      expect(authorization.role, UserRole.supervisor);
      expect(
        authorization.permissions,
        containsAll([Permission.viewTeamProduction, Permission.assignQuantity]),
      );
      expect(authorization.teamIds, ['team-1', 'team-2']);
    });

    test('does not promote a session with missing role claims', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization({
          'Permissions': 'VIEW_TEAM_PRODUCTION',
          'TeamIds': 'team-1',
        }),
        throwsException,
      );
    });

    test('requires team-view permission and a non-empty scope', () {
      expect(
        () => AuthRepositoryImpl.parseAuthorization({
          'Role': 'SUPERVISOR',
          'Permissions': 'ASSIGN_QUANTITY',
          'TeamIds': 'team-1',
        }),
        throwsException,
      );

      expect(
        () => AuthRepositoryImpl.parseAuthorization({
          'Role': 'SUPERVISOR',
          'Permissions': 'VIEW_TEAM_PRODUCTION',
          'TeamIds': '',
        }),
        throwsException,
      );
    });
  });
}
