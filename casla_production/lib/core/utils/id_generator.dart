// Core Utilities — ID Generator
// Uses UUID v4 for local IDs and idempotency keys (Spec 7.2)

import 'package:uuid/uuid.dart';

class IdGenerator {
  IdGenerator._();
  static const _uuid = Uuid();

  /// Generate a new UUID v4 for local entity IDs
  static String newId() => _uuid.v4();

  /// Generate a new UUID v4 for idempotency keys (SAP sync)
  static String newIdempotencyKey() => _uuid.v4();
}
