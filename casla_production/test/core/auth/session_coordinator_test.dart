import 'dart:async';

import 'package:casla_production/core/auth/session_coordinator.dart';
import 'package:casla_production/core/auth/session_refresh.dart';
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
      coordinator.completeLogin(
        generation: generation,
        session: session('user-a'),
      ),
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

  test(
    'a caller whose token was already rotated does not refresh again',
    () async {
      var calls = 0;
      final coordinator = SessionCoordinator((current) async {
        calls++;
        return session('user-a', refreshToken: 'refresh-b');
      });
      final generation = coordinator.beginLogin();
      coordinator.completeLogin(
        generation: generation,
        session: session('user-a'),
      );

      // First caller refreshes with the token everybody started with.
      expect(
        await coordinator.refreshDetailed(staleAccessToken: 'access-user-a'),
        SessionRefreshOutcome.refreshed,
      );
      expect(calls, 1);
      // A second caller that failed with that same old token must not rotate
      // the single-use refresh token a second time.
      expect(
        await coordinator.refreshDetailed(staleAccessToken: 'old-access'),
        SessionRefreshOutcome.refreshed,
      );
      expect(calls, 1);
      coordinator.dispose();
    },
  );

  test('SAP refusing the refresh token is a rejection', () async {
    final coordinator = SessionCoordinator((_) async {
      throw const SessionRefreshRejectedException(
        code: 'TOKEN_INVALID_OR_EXPIRED',
        message: 'dead',
      );
    });
    final generation = coordinator.beginLogin();
    coordinator.completeLogin(
      generation: generation,
      session: session('user-a'),
    );

    expect(await coordinator.refreshDetailed(), SessionRefreshOutcome.rejected);
    expect(await coordinator.refresh(), isFalse);
    // The coordinator itself keeps the session; ending it is AppState's call.
    expect(coordinator.currentSession?.id, 'user-a');
    coordinator.dispose();
  });

  test('an unreachable SAP is unavailable and keeps the session', () async {
    final coordinator = SessionCoordinator((_) async {
      throw const SessionRefreshUnavailableException('offline');
    });
    final generation = coordinator.beginLogin();
    coordinator.completeLogin(
      generation: generation,
      session: session('user-a'),
    );

    expect(
      await coordinator.refreshDetailed(),
      SessionRefreshOutcome.unavailable,
    );
    expect(coordinator.currentSession?.refreshToken, 'refresh-a');
    coordinator.dispose();
  });

  test('nothing to refresh is skipped, not a failure', () async {
    final coordinator = SessionCoordinator((_) async => null);
    expect(await coordinator.refreshDetailed(), SessionRefreshOutcome.skipped);
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
    coordinator.completeLogin(
      generation: generation,
      session: session('user-a'),
    );

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
