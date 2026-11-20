// SapODataClient.postWithCsrf: the CSRF token of a transport session is
// reused, a 403 on a reused token is answered with one fresh fetch and one
// resend, and SAP_REUSE_CSRF_TOKEN=false restores a fetch per request.

import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingClient extends SapODataClient {
  _CountingClient({required bool reuse})
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
        reuseCsrfToken: reuse,
      );

  var csrfFetches = 0;
  var holdsCsrfToken = false;

  @override
  bool get hasCsrfToken => holdsCsrfToken;

  // CSRF fetching builds its own Dio; keep the test off the network.
  @override
  Future<String?> fetchCsrfToken() async {
    csrfFetches++;
    holdsCsrfToken = true;
    return 'contract-csrf';
  }
}

void main() {
  late List<int> statuses;
  late int sends;

  _CountingClient clientWith({required bool reuse}) {
    final client = _CountingClient(reuse: reuse);
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          sends++;
          final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
          if (status != 200) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: request, statusCode: status),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {'Status': 'SUCCESS'},
            ),
          );
        },
      ),
    );
    return client;
  }

  setUp(() {
    statuses = [];
    sends = 0;
  });

  test('the token is fetched once and reused by later requests', () async {
    final client = clientWith(reuse: true);

    await client.postWithCsrf('Set/action', data: const {});
    await client.postWithCsrf('Set/action', data: const {});

    expect(client.csrfFetches, 1);
    expect(sends, 2);
  });

  test('a 403 on a reused token is resent once with a fresh token', () async {
    final client = clientWith(reuse: true);
    var guards = 0;
    await client.postWithCsrf('Set/action', data: const {});
    statuses.add(403);

    final response = await client.postWithCsrf(
      'Set/action',
      data: const {},
      guard: () => guards++,
    );

    expect(response.statusCode, 200);
    expect(client.csrfFetches, 2);
    expect(sends, 3);
    // The caller's session check runs before each of the two sends.
    expect(guards, 2);
  });

  test('a second 403 is reported, not sent a third time', () async {
    final client = clientWith(reuse: true);
    await client.postWithCsrf('Set/action', data: const {});
    statuses.addAll([403, 403]);

    await expectLater(
      client.postWithCsrf('Set/action', data: const {}),
      throwsA(isA<DioException>()),
    );

    expect(sends, 3);
  });

  test('a failure other than 403 is never resent', () async {
    final client = clientWith(reuse: true);
    await client.postWithCsrf('Set/action', data: const {});
    statuses.add(400);

    await expectLater(
      client.postWithCsrf('Set/action', data: const {}),
      throwsA(isA<DioException>()),
    );

    expect(client.csrfFetches, 1);
    expect(sends, 2);
  });

  test(
    'with reuse off a token is fetched per request and a 403 is final',
    () async {
      final client = clientWith(reuse: false);

      await client.postWithCsrf('Set/action', data: const {});
      await client.postWithCsrf('Set/action', data: const {});
      expect(client.csrfFetches, 2);

      statuses.add(403);
      await expectLater(
        client.postWithCsrf('Set/action', data: const {}),
        throwsA(isA<DioException>()),
      );
      expect(client.csrfFetches, 3);
      expect(sends, 3);
    },
  );
}
