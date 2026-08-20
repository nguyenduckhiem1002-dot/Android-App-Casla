// Test harness — runs the real SQLite engine inside `flutter test`.
//
// The tests exercise the production schema, queries and constraints rather than
// a stand-in: a migration that drops a column or a CHECK that rejects a valid
// quantity has to fail here, not on a supervisor's PDA.

import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Swaps sqflite's platform-channel backend for the bundled native engine.
void initSqfliteFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Points [CaslaDatabase] at a fresh in-memory database for every test in the
/// enclosing file. Call once at the top of `main()`.
///
/// In-memory rather than a temp file so each `openDatabase` call gets its own
/// blank schema — a shared file would carry one test's rows into the next.
/// Tests that need durability across a reopen set their own file path instead;
/// see `database_persistence_test.dart`.
void useInMemoryDatabase() {
  setUpAll(() {
    initSqfliteFfi();
    CaslaDatabase.databasePathOverride = inMemoryDatabasePath;
  });
}
