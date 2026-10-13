import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';

final rememberedLoginProvider = Provider<RememberedLoginStore>((ref) {
  return RememberedLoginStore(const FlutterSecureStorage());
});

class RememberedLogin {
  final String username;
  final String password;
  final String? accountId;

  const RememberedLogin({
    required this.username,
    required this.password,
    this.accountId,
  });
}

/// One credential pair per SAP endpoint, stored only in platform secure storage.
/// Serialize read/modify/write operations so forgetting cannot race a save.
class RememberedLoginStore {
  final FlutterSecureStorage _storage;
  Future<void>? _pending;

  RememberedLoginStore(this._storage);

  String get _key => 'remembered_login_v1:${AppConfig.sapAuthServiceUrl}';

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _pending?.then((_) => operation()) ?? operation();
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<RememberedLogin?> _read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value['username'] is! String ||
          value['password'] is! String ||
          (value['accountId'] != null && value['accountId'] is! String)) {
        return null;
      }
      final username = (value['username'] as String).trim();
      if (username.isEmpty) return null;
      return RememberedLogin(
        username: username,
        password: value['password'] as String,
        accountId: value['accountId'] as String?,
      );
    } on FormatException {
      return null;
    }
  }

  Future<RememberedLogin?> read() => _serial(_read);

  Future<void> _write(RememberedLogin login) => _storage.write(
    key: _key,
    value: jsonEncode({
      'username': login.username,
      'password': login.password,
      'accountId': login.accountId,
    }),
  );

  Future<void> save(RememberedLogin login) => _serial(() => _write(login));

  Future<void> forget() => _serial(() => _storage.delete(key: _key));

  Future<void> updatePasswordForAccount(String accountId, String password) =>
      _serial(() async {
        final login = await _read();
        if (login == null || login.accountId != accountId) return;
        await _write(
          RememberedLogin(
            username: login.username,
            password: password,
            accountId: accountId,
          ),
        );
      });
}
