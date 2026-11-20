// Redaction tests — credentials must not survive into the log.
//
// The original patterns matched only `password='...'`, but Dio logs the encoded
// URI where SAP's required single quotes appear as %27. Every real request
// therefore missed the filter and printed the password in full.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';

class _MissingCsrfClient extends SapODataClient {
  _MissingCsrfClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  @override
  Future<String?> fetchCsrfToken() async => null;
}

class _ValidCsrfClient extends SapODataClient {
  _ValidCsrfClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  @override
  Future<String?> fetchCsrfToken() async => 'test-csrf';
}

void main() {
  group('SapODataClient.redactSecrets', () {
    test('masks a percent-encoded password, the form Dio actually logs', () {
      const line =
          'uri: https://sap.example/login?Username=%27svc%27&password=%27hunter2%27';

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('hunter2')));
      expect(out, contains('[REDACTED]'));
    });

    test('masks a raw quoted password', () {
      const line = "queryParameters: {Username: 'svc', password: 'hunter2'}";

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('hunter2')));
    });

    test('masks an unquoted query password', () {
      const line =
          'uri: https://sap.example/login?password=hunter2&device_id=x';

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('hunter2')));
      expect(out, contains('device_id=x'), reason: 'must not over-redact');
    });

    test('masks the change-password parameters', () {
      const line =
          'changePassword?old_password=%27oldpw%27&new_password=%27newpw%27';

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('oldpw')));
      expect(out, isNot(contains('newpw')));
    });

    test('masks access and refresh tokens in both forms', () {
      const line =
          "access_token='abc123' refresh_token=%27def456%27 access_token=ghi789";

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('def456')));
      expect(out, isNot(contains('ghi789')));
    });

    test('masks the Basic auth header', () {
      const line = 'Authorization: Basic c3ZjOnNlY3JldA==';

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('c3ZjOnNlY3JldA')));
      expect(out, contains('Authorization=[REDACTED]'));
    });

    test('masks SAP camel-case JSON credentials and cookie headers', () {
      const line =
          'data: {WorkerPassword: "worker-secret", CurrentPassword: "old-secret", '
          'NewPassword: "new-secret", AccessToken: "access-123", '
          'RefreshToken: "refresh-456"} Cookie: JSESSIONID=abc; sap-user=def '
          'x-csrf-token: csrf-value';

      final out = SapODataClient.redactSecrets(line);

      for (final secret in const [
        'worker-secret',
        'old-secret',
        'new-secret',
        'access-123',
        'refresh-456',
        'JSESSIONID=abc',
        'csrf-value',
      ]) {
        expect(out, isNot(contains(secret)));
      }
    });

    test('masks Bearer credentials', () {
      const line = 'Authorization: Bearer live-token-value';

      final out = SapODataClient.redactSecrets(line);

      expect(out, isNot(contains('live-token-value')));
      expect(out, contains('Authorization=[REDACTED]'));
    });

    test('leaves non-secret content alone', () {
      const line = 'uri: https://sap.example/ZC_USER_QR_API?Username=%27svc%27';

      final out = SapODataClient.redactSecrets(line);

      expect(out, contains('ZC_USER_QR_API'));
      expect(out, contains('svc'));
    });
  });

  group('SapODataClient.safeOperationLabel', () {
    test('keeps only the OData action name', () {
      expect(
        SapODataClient.safeOperationLabel(
          'OperationAllocations/com.sap.example.submitInitialAssign',
        ),
        'submitInitialAssign',
      );
    });

    test('does not expose query values', () {
      expect(
        SapODataClient.safeOperationLabel(
          'login?WorkerPassword=top-secret&AccessToken=token',
        ),
        'login',
      );
    });
  });

  group('SapODataClient.safeRequestPayload', () {
    test('renders the action parameters with every credential masked', () {
      final out = SapODataClient.safeRequestPayload({
        'ProductionOrder': '010140000380',
        'Operation': '0080',
        'WorkerID': 'CL400111',
        'Quantity': '100',
        'DefectQuantity': '0',
        'UnitOfMeasure': 'CHC',
        'ShiftID': '1',
        'EntryDate': '2026-10-27',
        'EntryTime': '13:23:07',
        'PostingDate': '2026-10-27',
        'OriginalTransactionUUID': null,
        'AccessToken': 'tok-secret-123',
        'DeviceID': 'PDA-TC22-14-3',
        'WorkerPassword': 'hunter2',
        'SyncItemUUID': 'sync-1',
      })!;

      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('tok-secret-123')));
      expect(out, contains('"WorkerPassword":"[REDACTED]"'));
      expect(out, contains('"AccessToken":"[REDACTED]"'));
      expect(out, contains('"ProductionOrder":"010140000380"'));
      expect(
        out,
        contains('"OriginalTransactionUUID":null'),
        reason: 'a missing parameter must stay visible as null',
      );
      expect(out, contains('"EntryTime":"13:23:07"'));
      expect(out, isNot(contains('\n')));
    });

    test('masks login credentials under their own key names', () {
      final out = SapODataClient.safeRequestPayload({
        'Username': 'cl400033',
        'Password': 'hunter2',
        'DeviceID': 'x',
        'RefreshToken': 'rt-1',
        'NewPassword': 'n3w',
      })!;

      expect(out, contains('"Username":"cl400033"'));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('rt-1')));
      expect(out, isNot(contains('n3w')));
    });

    test('returns null for a body that is not a JSON object', () {
      expect(SapODataClient.safeRequestPayload(null), isNull);
      expect(SapODataClient.safeRequestPayload('raw'), isNull);
    });

    test('is bounded', () {
      final out = SapODataClient.safeRequestPayload({'Note': 'x' * 5000})!;

      expect(out.length, SapODataClient.maxLoggedPayloadLength + 1);
      expect(out.endsWith('…'), isTrue);
    });
  });

  group('SapODataClient.safeRejectionMessage', () {
    DioException rejection(Object? body, {int status = 400}) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        data: body,
      ),
    );

    test('keeps the free-text sentence a RAP validation answers with', () {
      final error = rejection({
        'error': {
          'code': '/IWBEP/CM_V4S_RUN/000',
          'message': 'Số lượng còn lại không khớp với sổ phân bổ',
        },
      });

      final out = SapODataClient.safeRejectionMessage(
        error,
        diagnostic: '/IWBEP/CM_V4S_RUN/000',
      );

      expect(out, 'Số lượng còn lại không khớp với sổ phân bổ');
    });

    test(
      'does not repeat a business code already logged as the diagnostic',
      () {
        final error = rejection({
          'error': {
            'code': '/IWBEP/CM_V4S_RUN/000',
            'message': 'WORKER_AUTH_FAILED',
          },
        });

        expect(
          SapODataClient.safeRejectionMessage(
            error,
            diagnostic: 'WORKER_AUTH_FAILED',
          ),
          isNull,
        );
      },
    );

    test('logs nothing for a body without an OData error envelope', () {
      final html = rejection(
        '<html>Anmeldung fehlgeschlagen</html>',
        status: 401,
      );
      final empty = rejection(null, status: 500);

      expect(
        SapODataClient.safeRejectionMessage(html, diagnostic: null),
        isNull,
      );
      expect(
        SapODataClient.safeRejectionMessage(empty, diagnostic: null),
        isNull,
      );
    });

    test('collapses newlines, redacts secrets and truncates', () {
      final error = rejection({
        'error': {
          'code': 'X',
          'message': {
            'value': 'Line one\n  password=hunter2 then ${'x' * 300}',
          },
        },
      });

      final out = SapODataClient.safeRejectionMessage(error, diagnostic: 'X')!;

      expect(out, isNot(contains('\n')));
      expect(out, isNot(contains('hunter2')));
      expect(out, startsWith('Line one password=[REDACTED] then'));
      expect(out.endsWith('…'), isTrue);
      expect(
        out.length,
        SapODataClient.maxLoggedRejectionLength + 1,
        reason: 'bounded plus the ellipsis',
      );
    });
  });

  group('SapODataClient.requireCsrfToken', () {
    test('blocks a mutation when fetching the token fails', () async {
      await expectLater(
        _MissingCsrfClient().requireCsrfToken(),
        throwsA(isA<SapCsrfException>()),
      );
    });

    test('returns the token supplied by the fetch', () async {
      expect(await _ValidCsrfClient().requireCsrfToken(), 'test-csrf');
    });
  });
}
