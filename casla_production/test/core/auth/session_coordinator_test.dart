import 'dart:async';

import 'package:casla_production/core/auth/session_coordinator.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  UserSession session(String id, {String refreshToken = 'refresh-a'}) =>
      UserSession(
        id: id,
        maNv: id,
        fullName: id,
        teamName: 'Tổ A',
        accessToken: 'access-$id',
        refreshToken: refreshToken,
        role: UserRole.supervisor,
        permissions: const {Permission.viewTeamProduction},
        toIds: const ['team-a'],
      );

  test('a refresh cannot resurrect a session after logout', () async {
    final gate = Completer<UserSession?>();
    final coordinator = SessionCoordinator((_) => gate.future);
    final generation = coordinator.beginLogin();
    expect(
      coordinator.completeLogin(generation: generation, session: session('user-a')),
      isTrue,
    );

    final refresh = coordinator.refresh();
    coordinator.clear();
    gate.complete(session('user-a', refreshToken: 'refresh-b'));

    expect(await refresh, isFalse);
    expect(coordinator.currentSession, isNull);
    coordinator.dispose();
  });

  test('a refresh cannot overwrite a newer login identity', () async {
    final gate = Completer<UserSession?>();
    final coordinator = SessionCoordinator((_) => gate.future);
    final firstGeneration = coordinator.beginLogin();
    coordinator.completeLogin(
      generation: firstGeneration,
      session: session('user-a'),
    );

    final refresh = coordinator.refresh();
    final secondGeneration = coordinator.beginLogin();
    coordinator.completeLogin(
      generation: secondGeneration,
      session: session('user-b'),
    );
    gate.complete(session('user-a', refreshToken: 'refresh-b'));

    expect(await refresh, isFalse);
    expect(coordinator.currentSession?.id, 'user-b');
    coordinator.dispose();
  });

  test('parallel refresh callers share one SAP refresh request', () async {
    final gate = Completer<UserSession?>();
    var calls = 0;
    final coordinator = SessionCoordinator((_) {
      calls++;
      return gate.future;
    });
    final generation = coordinator.beginLogin();
    coordinator.completeLogin(generation: generation, session: session('user-a'));

    final first = coordinator.refresh();
    final second = coordinator.refresh();
    expect(calls, 1);

    gate.complete(session('user-a', refreshToken: 'refresh-b'));
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(coordinator.currentSession?.refreshToken, 'refresh-b');
    coordinator.dispose();
  });
}
