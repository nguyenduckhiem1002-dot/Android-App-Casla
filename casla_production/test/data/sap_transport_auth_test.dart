import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const baseUrl = 'https://gateway.example.org/sap/opu/odata4/sap/';

  group('SapODataClient transport authentication', () {
    test('basic mode attaches the configured Basic Authorization header', () {
      final client = SapODataClient(
        baseUrl: baseUrl,
        transportAuthMode: SapTransportAuthMode.basic,
        basicAuthUser: 'service-user',
        basicAuthPassword: 'service-pass',
      );

      expect(
        client.dio.options.headers['Authorization'],
        'Basic c2VydmljZS11c2VyOnNlcnZpY2UtcGFzcw==',
      );
      expect(client.ensureConfigured, returnsNormally);
    });

    test('gateway mode never attaches a shared Authorization header', () {
      final client = SapODataClient(
        baseUrl: baseUrl,
        transportAuthMode: SapTransportAuthMode.gateway,
        basicAuthUser: '',
        basicAuthPassword: '',
      );

      expect(client.dio.options.headers.containsKey('Authorization'), isFalse);
      expect(client.ensureConfigured, returnsNormally);
    });

    test('gateway mode rejects accidentally supplied Basic credentials', () {
      final client = SapODataClient(
        baseUrl: baseUrl,
        transportAuthMode: SapTransportAuthMode.gateway,
        basicAuthUser: 'should-not-be-here',
        basicAuthPassword: 'secret',
      );

      expect(
        client.ensureConfigured,
        throwsA(isA<SapConfigurationException>()),
      );
    });

    test('basic mode fails closed when credentials are missing', () {
      final client = SapODataClient(
        baseUrl: baseUrl,
        transportAuthMode: SapTransportAuthMode.basic,
        basicAuthUser: '',
        basicAuthPassword: '',
      );

      expect(
        client.ensureConfigured,
        throwsA(isA<SapConfigurationException>()),
      );
    });
  });
}
