// The sync engine asks the gateway for a session refresh right after a push
// failed on an expired token. The gateway names the token that push used, so
// a refresh another caller already made is not followed by a second rotation.

import 'package:casla_production/core/auth/session_refresh.dart';
import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/data/sap/sap_pp_opalloc_gateway.dart';
import 'package:casla_production/data/sap/sap_session_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

class _RecordingSession implements SapSessionProvider {
  String? token = 'token-a';
  final List<String?> staleTokens = [];

  @override
  String? get accessToken => token;
  @override
  int get generation => 1;
  @override
  bool isGenerationCurrent(int generation) => generation == 1;
  @override
  Future<SessionRefreshOutcome> refreshSession({
    String? staleAccessToken,
  }) async {
    staleTokens.add(staleAccessToken);
    return SessionRefreshOutcome.refreshed;
  }
}

class _OfflineClient extends SapODataClient {
  _OfflineClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  @override
  Future<String?> fetchCsrfToken() async => 'contract-csrf';
}

void main() {
  useInMemoryDatabase();

  late _RecordingSession session;
  late SapPpOpAllocGateway gateway;

  setUp(() {
    CaslaDatabase.resetForTesting();
    session = _RecordingSession();
    gateway = SapPpOpAllocGateway(
      db: CaslaDatabase.instance,
      client: _OfflineClient(),
      session: session,
    );
  });

  // A queue row without an idempotency key is turned away before any HTTP
  // call, which is enough here: the token is recorded when the push starts.
  Future<void> pushOnce() async {
    await expectLater(
      gateway.push(
        const SyncPushRequest(
          queueItem: {
            'id': 'queue-1',
            'entity_type': 'PRODUCTION',
            'entity_id': 'rec-1',
            'action': 'CREATE',
          },
          source: {'id': 'rec-1'},
        ),
      ),
      throwsA(isA<SapBusinessError>()),
    );
  }

  test('a refresh after a push names the token that push used', () async {
    await pushOnce();
    // Another caller renews the session before the engine reacts.
    session.token = 'token-b';

    expect(await gateway.refreshSession(), isTrue);
    expect(session.staleTokens, ['token-a']);
  });

  test('each push replaces the remembered token', () async {
    await pushOnce();
    session.token = 'token-b';
    await pushOnce();

    await gateway.refreshSession();
    expect(session.staleTokens, ['token-b']);
  });

  test('without a push, or after a reset, no stale token is claimed', () async {
    await gateway.refreshSession();
    await pushOnce();
    gateway.resetTransportSession();
    await gateway.refreshSession();

    expect(session.staleTokens, [null, null]);
  });
}
