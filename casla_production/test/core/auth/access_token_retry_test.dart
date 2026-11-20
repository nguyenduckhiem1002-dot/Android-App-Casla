// A direct call that carries the access token gets one refresh-and-retry when
// SAP says the token expired — and never a second one.

import 'package:casla_production/core/auth/access_token_retry.dart';
import 'package:casla_production/core/auth/session_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String? token;
  late List<String> usedTokens;
  late List<String?> staleTokens;
  late SessionRefreshOutcome outcome;
  String? tokenAfterRefresh;

  Future<SessionRefreshOutcome> refresh({String? staleAccessToken}) async {
    staleTokens.add(staleAccessToken);
    if (outcome == SessionRefreshOutcome.refreshed) token = tokenAfterRefresh;
    return outcome;
  }

  Future<String> run(Future<String> Function(String accessToken) call) =>
      runWithAccessTokenRetry<String>(
        readAccessToken: () => token,
        refreshSession: refresh,
        call: (accessToken) {
          usedTokens.add(accessToken);
          return call(accessToken);
        },
      );

  setUp(() {
    token = 'token-a';
    tokenAfterRefresh = 'token-b';
    usedTokens = [];
    staleTokens = [];
    outcome = SessionRefreshOutcome.refreshed;
  });

  test('a valid token is used as it is, without a refresh', () async {
    expect(await run((accessToken) async => 'ok'), 'ok');
    expect(usedTokens, ['token-a']);
    expect(staleTokens, isEmpty);
  });

  test('an expired token is renewed once and the call sent again', () async {
    final result = await run((accessToken) async {
      if (accessToken == 'token-a') {
        throw const AccessTokenExpiredException('hết hạn');
      }
      return 'changed';
    });

    expect(result, 'changed');
    expect(usedTokens, ['token-a', 'token-b']);
    // The refresh names the token that failed, so a refresh another caller
    // already made is reused instead of rotating the tokens twice.
    expect(staleTokens, ['token-a']);
  });

  test('a second expiry answer is passed on, not refreshed again', () async {
    await expectLater(
      run(
        (accessToken) async =>
            throw const AccessTokenExpiredException('hết hạn'),
      ),
      throwsA(isA<AccessTokenExpiredException>()),
    );
    expect(usedTokens, ['token-a', 'token-b']);
    expect(staleTokens, hasLength(1));
  });

  test('an unreachable SAP keeps the session and says to try again', () async {
    outcome = SessionRefreshOutcome.unavailable;

    await expectLater(
      run(
        (accessToken) async =>
            throw const AccessTokenExpiredException('hết hạn'),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains(kSessionRenewUnavailableMessage),
        ),
      ),
    );
    expect(usedTokens, ['token-a']);
    expect(token, 'token-a');
  });

  test('a refused refresh passes the expiry on without a retry', () async {
    for (final refused in [
      SessionRefreshOutcome.rejected,
      SessionRefreshOutcome.skipped,
    ]) {
      outcome = refused;
      usedTokens = [];

      await expectLater(
        run(
          (accessToken) async =>
              throw const AccessTokenExpiredException('hết hạn'),
        ),
        throwsA(isA<AccessTokenExpiredException>()),
      );
      expect(usedTokens, ['token-a'], reason: refused.name);
    }
  });

  test('a refresh that left the token unchanged is not retried', () async {
    tokenAfterRefresh = 'token-a';

    await expectLater(
      run(
        (accessToken) async =>
            throw const AccessTokenExpiredException('hết hạn'),
      ),
      throwsA(isA<AccessTokenExpiredException>()),
    );
    expect(usedTokens, ['token-a']);
  });

  test('other failures are not mistaken for an expired token', () async {
    await expectLater(
      run(
        (accessToken) async => throw Exception('Mật khẩu hiện tại không đúng'),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Mật khẩu hiện tại không đúng'),
        ),
      ),
    );
    expect(staleTokens, isEmpty);
  });

  test('without a session nothing is sent', () async {
    token = null;

    await expectLater(
      run((accessToken) async => 'never'),
      throwsA(
        isA<AccessTokenExpiredException>().having(
          (error) => error.message,
          'message',
          kNoSessionMessage,
        ),
      ),
    );
    expect(usedTokens, isEmpty);
    expect(staleTokens, isEmpty);
  });
}
