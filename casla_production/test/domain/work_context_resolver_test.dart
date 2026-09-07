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
}
