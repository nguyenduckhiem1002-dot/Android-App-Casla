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
  int _transportGeneration = 0;
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
          // Deliberately do not log URI query, headers, request/response body
          // or Dio's error message: each can contain credentials in legacy
          // OData calls. The path/status/type is enough for debug diagnosis.
          if (kDebugMode) {
            _logger.e(
              'SAP request failed: ${error.requestOptions.method} '
              'status=${error.response?.statusCode ?? '-'} '
              'type=${error.type.name}',
            );
          }
          handler.next(error);
        },
      ),
    );

    // Keep debug telemetry metadata-only. Dio's LogInterceptor serializes
    // headers and request/response bodies, where worker passwords, CSRF
    // tokens and cookies can appear. Redacting after serialization is less
    // safe than never serializing the secrets in the first place.
    if (kDebugMode) {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            _logger.d('SAP request: ${options.method}');
            handler.next(options);
          },
        ),
      );
    }
  }

  /// Masks credentials in a line destined for the log.
  ///
  /// Supports SAP's camel-case JSON keys as well as snake-case query keys.
  /// This remains a defence in depth helper for isolated diagnostic strings;
  /// normal request logging above never serializes secret-bearing fields.
  @visibleForTesting
  static String redactSecrets(String input) {
    var out = input.replaceAllMapped(
      RegExp(r'\b(Basic|Bearer)\s+[^\s,;]+', caseSensitive: false),
      (match) => '${match.group(1)} [REDACTED]',
    );

    // Header values are all sensitive as a unit. Handle normal log lines and
    // map-like rendering (`Cookie: ...`) without attempting to preserve a
    // partly-secret value.
    out = out.replaceAllMapped(
      RegExp(
        r'\b(cookie|set-cookie|x-csrf-token)\s*[:=]\s*[^\r\n,}]*',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=[REDACTED]',
    );
    out = out.replaceAllMapped(
      RegExp(
        r'\bauthorization\s*[:=]\s*(?!(?:Basic|Bearer)\s+\[REDACTED\])[^\r\n,}]*',
        caseSensitive: false,
      ),
      (_) => 'Authorization=[REDACTED]',
    );

    const secretKey =
        r'(?:password|old[_-]?password|new[_-]?password|current[_-]?password|worker[_-]?password|access[_-]?token|refresh[_-]?token)';
    out = out.replaceAllMapped(
      RegExp(
        '\\b($secretKey)\\b\\s*[:=]\\s*'
        r'''(?:%27.*?%27|'[^']*'|"[^"]*"|[^&\s,}\]\[]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=[REDACTED]',
    );
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
        break;
      case SapTransportAuthMode.gateway:
        if (_basicAuthUser.isNotEmpty || _basicAuthPassword.isNotEmpty) {
          throw const SapConfigurationException(
            'Gateway mode không cho phép cấu hình SAP_BASIC_AUTH_USER hoặc '
            'SAP_BASIC_AUTH_PASSWORD trong mobile client.',
          );
        }
        break;
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
    final requestGeneration = _transportGeneration;
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

      // A logout or a newer login cleared this transport while the fetch was
      // in flight. Never repopulate its cookies/token afterwards.
      if (requestGeneration != _transportGeneration) return null;

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
    } catch (error) {
      if (kDebugMode) {
        _logger.w('Failed to fetch SAP CSRF token (${error.runtimeType})');
      }
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
    _transportGeneration++;
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
