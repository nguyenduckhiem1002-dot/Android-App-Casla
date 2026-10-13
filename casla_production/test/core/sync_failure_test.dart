// Failure-classification tests.
//
// The distinction these lock down is the one that decides whether a record ever
// reaches SAP: a timeout must stay queued, and a rejected quantity must not.

import 'dart:io';
import 'dart:math';

import 'package:casla_production/core/sync/sync_failure.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _dio(DioExceptionType type, {int? status, Object? body}) {
  final options = RequestOptions(path: 'ZUI_PROD_RECORD');
  return DioException(
    requestOptions: options,
    type: type,
    response: status == null
        ? null
        : Response<Object?>(
            requestOptions: options,
            statusCode: status,
            data: body,
          ),
  );
}

void main() {
  test('permission failures use their code-specific messages', () {
    expect(
      friendlySapErrorMessage(const SapBusinessError('MISSING_PERMISSION')),
      'Tài khoản không có quyền thực hiện chức năng này.',
    );
    const scopeMessage =
        'Công đoạn được giao không thuộc phiên làm việc được chọn.';
    for (final code in [
      'WORK_CONTEXT_NOT_ALLOWED',
      'WORKER_NOT_ALLOWED',
      'WORK_CONTEXT_MISMATCH',
    ]) {
      expect(friendlySapErrorMessage(SapBusinessError(code)), scopeMessage);
      expect(classifySyncError(SapBusinessError(code)).message, scopeMessage);
    }
  });

  test('an unknown position tells the supervisor where to create it', () {
    const error = SapBusinessError('POSITION_NOT_ACTIVE');

    expect(
      friendlySapErrorMessage(error),
      'Vị trí chưa tồn tại trên hệ thống. Vui lòng tạo ở phần Vị trí.',
    );
    // Retrying the same label cannot succeed until the position exists.
    expect(classifySyncError(error).kind, SyncFailureKind.permanent);
  });

  test('RAP behavior failures show a supportable history message', () {
    expect(
      friendlySapErrorMessage(const SapBusinessError('SABP_BEHV/100')),
      contains('kiểm tra log ST22'),
    );
  });

  test('action wrapper exposes the nested SAP business failure', () {
    const error = SapBusinessError(
      'CONFIRM_INPUT_INVALID',
      message: 'SHIFT_WORK_DATE_MISMATCH',
    );

    expect(
      friendlySapErrorMessage(error),
      contains('Ngày làm việc đã lưu không khớp'),
    );
    final failure = classifySyncError(error);
    expect(failure.code, 'SHIFT_WORK_DATE_MISMATCH');
    expect(failure.kind, SyncFailureKind.permanent);
    expect(failure.message, isNot(contains('CONFIRM_INPUT_INVALID')));
  });

  test('SAP XML parser response is a payload error, not worker rejection', () {
    final error = _dio(
      DioExceptionType.badResponse,
      status: 400,
      body: {
        'error': {
          'code': 'CX_SXML_PARSE_ERROR',
          'message': 'Error while parsing an XML stream',
        },
      },
    );
    try {
      rethrowAsBusinessError(error);
    } catch (converted) {
      final failure = classifySyncError(converted);
      expect(failure.code, 'SAP_PAYLOAD_FORMAT_ERROR');
      expect(failure.kind, SyncFailureKind.permanent);
      expect(failure.message, isNot(contains('XML')));
      expect(failure.message, contains('định dạng'));
    }
  });
  group('transient — the record stays queued', () {
    test('connection timeout', () {
      final failure = classifySyncError(
        _dio(DioExceptionType.connectionTimeout),
      );
      expect(failure.kind, SyncFailureKind.transient);
      expect(failure.code, 'ERR_TIMEOUT');
      expect(failure.isRetryable, isTrue);
    });

    test('send and receive timeouts', () {
      for (final type in [
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(classifySyncError(_dio(type)).kind, SyncFailureKind.transient);
      }
    });

    test('connection error', () {
      expect(
        classifySyncError(_dio(DioExceptionType.connectionError)).kind,
        SyncFailureKind.transient,
      );
    });

    test('a raw socket failure', () {
      expect(
        classifySyncError(const SocketException('no route to host')).kind,
        SyncFailureKind.transient,
      );
    });

    test('5xx from SAP', () {
      for (final status in [500, 502, 503, 504]) {
        final failure = classifySyncError(
          _dio(DioExceptionType.badResponse, status: status),
        );
        expect(failure.kind, SyncFailureKind.transient, reason: '$status');
        expect(failure.code, 'HTTP_$status');
      }
    });

    test('408 and 429 are "come back later", not rejections', () {
      for (final status in [408, 429]) {
        expect(
          classifySyncError(
            _dio(DioExceptionType.badResponse, status: status),
          ).kind,
          SyncFailureKind.transient,
          reason: '$status',
        );
      }
    });
  });

  group('permanent — retrying cannot help', () {
    test('400 and 422 are business-rule rejections', () {
      for (final status in [400, 409, 422]) {
        final failure = classifySyncError(
          _dio(DioExceptionType.badResponse, status: status),
        );
        expect(failure.kind, SyncFailureKind.permanent, reason: '$status');
        expect(failure.isRetryable, isFalse);
      }
    });

    test('404 does not become an infinite retry', () {
      expect(
        classifySyncError(_dio(DioExceptionType.badResponse, status: 404)).kind,
        SyncFailureKind.permanent,
      );
    });

    test('a bad certificate needs an operator, not a backoff timer', () {
      expect(
        classifySyncError(_dio(DioExceptionType.badCertificate)).kind,
        SyncFailureKind.permanent,
      );
    });

    test('an unconfigured SAP endpoint', () {
      expect(
        classifySyncError(const SapConfigurationException('thiếu .env')).kind,
        SyncFailureKind.permanent,
      );
    });
  });

  group('auth', () {
    test('401 and 403 ask for a re-authentication', () {
      for (final status in [401, 403]) {
        expect(
          classifySyncError(
            _dio(DioExceptionType.badResponse, status: status),
          ).kind,
          SyncFailureKind.auth,
          reason: '$status',
        );
      }
    });
  });

  group('error message extraction', () {
    test('reads the nested OData error envelope', () {
      final failure = classifySyncError(
        _dio(
          DioExceptionType.badResponse,
          status: 400,
          body: {
            'error': {
              'message': {'value': 'Số lượng vượt quá phần còn lại'},
            },
          },
        ),
      );

      expect(failure.message, 'Số lượng vượt quá phần còn lại');
    });

    test('reads the flattened form older services return', () {
      final failure = classifySyncError(
        _dio(
          DioExceptionType.badResponse,
          status: 400,
          body: {
            'error': {'message': 'Phân công đã đóng'},
          },
        ),
      );

      expect(failure.message, 'Phân công đã đóng');
    });

    test('reads an OData envelope returned as a JSON string', () {
      final error = _dio(
        DioExceptionType.badResponse,
        status: 400,
        body:
            '{"error":{"code":"BAD_REQUEST",'
            '"message":"SHIFT_NOT_APPLICABLE"}}',
      );

      expect(odataErrorMessage(error), 'SHIFT_NOT_APPLICABLE');
    });

    test('reads the RAP business code from nested reported details', () {
      final error = _dio(
        DioExceptionType.badResponse,
        status: 400,
        body: {
          'error': {
            'code': 'SABP_BEHV/100',
            'message': {'value': 'Business validation failed'},
            'innererror': {
              'errordetails': [
                {
                  'code': 'WORKER_OPERATION_NOT_ALLOWED',
                  'message': 'WORKER_OPERATION_NOT_ALLOWED',
                },
              ],
            },
          },
        },
      );

      expect(odataErrorMessage(error), 'WORKER_OPERATION_NOT_ALLOWED');
      expect(
        () => rethrowAsBusinessError(error),
        throwsA(
          isA<SapBusinessError>().having(
            (item) => item.code,
            'code',
            'WORKER_OPERATION_NOT_ALLOWED',
          ),
        ),
      );
      expect(
        classifySyncError(
          const SapBusinessError(
            'WORKER_OPERATION_NOT_ALLOWED',
            message: 'Business validation failed',
          ),
        ).message,
        'Công nhân không có quyền với bộ phận của công đoạn.',
      );
    });

    test('preserves human SAP text that ends with an uppercase word', () {
      final error = _dio(
        DioExceptionType.badResponse,
        status: 400,
        body: {
          'error': {
            'code': 'SABP_BEHV/100',
            'message': 'Không tìm thấy lệnh sản xuất trên SAP',
          },
        },
      );

      expect(odataErrorMessage(error), 'Không tìm thấy lệnh sản xuất trên SAP');
      expect(
        () => rethrowAsBusinessError(error),
        throwsA(
          isA<SapBusinessError>()
              .having((item) => item.code, 'code', 'SABP_BEHV/100')
              .having(
                (item) => item.message,
                'message',
                'Không tìm thấy lệnh sản xuất trên SAP',
              ),
        ),
      );
    });

    test('identifies a service binding missing the shift parameters', () {
      final error = _dio(
        DioExceptionType.badResponse,
        status: 400,
        body: {
          'error': {
            'code': '/IWCOR/CX_OD_BAD_REQUEST',
            'message': "The parameter 'ShiftID' does not exist",
          },
        },
      );

      expect(odataSafeDiagnostic(error), 'SAP_SHIFT_CONTRACT_OUTDATED');
      expect(
        () => rethrowAsBusinessError(error),
        throwsA(
          isA<SapBusinessError>().having(
            (item) => item.code,
            'code',
            'SAP_SHIFT_CONTRACT_OUTDATED',
          ),
        ),
      );
    });

    test(
      'preserves a namespaced OData code and human message through classification',
      () {
        final error = _dio(
          DioExceptionType.badResponse,
          status: 400,
          body: {
            'error': {
              'code': '/IWCOR/CX_OD_BAD_REQUEST',
              'message': 'Yêu cầu không hợp lệ trên SAP',
            },
          },
        );

        try {
          rethrowAsBusinessError(error);
        } catch (converted) {
          expect(converted, isA<SapBusinessError>());
          final business = converted as SapBusinessError;
          expect(business.code, '/IWCOR/CX_OD_BAD_REQUEST');
          expect(business.message, 'Yêu cầu không hợp lệ trên SAP');

          final failure = classifySyncError(business);
          expect(failure.kind, SyncFailureKind.permanent);
          expect(failure.code, '/IWCOR/CX_OD_BAD_REQUEST');
          expect(failure.message, 'Yêu cầu không hợp lệ trên SAP');
          expect(
            friendlySapErrorMessage(business),
            'Yêu cầu không hợp lệ trên SAP',
          );
        }
      },
    );

    test('does not classify a namespaced token suffix as auth', () {
      final failure = classifySyncError(
        const SapBusinessError('/ZUI/CX_TOKEN_INVALID_OR_EXPIRED'),
      );
      expect(failure.kind, SyncFailureKind.permanent);
      expect(failure.code, '/ZUI/CX_TOKEN_INVALID_OR_EXPIRED');
    });

    test('falls back to a readable default when SAP sends no envelope', () {
      final failure = classifySyncError(
        _dio(DioExceptionType.badResponse, status: 400, body: 'oops'),
      );

      expect(failure.message, contains('400'));
    });
  });

  group('ZUI_PP_OPALLOC / ZUI_MOB_AUTH business codes', () {
    test('new backend codes map by code and preserve retry semantics', () {
      expect(
        friendlySapErrorMessage(
          const SapBusinessError('OPERATION_QUANTITY_EXCEEDED'),
        ),
        contains('Tổng giao vượt sản lượng'),
      );
      expect(
        classifySyncError(
          const SapBusinessError('OPERATION_QUANTITY_EXCEEDED'),
        ).kind,
        SyncFailureKind.transient,
      );
      expect(
        classifySyncError(
          const SapBusinessError(
            'MANAGER_OPERATION_NOT_ALLOWED',
            message: 'backend technical text',
          ),
        ).kind,
        SyncFailureKind.permanent,
      );
      expect(
        friendlySapErrorMessage(
          const SapBusinessError(
            'WORKER_OPERATION_NOT_ALLOWED',
            message: 'backend technical text',
          ),
        ),
        'Công nhân không có quyền với bộ phận của công đoạn.',
      );
      expect(
        classifySyncError(const SapBusinessError('EMPTY_TOKEN')).kind,
        SyncFailureKind.auth,
      );
      expect(
        classifySyncError(
          const SapBusinessError('WORKER_BALANCE_DUPLICATE'),
        ).kind,
        SyncFailureKind.permanent,
      );
      expect(
        classifySyncError(
          const SapBusinessError('UNIT_OF_MEASURE_MISMATCH'),
        ).kind,
        SyncFailureKind.permanent,
      );
    });

    test('TOKEN_INVALID_OR_EXPIRED is refreshable, not permanent', () {
      final failure = classifySyncError(
        const SapBusinessError('TOKEN_INVALID_OR_EXPIRED'),
      );

      expect(failure.kind, SyncFailureKind.auth);
      expect(failure.isRetryable, isTrue);
    });

    test('WORKER_AUTH_FAILED waits for a fresh human verification', () {
      final failure = classifySyncError(
        const SapBusinessError('WORKER_AUTH_FAILED'),
      );

      expect(failure.kind, SyncFailureKind.needsVerification);
      expect(failure.isRetryable, isFalse);
      expect(failure.message, contains('Mật khẩu xác nhận'));
    });

    test(
      'BUSINESS_VALIDATION_FAILED is permanent with an explained message',
      () {
        final failure = classifySyncError(
          const SapBusinessError('BUSINESS_VALIDATION_FAILED'),
        );

        expect(failure.kind, SyncFailureKind.permanent);
        expect(failure.message, isNot(contains('BUSINESS_VALIDATION_FAILED')));
      },
    );

    test(
      'an unrecognized code still fails permanent, code visible for support',
      () {
        final failure = classifySyncError(
          const SapBusinessError('SOME_NEW_CODE_NOT_IN_THE_TABLE'),
        );

        expect(failure.kind, SyncFailureKind.permanent);
        expect(failure.message, contains('SOME_NEW_CODE_NOT_IN_THE_TABLE'));
      },
    );

    test(
      'a SYNC_RECEIPT ambiguity SAP could not resolve stays queued, not FAILED',
      () {
        final failure = classifySyncError(
          const SapReceiptUnconfirmedException('SYNC_RECEIPT_NOT_FOUND'),
        );

        expect(failure.kind, SyncFailureKind.transient);
        expect(failure.isRetryable, isTrue);
      },
    );

    test('a missing worker password needs a human, not an automatic retry', () {
      final failure = classifySyncError(
        const WorkerVerificationRequiredException(),
      );

      expect(failure.kind, SyncFailureKind.needsVerification);
      expect(failure.isRetryable, isFalse);
    });
  });

  group('SyncBackoff', () {
    // Jitter off, so the growth curve itself is under test.
    final backoff = SyncBackoff(random: _FixedRandom(0.5));

    test('grows exponentially from the base delay', () {
      expect(backoff.delayFor(0), SyncBackoff.base);
      expect(backoff.delayFor(1), SyncBackoff.base * 2);
      expect(backoff.delayFor(2), SyncBackoff.base * 4);
    });

    test('caps so a stuck item still retries a few times an hour', () {
      expect(backoff.delayFor(30), SyncBackoff.max);
      expect(backoff.delayFor(1000), SyncBackoff.max);
    });

    test('jitter stays inside ±20%', () {
      final low = SyncBackoff(random: _FixedRandom(0.0)).delayFor(0);
      final high = SyncBackoff(random: _FixedRandom(1.0)).delayFor(0);

      expect(
        low.inMilliseconds,
        (SyncBackoff.base.inMilliseconds * 0.8).round(),
      );
      expect(
        high.inMilliseconds,
        (SyncBackoff.base.inMilliseconds * 1.2).round(),
      );
    });

    test('nextRetryAtUtc lands in the future', () {
      final now = DateTime.utc(2026, 8, 20, 10);
      final at = backoff.nextRetryAtUtc(0, now: now);

      expect(at, now.add(SyncBackoff.base).millisecondsSinceEpoch);
    });
  });
}

/// A [Random] that always hands back the same fraction, so jitter is pinned.
class _FixedRandom implements Random {
  final double _value;

  _FixedRandom(this._value);

  @override
  double nextDouble() => _value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}
