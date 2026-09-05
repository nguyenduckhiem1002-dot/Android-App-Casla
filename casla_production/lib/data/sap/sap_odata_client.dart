// SAP Integration — OData Client
// Spec: Section 9, 7.2 (dio)
// Configurable base URL, transport auth, CSRF token handling, logging with redaction

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
  final SapTransportAuthMode transportAuthMode;
  final String _basicAuthUser;
  final String _basicAuthPassword;
  String? _authToken;
  String? _csrfToken;
  List<String>? _cookies;
  late final Dio dio;
  final _logger = Logger(filter: DebugOnlyLogFilter());

  SapODataClient({
    String? baseUrl,
    String? authToken,
    SapTransportAuthMode? transportAuthMode,
    String? basicAuthUser,
    String? basicAuthPassword,
  }) : baseUrl = _normalizeBaseUrl(baseUrl ?? AppConfig.sapBaseUrl),
       transportAuthMode = transportAuthMode ?? AppConfig.sapTransportAuthMode,
       _basicAuthUser = (basicAuthUser ?? AppConfig.sapBasicAuthUser).trim(),
       _basicAuthPassword =
           (basicAuthPassword ?? AppConfig.sapBasicAuthPassword).trim() {
    _authToken = authToken;

    dio = Dio(
      BaseOptions(
        baseUrl: this.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          ..._transportHeaders(),
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Transport auth is closed and deterministic. In gateway mode an
          // Authorization header must never be inherited from a previous call
          // or accidentally reintroduced by a caller.
          options.headers.remove('Authorization');
          options.headers.addAll(_transportHeaders());

          // Attach session cookies if present.
          if (_cookies != null && _cookies!.isNotEmpty) {
            options.headers['Cookie'] = _cookies!.join('; ');
          }

          // Attach CSRF token for non-GET requests.
          if (options.method != 'GET' && options.method != 'HEAD') {
            if (_csrfToken != null && _csrfToken!.isNotEmpty) {
              options.headers['x-csrf-token'] = _csrfToken;
            }
          }

          handler.next(options);
        },
        onError: (error, handler) {
          _logger.e(
            redactSecrets(
              'SAP API Error: ${error.response?.statusCode} ${error.message}',
            ),
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
        r''
            '$key$sep'
            r"[^&\s,}\]\[]+", // password=secret
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

  Map<String, String> _transportHeaders() {
    if (transportAuthMode == SapTransportAuthMode.gateway) {
      return const <String, String>{};
    }
    return <String, String>{
      'Authorization': 'Basic ${_getBasicAuthCredentials()}',
    };
  }

  void ensureConfigured() {
    final uri = Uri.tryParse(baseUrl);
    final hasHttpHost =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;

    if (!hasHttpHost) {
      throw const SapConfigurationException(
        'Không thể kết nối SAP. Vui lòng kiểm tra SAP_BASE_URL.',
      );
    }

    if (kReleaseMode && uri.scheme != 'https') {
      throw const SapConfigurationException(
        'Bản phát hành chỉ cho phép kết nối SAP qua HTTPS.',
      );
    }

    if (uri.host == 'your-host' || uri.host.endsWith('.example')) {
      throw const SapConfigurationException(
        'SAP_BASE_URL vẫn đang dùng giá trị mẫu.',
      );
    }

    if (kReleaseMode && transportAuthMode != SapTransportAuthMode.gateway) {
      throw const SapConfigurationException(
        'Bản phát hành phải dùng SAP_TRANSPORT_AUTH_MODE=gateway để không '
        'đóng gói shared SAP Basic credential.',
      );
    }

    switch (transportAuthMode) {
      case SapTransportAuthMode.basic:
        if (_basicAuthUser.isEmpty ||
            _basicAuthPassword.isEmpty ||
            _basicAuthUser == 'replace-me' ||
            _basicAuthPassword == 'replace-me') {
          throw const SapConfigurationException(
            'Basic mode chỉ dành cho dev/staging và cần '
            'SAP_BASIC_AUTH_USER/SAP_BASIC_AUTH_PASSWORD hợp lệ.',
          );
        }
      case SapTransportAuthMode.gateway:
        if (_basicAuthUser.isNotEmpty || _basicAuthPassword.isNotEmpty) {
          throw const SapConfigurationException(
            'Gateway mode không cho phép cấu hình SAP_BASIC_AUTH_USER hoặc '
            'SAP_BASIC_AUTH_PASSWORD trong mobile client.',
          );
        }
    }
  }

  String _getBasicAuthCredentials() {
    return base64Encode(utf8.encode('$_basicAuthUser:$_basicAuthPassword'));
  }

  /// Explicitly fetches fresh CSRF Token and Session Cookies from the backend.
  ///
  /// In direct Basic mode the mobile authenticates to SAP itself. In gateway
  /// mode the request intentionally carries no shared Authorization header; the
  /// trusted gateway is responsible for adding its upstream SAP credential.
  /// Uses a clean standalone Dio instance to avoid interceptor recursion.
  Future<String?> fetchCsrfToken() async {
    try {
      ensureConfigured();
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
            'x-csrf-token': 'Fetch',
            ..._transportHeaders(),
          },
        ),
      );

      // Read CSRF Token from response headers.
      final tokenHeader = response.headers['x-csrf-token'];
      if (tokenHeader != null && tokenHeader.isNotEmpty) {
        final token = tokenHeader.first;
        if (token.isNotEmpty && token.toLowerCase() != 'fetch') {
          _csrfToken = token;
          _logger.i('SAP CSRF Token fetched successfully');
        }
      }

      // Read Set-Cookie headers for session persistence.
      final setCookieHeaders = response.headers['set-cookie'];
      if (setCookieHeaders != null && setCookieHeaders.isNotEmpty) {
        _cookies = setCookieHeaders.map((c) => c.split(';')[0]).toList();
        _logger.i('SAP Session Cookies fetched');
      }

      return _csrfToken;
    } on SapConfigurationException {
      rethrow;
    } catch (e) {
      _logger.w(redactSecrets('Failed to fetch SAP CSRF token: $e'));
      return null;
    }
  }

  /// Update the application session token after login/refresh.
  ///
  /// This token remains part of the existing RAP action payload contract and
  /// is intentionally not repurposed as an HTTP Bearer token here. Changing
  /// that would alter the backend authentication contract. Transport mode only
  /// controls whether the mobile itself carries the shared SAP service account.
  void setAuthToken(String? token) {
    _authToken = token;
  }

  /// Reset CSRF token & cookies (e.g. on logout).
  void resetCsrfSession() {
    _csrfToken = null;
    _cookies = null;
  }

  /// Check if client has a valid application auth token.
  bool get isAuthenticated => _authToken != null && _authToken!.isNotEmpty;
}

/// SAP logs are disabled completely outside debug builds. Network exceptions
/// can contain full URLs, including legacy OData query parameters with tokens.
class DebugOnlyLogFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => kDebugMode;
}
