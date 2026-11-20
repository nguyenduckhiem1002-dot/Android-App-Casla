// A refresh that SAP refuses and a refresh that never reached SAP must not
// look the same to the caller: one ends the session, the other must not.

import 'package:casla_production/core/auth/session_refresh.dart';
import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/sap/sap_auth_controller.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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
  late _OfflineClient client;
  late SapAuthController controller;
  Object? Function(RequestOptions request)? answer;

  setUp(() {
    client = _OfflineClient();
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final next = answer!(request);
          if (next is DioException) {
            handler.reject(next);
          } else {
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: next),
            );
          }
        },
      ),
    );
    controller = SapAuthController(client);
  });

  DioException rejectedBySap(RequestOptions request, int status, String text) =>
      DioException(
        requestOptions: request,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: request,
          statusCode: status,
          data: {
            'error': {'code': 'SABP_BEHV/100', 'message': text},
          },
        ),
      );

  test('a refused refresh token is a rejection with SAP\'s code', () async {
    answer = (request) =>
        rejectedBySap(request, 400, 'TOKEN_INVALID_OR_EXPIRED');

    await expectLater(
      controller.refresh(refreshToken: 'dead', deviceId: 'pda'),
      throwsA(
        isA<SessionRefreshRejectedException>().having(
          (e) => e.code,
          'code',
          'TOKEN_INVALID_OR_EXPIRED',
        ),
      ),
    );
  });

  test('a Vietnamese refusal text from ABAP is still a rejection', () async {
    answer = (request) =>
        rejectedBySap(request, 400, 'Refresh token không hợp lệ hoặc hết hạn');

    await expectLater(
      controller.refresh(refreshToken: 'dead', deviceId: 'pda'),
      throwsA(isA<SessionRefreshRejectedException>()),
    );
  });

  test('SAP\'s own "not right now" keeps the session', () async {
    // Since 2026-11-16 the handler answers a lock held by a parallel refresh,
    // or a hashing/UUID failure, with this code on a 4xx: nothing changed on
    // SAP, so it is not a refusal.
    answer = (request) =>
        rejectedBySap(request, 400, 'AUTH_REFRESH_UNAVAILABLE');

    await expectLater(
      controller.refresh(refreshToken: 'still-good', deviceId: 'pda'),
      throwsA(isA<SessionRefreshUnavailableException>()),
    );
  });

  test('a timeout is unavailable, never a rejection', () async {
    answer = (request) => DioException(
      requestOptions: request,
      type: DioExceptionType.receiveTimeout,
    );

    await expectLater(
      controller.refresh(refreshToken: 'maybe-fine', deviceId: 'pda'),
      throwsA(isA<SessionRefreshUnavailableException>()),
    );
  });

  test('a gateway 503 is unavailable, never a rejection', () async {
    answer = (request) => DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: request,
        statusCode: 503,
        data: '<html>Service Unavailable</html>',
      ),
    );

    await expectLater(
      controller.refresh(refreshToken: 'maybe-fine', deviceId: 'pda'),
      throwsA(isA<SessionRefreshUnavailableException>()),
    );
  });

  test('a 4xx without an OData envelope is unavailable', () async {
    // A proxy or captive portal answering 403 with HTML is not SAP refusing
    // the token.
    answer = (request) => DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: request,
        statusCode: 403,
        data: '<html>Forbidden</html>',
      ),
    );

    await expectLater(
      controller.refresh(refreshToken: 'maybe-fine', deviceId: 'pda'),
      throwsA(isA<SessionRefreshUnavailableException>()),
    );
  });

  test('a successful refresh returns the rotated tokens', () async {
    answer = (request) => {
      'UserUUID': 'u-1',
      'SessionID': 's-1',
      'AccessToken': 'access-2',
      'RefreshToken': 'refresh-2',
      'Status': 'A',
      'PasswordChangeRequired': false,
    };

    final result = await controller.refresh(
      refreshToken: 'refresh-1',
      deviceId: 'pda',
    );

    expect(result.isSuccess, isTrue);
    expect(result.refreshToken, 'refresh-2');
  });

  group('changePassword', () {
    Future<void> change() => controller.changePassword(
      accessToken: 'access-1',
      currentPassword: 'old-password',
      newPassword: 'new-password',
      deviceId: 'pda',
    );

    test('an expired access token is its own, recoverable failure', () async {
      // The ABAP handler's exact wording: free text, then the validator code.
      answer = (request) => rejectedBySap(
        request,
        400,
        'Token không hợp lệ: TOKEN_INVALID_OR_EXPIRED',
      );

      await expectLater(
        change(),
        throwsA(
          isA<AccessTokenExpiredException>().having(
            (error) => error.message,
            'message',
            'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
          ),
        ),
      );
    });

    test('the bare code SAP sends since 2026-11-16 is recognised', () async {
      answer = (request) =>
          rejectedBySap(request, 400, 'TOKEN_INVALID_OR_EXPIRED');

      await expectLater(change(), throwsA(isA<AccessTokenExpiredException>()));
    });

    test('a bare DEVICE_MISMATCH gets its Vietnamese message', () async {
      answer = (request) => rejectedBySap(request, 400, 'DEVICE_MISMATCH');

      await expectLater(
        change(),
        throwsA(
          isA<Exception>()
              .having(
                (error) => error,
                'type',
                isNot(isA<AccessTokenExpiredException>()),
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('Token không thuộc thiết bị này'),
              ),
        ),
      );
    });

    test('a token of another device is not treated as expired', () async {
      answer = (request) =>
          rejectedBySap(request, 400, 'Token không hợp lệ: DEVICE_MISMATCH');

      await expectLater(
        change(),
        throwsA(
          isA<Exception>()
              .having(
                (error) => error,
                'type',
                isNot(isA<AccessTokenExpiredException>()),
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('DEVICE_MISMATCH'),
              ),
        ),
      );
    });

    test('a wrong current password keeps SAP\'s own message', () async {
      answer = (request) =>
          rejectedBySap(request, 400, 'Mật khẩu hiện tại không đúng');

      await expectLater(
        change(),
        throwsA(
          isA<Exception>()
              .having(
                (error) => error,
                'type',
                isNot(isA<AccessTokenExpiredException>()),
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('Mật khẩu hiện tại không đúng'),
              ),
        ),
      );
    });
  });
}
