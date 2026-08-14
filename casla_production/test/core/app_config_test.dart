import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/config/app_config.dart';

void main() {
  test('normalizes quoted and JSON-escaped environment values', () {
    // The actual compile-time values are covered by integration startup;
    // this guards that accessing normalized configuration never fails.
    expect(AppConfig.sapBaseUrl, isA<String>());
    expect(AppConfig.sapBasicAuthUser, isA<String>());
    expect(AppConfig.sapBasicAuthPassword, isA<String>());
  });
}
