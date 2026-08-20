// SAP Integration — OData Client
// Spec: Section 9, 7.2 (dio)
// Configurable base URL, auth token interceptor, CSRF token handling, logging with redaction

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../../core/config/app_config.dart';

class SapConfigurationException implements Exception {
  final String message;

  const SapConfigurationException(this.message);

  @override
  String toString() => message;
}

class SapODataClient {
  final String baseUrl;
  String? _authToken;
  String? _csrfToken;
  List<String>? _cookies;
  late final Dio dio;
  final _logger = Logger(filter: ProductionFilter());

  SapODataClient({String? baseUrl, String? authToken})
    : baseUrl = _normalizeBaseUrl(baseUrl ?? AppConfig.sapBaseUrl) {
    _authToken = authToken;
    final basicAuthCredentials = _getBasicAuthCredentials();

    dio = Dio(
      BaseOptions(
        baseUrl: this.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Basic $basicAuthCredentials',
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Always use Basic Auth header per SAP NetWeaver/OData requirement
          options.headers['Authorization'] = 'Basic $basicAuthCredentials';

          // Attach session cookies if present
          if (_cookies != null && _cookies!.isNotEmpty) {
            options.headers['Cookie'] = _cookies!.join('; ');
          }

          // Attach CSRF token for non-GET requests
          if (options.method != 'GET' && options.method != 'HEAD') {
            if (_csrfToken != null && _csrfToken!.isNotEmpty) {
              options.headers['x-csrf-token'] = _csrfToken;
            }
          }

          handler.next(options);
        },
        onError: (error, handler) {
          _logger.e(
            'SAP API Error: ${error.response?.statusCode} ${error.message}',
          );
          handler.next(error);
        },
      ),
    );

    // Logging interceptor (with token redaction per Spec Section 10).
    //
    // Debug builds only: request and response bodies carry credentials, and
    // attaching the interceptor in release relied on a downstream level filter
    // to keep them out of the log. Not attaching it at all is the guarantee, and
    // it also drops the per-request redaction cost from production.
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          requestHeader: true,
          responseHeader: true,
          requestBody: true,
          responseBody: true,
          logPrint: (obj) => _logger.d(redactSecrets(obj.toString())),
        ),
      );
    }
  }

  /// Masks credentials in a line destined for the log.
  ///
  /// Dio logs the *encoded* URI, where the single quotes SAP's OData function
  /// imports require appear as `%27`. The original patterns only matched the raw
  /// `password='...'` form, so they silently missed every real request and the
  /// password was printed verbatim. Both forms are covered here.
  @visibleForTesting
  static String redactSecrets(String input) {
    const secretKeys = [
      'password',
      'old_password',
      'new_password',
      'access_token',
      'refresh_token',
    ];

    var out = input.replaceAll(RegExp(r'Basic\s+\S+'), 'Basic [REDACTED]');

    // The separator varies by what is being logged: `password=` in a URI,
    // `password: ` in Dio's map rendering of queryParameters.
    const sep = r'\s*[:=]\s*';

    for (final key in secretKeys) {
      final patterns = <String>[
        "$key$sep'[^']*'", // password='secret'
        '$key$sep"[^"]*"', // password="secret"
        '$key$sep%27.*?%27', // password=%27secret%27  (what Dio prints)
        r'' '$key$sep' r"[^&\s,}\]\[]+", // password=secret
      ];

      for (final pattern in patterns) {
        out = out.replaceAll(
          RegExp(pattern, caseSensitive: false),
          '$key=[REDACTED]',
        );
      }
    }

    return out;
  }

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.endsWith('/')) {
      return trimmed;
    }
    return '$trimmed/';
  }

  void ensureConfigured() {
    final uri = Uri.tryParse(baseUrl);
    final hasHttpHost =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;

    if (!hasHttpHost) {
      throw const SapConfigurationException(
        'Không thể kết nối SAP. Vui lòng kiểm tra cấu hình trong file .env '
        'và chạy ứng dụng với --dart-define-from-file=.env.',
      );
    }

    if (AppConfig.sapBasicAuthUser.isEmpty ||
        AppConfig.sapBasicAuthPassword.isEmpty) {
      throw const SapConfigurationException(
        'Thiếu thông tin xác thực SAP trong file .env. Vui lòng kiểm tra '
        'SAP_BASIC_AUTH_USER và SAP_BASIC_AUTH_PASSWORD.',
      );
    }
  }

  String _getBasicAuthCredentials() {
    return base64Encode(
      utf8.encode(
        '${AppConfig.sapBasicAuthUser}:${AppConfig.sapBasicAuthPassword}',
      ),
    );
  }

  /// Explicitly fetches fresh CSRF Token and Session Cookies from SAP backend.
  /// Uses a clean standalone Dio instance to avoid interceptor recursion.
  Future<String?> fetchCsrfToken() async {
    try {
      ensureConfigured();
      final basicAuthCredentials = _getBasicAuthCredentials();
      final cleanDio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      final response = await cleanDio.get(
        '\$metadata',
        options: Options(
          headers: {
            'Accept': '*/*',
            'Authorization': 'Basic $basicAuthCredentials',
            'x-csrf-token': 'Fetch',
          },
        ),
      );

      // Read CSRF Token from response headers
      final tokenHeader = response.headers['x-csrf-token'];
      if (tokenHeader != null && tokenHeader.isNotEmpty) {
        final token = tokenHeader.first;
        if (token.isNotEmpty && token.toLowerCase() != 'fetch') {
          _csrfToken = token;
          _logger.i('SAP CSRF Token fetched successfully');
        }
      }

      // Read Set-Cookie headers for session persistence
      final setCookieHeaders = response.headers['set-cookie'];
      if (setCookieHeaders != null && setCookieHeaders.isNotEmpty) {
        _cookies = setCookieHeaders.map((c) => c.split(';')[0]).toList();
        _logger.i('SAP Session Cookies fetched');
      }

      return _csrfToken;
    } on SapConfigurationException {
      rethrow;
    } catch (e) {
      _logger.w('Failed to fetch SAP CSRF token: $e');
      return null;
    }
  }

  /// Update auth token (after login/refresh).
  ///
  /// WARNING: this token is *not* sent on requests. The request interceptor
  /// unconditionally sets `Authorization` to the shared Basic service account,
  /// and SAP receives the per-user token only where a caller passes it
  /// explicitly as an `access_token` query parameter. So every call reaches SAP
  /// as the service account, and SAP cannot attribute an action to a person.
  ///
  /// Resolving this is task P4-04 in the remediation plan: either send this
  /// token per request instead of Basic, or drop the field as dead. It is left
  /// in place for now because changing it alters what SAP sees.
  void setAuthToken(String? token) {
    _authToken = token;
  }

  /// Reset CSRF token & cookies (e.g. on logout)
  void resetCsrfSession() {
    _csrfToken = null;
    _cookies = null;
  }

  /// Check if client has a valid auth token
  bool get isAuthenticated => _authToken != null && _authToken!.isNotEmpty;
}

/// Production log filter — disable verbose logging in release
class ProductionFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return kDebugMode || event.level.index >= Level.warning.index;
  }
}
