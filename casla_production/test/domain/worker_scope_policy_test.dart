import 'package:casla_production/domain/policies/worker_scope_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkerScopePolicy', () {
    test('returns inScope when worker and supervisor share a team', () {
      expect(
        WorkerScopePolicy.evaluate(
          workerTeamIds: const ['TEAM-2'],
          supervisorTeamIds: const ['TEAM-1', 'TEAM-2'],
        ),
        WorkerScopeMatch.inScope,
      );
    });

    test('returns outOfScope when known worker teams do not intersect', () {
      expect(
        WorkerScopePolicy.evaluate(
          workerTeamIds: const ['TEAM-3'],
          supervisorTeamIds: const ['TEAM-1', 'TEAM-2'],
        ),
        WorkerScopeMatch.outOfScope,
      );
    });

    test('returns unknown when cached worker team membership is missing', () {
      expect(
        WorkerScopePolicy.evaluate(
          workerTeamIds: const [],
          supervisorTeamIds: const ['TEAM-1'],
        ),
        WorkerScopeMatch.unknown,
      );
    });

    test('fails closed when supervisor has no work scope', () {
      expect(
        WorkerScopePolicy.evaluate(
          workerTeamIds: const ['TEAM-1'],
          supervisorTeamIds: const [],
        ),
        WorkerScopeMatch.outOfScope,
      );
    });
  });
}
