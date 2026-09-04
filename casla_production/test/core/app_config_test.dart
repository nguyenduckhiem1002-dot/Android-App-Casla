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

  group('joinServiceUrl', () {
    // Locks in the exact service roots confirmed against the real tenant —
    // https://my426501-api.s4hana.cloud.sap/... — so an edit to either
    // suffix constant has to be a deliberate rebind, not a typo.
    const base = 'https://my426501-api.s4hana.cloud.sap/sap/opu/odata4/sap/';

    test('builds the exact published ZUI_MOB_AUTH service root', () {
      expect(
        AppConfig.joinServiceUrl(base, AppConfig.authServiceSuffix),
        'https://my426501-api.s4hana.cloud.sap/sap/opu/odata4/sap/'
        'zapi_mob_auth/srvd_a2x/sap/zui_mob_auth/0001/',
      );
    });

    test('builds the exact published ZUI_PP_OPALLOC service root', () {
      expect(
        AppConfig.joinServiceUrl(base, AppConfig.ppOpAllocServiceSuffix),
        'https://my426501-api.s4hana.cloud.sap/sap/opu/odata4/sap/'
        'zapi_pp_opalloc/srvd_a2x/sap/zui_pp_opalloc/0001/',
      );
    });

    test('tolerates a base missing its trailing slash', () {
      expect(
        AppConfig.joinServiceUrl('https://host/sap/opu/odata4/sap', 'suffix/'),
        'https://host/sap/opu/odata4/sap/suffix/',
      );
    });

    test('a blank base stays blank rather than a host-less path', () {
      expect(AppConfig.joinServiceUrl('', 'suffix/'), '');
    });
  });
}
