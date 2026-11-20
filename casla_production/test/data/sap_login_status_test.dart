// ZA_MOB_LoginResult.Status is the only thing an unauthenticated login
// returns about why it was refused. 'F' (wrong password / inactive) and
// 'L' (temporarily locked after repeated failures) must stay distinct on the
// app side: a locked user who keeps retyping only extends the lock.

import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

SapLoginResult _result(String status) => SapLoginResult.fromJson({
  'UserUUID': 'u-1',
  'SessionID': '',
  'AccessToken': '',
  'RefreshToken': '',
  'Status': status,
  'PasswordChangeRequired': false,
});

void main() {
  test("'A' and 'P' are successes, neither is locked", () {
    for (final status in ['A', 'P']) {
      final r = _result(status);
      expect(r.isSuccess, isTrue, reason: status);
      expect(r.isLocked, isFalse, reason: status);
    }
  });

  test("'F' is a plain failure, not a lockout", () {
    final r = _result('F');
    expect(r.isSuccess, isFalse);
    expect(r.isLocked, isFalse);
  });

  test("'L' is a lockout and never a success", () {
    final r = _result('L');
    expect(r.isLocked, isTrue);
    expect(r.isSuccess, isFalse);
  });

  test(
    'lockout and plain-failure messages differ and tell the user to wait',
    () {
      expect(kAccountLockedMessage, isNot(equals(kLoginFailedMessage)));
      expect(kAccountLockedMessage, contains('tạm khóa'));
      expect(kAccountLockedMessage, contains('thử lại sau'));
      expect(kLoginFailedMessage, isNot(contains('khóa')));
    },
  );
}
