// SAP Integration — OData Client
// Spec: Section 9, 7.2 (dio)
// Configurable base URL, auth token interceptor, logging with redaction

import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

class SapODataClient {
  final String baseUrl;
  String? _authToken;
  late final Dio dio;
  final _logger = Logger(filter: ProductionFilter());

  SapODataClient({
    this.baseUrl = 'https://sap-gateway.caslagroup.vn/',
    String? authToken,
  }) : _authToken = authToken {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ));

    // Auth interceptor
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_authToken != null && _authToken!.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $_authToken';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        _logger.e('SAP API Error: ${error.response?.statusCode} ${error.message}');
        handler.next(error);
      },
    ));

    // Logging interceptor (with token redaction per Spec Section 10)
    dio.interceptors.add(LogInterceptor(
      requestHeader: false,
      responseHeader: false,
      requestBody: true,
      responseBody: true,
      logPrint: (obj) {
        // Redact sensitive data
        final redacted = obj.toString()
            .replaceAll(RegExp(r'Bearer\s+\S+'), 'Bearer [REDACTED]')
            .replaceAll(RegExp(r'"password"\s*:\s*"[^"]*"'), '"password":"[REDACTED]"');
        _logger.d(redacted);
      },
    ));
  }

  /// Update auth token (after login/refresh)
  void setAuthToken(String? token) {
    _authToken = token;
  }

  /// Check if client has a valid auth token
  bool get isAuthenticated => _authToken != null && _authToken!.isNotEmpty;
}

/// Production log filter — disable verbose logging in release
class ProductionFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    // In production, only log warnings and errors
    // For development, log everything
    return true; // TODO: Check kIsRelease
  }
}
