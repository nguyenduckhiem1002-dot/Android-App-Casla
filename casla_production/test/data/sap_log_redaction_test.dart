// Redaction tests — credentials must not survive into the log.
//
// The original patterns matched only `password='...'`, but Dio logs the encoded
// URI where SAP's required single quotes appear as %27. Every real request
// therefore missed the filter and printed the password in full.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';

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
}
