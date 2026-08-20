// Failure-classification tests.
//
// The distinction these lock down is the one that decides whether a record ever
// reaches SAP: a timeout must stay queued, and a rejected quantity must not.

import 'dart:io';
import 'dart:math';

import 'package:casla_production/core/sync/sync_failure.dart';
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

    test('falls back to a readable default when SAP sends no envelope', () {
      final failure = classifySyncError(
        _dio(DioExceptionType.badResponse, status: 400, body: 'oops'),
      );

      expect(failure.message, contains('400'));
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
