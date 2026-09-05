import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('token refresh keeps every SAP work context available to the UI', () {
    const contexts = [
      UserWorkContext(
        workId: 'TO-CAT-01',
        workName: 'Tổ Cắt 1',
        plant: '1000',
        workCenter: 'WC-CAT-01',
        boPhan: 'Xưởng Cắt',
        location: 'Nhà máy 1',
      ),
      UserWorkContext(
        workId: 'TO-CAT-02',
        workName: 'Tổ Cắt 2',
        plant: '1000',
        workCenter: 'WC-CAT-02',
        boPhan: 'Xưởng Cắt',
        location: 'Nhà máy 1',
      ),
    ];
    const session = UserSession(
      id: 'user-1',
      maNv: 'NV000001',
      fullName: 'Quản lý A',
      teamName: 'Tổ Cắt 1',
      role: UserRole.supervisor,
      permissions: {Permission.viewTeamProduction},
      toIds: ['TO-CAT-01', 'TO-CAT-02'],
      workContexts: contexts,
    );

    final refreshed = session.copyWithTokens(
      accessToken: 'new-access-token',
      refreshToken: 'new-refresh-token',
    );

    expect(refreshed.workContexts, hasLength(2));
    expect(refreshed.workContexts.map((context) => context.workName), [
      'Tổ Cắt 1',
      'Tổ Cắt 2',
    ]);
    expect(refreshed.toIds, ['TO-CAT-01', 'TO-CAT-02']);
  });
}
