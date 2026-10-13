// Core Database — Casla Production
// Spec: Section 8 (Data model & database), Section 4.7 (Đồng bộ offline)
//
// SQLite-backed store. Everything a worker records survives an app restart, a
// crash, and a dead battery — the sync queue is the app's durability guarantee,
// not a convenience cache, so it must not live in RAM.
//
// The public API is deliberately Map-based and unchanged from the in-memory
// version that preceded it: repositories and screens were already written
// against it, and sqflite returns rows in exactly that shape.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../utils/id_generator.dart';
import '../utils/operation_qr_parser.dart';
import '../../domain/policies/production_math.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/history_work_context.dart';
import 'casla_schema.dart';

/// Maps a `sync_queue.entity_type` onto the table holding the source row.
///
/// Both `PRODUCTION` and `PRODUCTION_RECORD` appear in the wild:
/// `ProductionRepositoryImpl` writes the former, `recordProductionOffline` and
/// the chaos tests write the latter. Accepting both here keeps the sync engine
/// from silently skipping half the queue.
const Map<String, String> _entitySourceTables = {
  'ASSIGNMENT': 'assignments',
  'PRODUCTION': 'production_records',
  'PRODUCTION_RECORD': 'production_records',
  'RECALL': 'recall_records',
  'RECALL_RECORD': 'recall_records',
};

/// A business-rule rejection detected while holding the SQLite transaction.
///
/// UI repositories may validate early for responsiveness, but only this layer
/// can make the check and the insert indivisible when two taps/devices race.
class MutationValidationException implements Exception {
  final String message;

  const MutationValidationException(this.message);

  @override
  String toString() => message;
}

enum SyncFeedFilter { all, pending, verification, failed }

/// Failed SAP writes remain available long enough for the operator to inspect
/// them, then leave the sync feed. The queue row itself is retained for audit
/// and diagnostics; this is a visibility policy, not destructive cleanup.
const syncFailureVisibilityDuration = Duration(minutes: 10);

class SyncFeedPage {
  final List<Map<String, dynamic>> items;
  final bool hasMore;
  final int? nextCreatedAtUtc;
  final String? nextId;
  final int pendingCount;
  final int verificationCount;
  final int failedCount;
  final int totalCount;

  const SyncFeedPage({
    required this.items,
    required this.hasMore,
    required this.nextCreatedAtUtc,
    required this.nextId,
    required this.pendingCount,
    required this.verificationCount,
    required this.failedCount,
    required this.totalCount,
  });
}

class CaslaDatabase {
  static const bool _seedDemoData = bool.fromEnvironment(
    'ENABLE_DEMO_DATA',
    defaultValue: kDebugMode,
  );

  /// Overrides the on-disk location. Tests point this at
  /// `inMemoryDatabasePath` so each case starts from a freshly created schema.
  @visibleForTesting
  static String? databasePathOverride;

  final Future<Database> _database;

  // Change tickers. Each `watch*` re-runs its query whenever the table it reads
  // is written, which keeps the query in SQL instead of re-filtering in Dart.
  final _assignmentController = StreamController<void>.broadcast();
  final _syncQueueController = StreamController<void>.broadcast();
  final _productionController = StreamController<void>.broadcast();
  final _recallController = StreamController<void>.broadcast();
  final _remotePostingController = StreamController<void>.broadcast();

  /// Ticks whenever SAP acknowledges a queued write. The work-history report
  /// cached before that moment no longer matches SAP and should be refreshed.
  Stream<void> get remotePostings => _remotePostingController.stream;

  static CaslaDatabase? _instance;
  static CaslaDatabase get instance {
    return _instance ??= CaslaDatabase._(_open());
  }

  CaslaDatabase._(this._database);

  /// Completes once the schema is open and seeded.
  ///
  /// Call sites do not have to await this — every method below awaits the same
  /// future — but `main()` does, so the first screen never renders against a
  /// database that is still opening.
  Future<void> get ready async => _database;

  /// Drops the singleton so the next `instance` access builds a fresh store.
  ///
  /// Tests share one process; without this every suite inherits whatever rows the
  /// previous one left behind, which makes them order-dependent.
  @visibleForTesting
  static void resetForTesting() {
    _instance?.dispose();
    _instance = null;
  }

  static Future<Database> _open() async {
    final path =
        databasePathOverride ?? p.join(await getDatabasesPath(), 'casla.db');

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          // Orphaned production against a deleted assignment would corrupt every
          // remaining/recall calculation, so the references in the schema are
          // enforced rather than decorative.
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await createSchema(db);
          if (_seedDemoData) await _seedData(db);
        },
        onUpgrade: migrate,
        // sqflite caches open databases by path. Tests all point the override at
        // `:memory:`, so the cache would hand every CaslaDatabase the same
        // handle and one test's teardown would close the database the next test
        // had just opened. The app, on a single real path, still wants the cache.
        singleInstance: databasePathOverride == null,
      ),
    );
  }

  static String _uuid() => IdGenerator.newId();

  // ─── Seed Data ──────────────────────────────────────────────────────
  // Runs once, inside onCreate — a persistent database must not re-seed on
  // every launch or demo rows would pile up.
  //
  // Auth: Handled entirely by SAP (ZUI_USER_QR_API). No local credentials.
  // 6 Employee Demo:
  //   1. Supervisor: MNV00100 — Trần Thị B (Supervisor Tổ Cắt 1-3)
  //   2. Worker SYNCED:  MNV00123 — Nguyễn Văn A (Tổ Cắt 2)
  //   3. Worker PENDING: MNV00147 — Lê Thị C (Tổ Cắt 1)
  //   4. Worker FAILED:  MNV00158 — Phạm Văn D (Tổ Cắt 3)
  //   5. Worker OPEN:    MNV00199 — Hoàng Văn E (Tổ Cắt 2)
  //   6. Worker QR:      NV0001   — Nguyễn Văn A (Công nhân sản xuất)
  static Future<void> _seedData(Database db) async {
    final batch = db.batch();

    void insert(String table, Map<String, Object?> values) =>
        batch.insert(table, values);

    for (final e in <Map<String, Object?>>[
      {
        'id': 'emp-4',
        'ma_nv': 'MNV00100',
        'ten': 'Trần Thị B',
        'bo_phan': 'Supervisor Tổ Cắt 1–3',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'SUPERVISOR',
        'quyen_han': jsonEncode([
          'ASSIGN_QUANTITY',
          'CONFIRM_COMPLETION',
          'RECALL_ASSIGNMENT',
          'VIEW_TEAM_PRODUCTION',
          'VIEW_SYNC_STATUS',
        ]),
        'to_ids': jsonEncode(['team-1', 'team-2', 'team-3']),
      },
      {
        'id': 'emp-1',
        'ma_nv': 'MNV00123',
        'ten': 'Nguyễn Văn A',
        'bo_phan': 'Tổ Cắt 2',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode(['team-2']),
      },
      {
        'id': 'emp-2',
        'ma_nv': 'MNV00147',
        'ten': 'Lê Thị C',
        'bo_phan': 'Tổ Cắt 1',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode(['team-1']),
      },
      {
        'id': 'emp-3',
        'ma_nv': 'MNV00158',
        'ten': 'Phạm Văn D',
        'bo_phan': 'Tổ Cắt 3',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode(['team-3']),
      },
      {
        'id': 'emp-5',
        'ma_nv': 'MNV00199',
        'ten': 'Hoàng Văn E',
        'bo_phan': 'Tổ Cắt 2',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode(['team-2']),
      },
      {
        'id': 'emp-6',
        'ma_nv': 'NV0001',
        'ten': 'Nguyễn Văn A',
        'bo_phan': 'Công nhân sản xuất',
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode(['team-2']),
      },
    ]) {
      insert('employees', e);
    }

    for (final t in <Map<String, Object?>>[
      {
        'id': 'team-1',
        'ma_to': 'TC01',
        'ten_to': 'Tổ Cắt 1',
        'bo_phan': 'Xưởng May',
        'trang_thai': 'ACTIVE',
      },
      {
        'id': 'team-2',
        'ma_to': 'TC02',
        'ten_to': 'Tổ Cắt 2',
        'bo_phan': 'Xưởng May',
        'trang_thai': 'ACTIVE',
      },
      {
        'id': 'team-3',
        'ma_to': 'TC03',
        'ten_to': 'Tổ Cắt 3',
        'bo_phan': 'Xưởng May',
        'trang_thai': 'ACTIVE',
      },
    ]) {
      insert('teams', t);
    }

    for (final o in <Map<String, Object?>>[
      {
        'id': 'ord-1',
        'ma_don_hang': 'DH-2026-00417',
        'ma_qr': 'QR-AKG-L',
        'ma_sp': 'SP-AKG',
        'ten_sp': 'Áo khoác gió — size L',
        'dac_tinh': 'Vải dù 2 lớp, chống nước, màu navy, size L',
        'uom': 'cái',
        'so_luong_don': 1000.0,
        'trang_thai': 'OPEN',
        // Demo-only values — a real order's production_order/operation must
        // come from the actual SAP Manufacturing Order/Operation, entered or
        // scanned separately from the app-internal ma_qr/ma_don_hang above.
        'production_order': '000010001234',
        'operation': '0010',
      },
      {
        'id': 'ord-2',
        'ma_don_hang': 'DH-2026-00391',
        'ma_qr': 'QR-QJN-32',
        'ma_sp': 'SP-QJN',
        'ten_sp': 'Quần jean nam — size 32',
        'dac_tinh': 'Denim 12oz, form slim, size 32',
        'uom': 'cái',
        'so_luong_don': 500.0,
        'trang_thai': 'OPEN',
        'production_order': '000010001235',
        'operation': '0010',
      },
      {
        'id': 'ord-3',
        'ma_don_hang': 'DH-2026-00502',
        'ma_qr': 'QR-ATN-01',
        'ma_sp': 'SP-ATN',
        'ten_sp': 'Áo thun nam Polo',
        'dac_tinh': 'Cotton 100%, cổ bẻ, màu trắng, freesize',
        'uom': 'cái',
        'so_luong_don': 800.0,
        'trang_thai': 'OPEN',
        'production_order': '000010001236',
        'operation': '0010',
      },
    ]) {
      insert('orders', o);
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    for (final a in <Map<String, Object?>>[
      // emp-1: Nguyễn Văn A (Status: SYNCED)
      {
        'id': 'asg-001',
        'nhan_vien_id': 'emp-1',
        'don_hang_id': 'ord-1',
        'to_id': 'team-2',
        'assigned_quantity': 650.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'status': 'OPEN',
        'note': 'Giao ca sáng',
        'created_by': 'MNV00100',
        'occurred_at_utc': now,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'sap_id': '00000000-0000-0000-0000-000000000001',
        'idempotency_key': 'demo-key-001',
        'created_at_utc': now,
      },
      // emp-2: Lê Thị C (Status: PENDING)
      {
        'id': 'asg-003',
        'nhan_vien_id': 'emp-2',
        'don_hang_id': 'ord-3',
        'to_id': 'team-1',
        'assigned_quantity': 320.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'status': 'OPEN',
        'note': null,
        'created_by': 'MNV00100',
        'occurred_at_utc': now,
        'device_id': 'PDA-CT01-A03',
        'sync_status': 'PENDING',
        'idempotency_key': 'demo-key-003',
        'created_at_utc': now,
      },
      // emp-3: Phạm Văn D (Status: FAILED)
      {
        'id': 'asg-004',
        'nhan_vien_id': 'emp-3',
        'don_hang_id': 'ord-1',
        'to_id': 'team-3',
        'assigned_quantity': 300.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'status': 'OPEN',
        'note': null,
        'created_by': 'MNV00100',
        'occurred_at_utc': now,
        'device_id': 'PDA-CT03-A09',
        'sync_status': 'FAILED',
        'idempotency_key': 'demo-key-004',
        'created_at_utc': now,
      },
      // emp-5: Hoàng Văn E (Status: OPEN / CHƯA XÁC NHẬN)
      {
        'id': 'asg-005',
        'nhan_vien_id': 'emp-5',
        'don_hang_id': 'ord-2',
        'to_id': 'team-2',
        'assigned_quantity': 400.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'status': 'OPEN',
        'note': 'Mới giao ca',
        'created_by': 'MNV00100',
        'occurred_at_utc': now,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'sap_id': '00000000-0000-0000-0000-000000000005',
        'idempotency_key': 'demo-key-005',
        'created_at_utc': now,
      },
      // Dữ liệu quá khứ (Hôm qua) để test xem lịch sử quá khứ
      {
        'id': 'asg-002',
        'nhan_vien_id': 'emp-1',
        'don_hang_id': 'ord-2',
        'to_id': 'team-2',
        'assigned_quantity': 200.0,
        'business_date': _yesterdayStr(),
        'shift_id': 'SHIFT_1',
        'status': 'CLOSED',
        'note': 'Đã xong ngày hôm qua',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 86400000,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'sap_id': '00000000-0000-0000-0000-000000000002',
        'idempotency_key': 'demo-key-002',
        'created_at_utc': now - 86400000,
      },
    ]) {
      insert('assignments', a);
    }

    for (final r in <Map<String, Object?>>[
      {
        'id': 'prod-001',
        'phan_cong_id': 'asg-001',
        'quantity': 236.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 7200000,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-001',
        'created_at_utc': now - 7200000,
      },
      {
        'id': 'prod-003',
        'phan_cong_id': 'asg-001',
        'quantity': 200.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 3600000,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-003',
        'created_at_utc': now - 3600000,
      },
      {
        'id': 'prod-005',
        'phan_cong_id': 'asg-003',
        'quantity': 214.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 5400000,
        'device_id': 'PDA-CT01-A03',
        'sync_status': 'PENDING',
        'idempotency_key': 'demo-prod-005',
        'created_at_utc': now - 5400000,
      },
      {
        'id': 'prod-006',
        'phan_cong_id': 'asg-004',
        'quantity': 201.0,
        'business_date': _todayStr(),
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 1800000,
        'device_id': 'PDA-CT03-A09',
        'sync_status': 'FAILED',
        'idempotency_key': 'demo-prod-006',
        'created_at_utc': now - 1800000,
      },
      // Quá khứ
      {
        'id': 'prod-004',
        'phan_cong_id': 'asg-002',
        'quantity': 200.0,
        'business_date': _yesterdayStr(),
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': now - 90000000,
        'device_id': 'PDA-CT02-A17',
        'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-004',
        'created_at_utc': now - 90000000,
      },
    ]) {
      insert('production_records', r);
    }

    for (final s in <Map<String, Object?>>[
      {
        'id': 'sync-001',
        'entity_type': 'PRODUCTION_RECORD',
        'entity_id': 'prod-006',
        'action': 'CREATE',
        'payload_summary': 'Xác nhận hoàn thành · +201 · DH-2026-00417',
        'created_at_utc': now - 1800000,
        'status': 'FAILED',
        'retry_count': 1,
        'last_error_code': 'ERR_VALIDATION',
        'last_error_message': 'Lỗi xác thực số lượng',
        'failure_kind': 'permanent',
        'device_id': 'PDA-CT03-A09',
      },
      {
        'id': 'sync-002',
        'entity_type': 'PRODUCTION_RECORD',
        'entity_id': 'prod-005',
        'action': 'CREATE',
        'payload_summary': 'Xác nhận hoàn thành · +214 · DH-2026-00502',
        'created_at_utc': now - 5400000,
        'status': 'PENDING',
        'retry_count': 0,
        'device_id': 'PDA-CT01-A03',
      },
    ]) {
      insert('sync_queue', s);
    }

    insert('audit_log', {
      'id': 'audit-001',
      'action': 'ASSIGNMENT_CREATED',
      'entity_id': 'asg-001',
      'performed_by': 'MNV00100',
      'occurred_at_utc': now,
    });

    await batch.commit(noResult: true);
  }

  static String _todayStr() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static String _yesterdayStr() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // ─── Row helpers ───────────────────────────────────────────────────
  // sqflite hands back read-only maps; callers mutate and augment rows, so every
  // row is copied out before it leaves this class.
  static List<Map<String, dynamic>> _rows(List<Map<String, Object?>> raw) =>
      raw.map(Map<String, dynamic>.from).toList();

  /// Employees carry two JSON-encoded list columns; every read path expects
  /// them as real `List`s.
  static Map<String, dynamic> _employeeRow(Map<String, Object?> raw) {
    final row = Map<String, dynamic>.from(raw);
    row['quyen_han'] = _decodeList(raw['quyen_han']);
    row['to_ids'] = _decodeList(raw['to_ids']);
    return row;
  }

  static List<String> _decodeList(Object? value) {
    if (value is! String || value.isEmpty) return const [];
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return decoded.map((e) => e.toString()).toList();
  }

  static double _toDouble(Object? value) =>
      value is num ? value.toDouble() : 0.0;

  static double _requireFinitePositive(Object? value, String message) {
    final quantity = _toDouble(value);
    if (!quantity.isFinite || quantity <= 0) {
      throw MutationValidationException(message);
    }
    return quantity;
  }

  static double _requireFiniteNonNegative(Object? value, String message) {
    if (value is! num || !value.toDouble().isFinite || value < 0) {
      throw MutationValidationException(message);
    }
    return value.toDouble();
  }

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  // ─── Auth / Employee Queries ──────────────────────────────────────

  Future<Map<String, dynamic>?> getEmployeeByCode(String code) async {
    final db = await _database;
    final rows = await db.query(
      'employees',
      where: 'ma_nv = ? OR id = ?',
      whereArgs: [code, code],
      limit: 1,
    );
    return rows.isEmpty ? null : _employeeRow(rows.first);
  }

  /// Accepts a QR identity locally without a master-data/scope prerequisite.
  /// Existing authorization metadata is never overwritten by QR input.
  Future<Map<String, dynamic>> acceptWorkerQr({
    required String code,
    String name = '',
    String department = '',
    DateTime? validFrom,
    DateTime? validTo,
  }) async {
    final db = await _database;
    return db.transaction((txn) async {
      await txn.insert('employees', {
        'id': 'qr-worker:$code',
        'ma_nv': code,
        'ten': name.isEmpty ? code : name,
        'bo_phan': department.trim(),
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': '[]',
        'to_ids': '[]',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update(
        'employees',
        {
          if (name.isNotEmpty) 'ten': name,
          if (department.trim().isNotEmpty) 'bo_phan': department.trim(),
          'valid_from': validFrom == null ? null : _dateOnly(validFrom),
          'valid_to': validTo == null ? null : _dateOnly(validTo),
        },
        where: 'ma_nv = ?',
        whereArgs: [code],
      );
      return _employeeRow(
        (await txn.query(
          'employees',
          where: 'ma_nv = ?',
          whereArgs: [code],
          limit: 1,
        )).single,
      );
    });
  }

  /// Stores the validity window carried by a scanned worker card without
  /// changing the authoritative role, team or active status from SAP.
  Future<void> rememberEmployeeQrValidity({
    required String maNv,
    DateTime? validFrom,
    DateTime? validTo,
  }) async {
    final values = <String, Object?>{
      if (validFrom != null) 'valid_from': _dateOnly(validFrom),
      if (validTo != null) 'valid_to': _dateOnly(validTo),
    };
    if (values.isEmpty) return;
    final db = await _database;
    await db.update('employees', values, where: 'ma_nv = ?', whereArgs: [maNv]);
  }

  Future<Map<String, dynamic>?> getEmployeeById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'employees',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _employeeRow(rows.first);
  }

  Future<List<Map<String, dynamic>>> getAllEmployees() async {
    final db = await _database;
    return (await db.query('employees')).map(_employeeRow).toList();
  }

  /// Ensures an employee record exists locally (e.g. cached from SAP).
  Future<void> ensureEmployeeExists({
    required String id,
    required String maNv,
    required String name,
    String department = 'Công nhân sản xuất',
  }) async {
    final db = await _database;
    await db.insert('employees', {
      'id': id,
      'ma_nv': maNv,
      'ten': name,
      'bo_phan': department,
      'trang_thai': 'ACTIVE',
      'vai_tro': 'CONG_NHAN',
      'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
      'to_ids': jsonEncode([]),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Upserts worker identities learned from SAP in one SQLite batch.
  ///
  /// Existing rows keep their role, permissions and team scope. WorkHistory
  /// only tells us WorkerID + name, so replacing a row here would erase
  /// authoritative `to_ids` and could accidentally broaden or narrow scope.
  Future<void> upsertEmployeesBatch(List<Map<String, String>> workers) async {
    if (workers.isEmpty) return;

    final deduplicated = <String, Map<String, String>>{};
    for (final worker in workers) {
      final workerId = worker['worker_id']?.trim() ?? '';
      if (workerId.isEmpty) continue;
      deduplicated[workerId] = worker;
    }
    if (deduplicated.isEmpty) return;

    final db = await _database;
    final batch = db.batch();
    for (final entry in deduplicated.entries) {
      final worker = entry.value;
      final workerId = entry.key;
      final workerName = worker['worker_name']?.trim();
      final name = workerName == null || workerName.isEmpty
          ? workerId
          : workerName;
      final dept =
          worker['department']?.trim() ?? worker['bo_phan']?.trim() ?? '';
      final defaultDept = dept.isNotEmpty ? dept : 'Công nhân sản xuất';
      final teamId = worker['team_id']?.trim() ?? worker['to_id']?.trim() ?? '';
      final toIdsJson = teamId.isNotEmpty
          ? jsonEncode([teamId])
          : jsonEncode(<String>[]);

      batch.rawInsert(
        '''
        INSERT INTO employees (
          id, ma_nv, ten, bo_phan, trang_thai, vai_tro, quyen_han, to_ids
        ) VALUES (?, ?, ?, ?, 'ACTIVE', 'CONG_NHAN', ?, ?)
        ON CONFLICT(ma_nv) DO UPDATE SET
          ten = excluded.ten,
          bo_phan = CASE
            WHEN excluded.bo_phan != 'Công nhân sản xuất' THEN excluded.bo_phan
            WHEN employees.bo_phan IS NULL OR employees.bo_phan = 'Công nhân sản xuất' THEN excluded.bo_phan
            ELSE employees.bo_phan
          END,
          to_ids = CASE
            WHEN excluded.to_ids != '[]' THEN excluded.to_ids
            ELSE employees.to_ids
          END,
          trang_thai = 'ACTIVE'
        ''',
        [
          'sap-worker:$workerId',
          workerId,
          name,
          defaultDept,
          jsonEncode(['VIEW_OWN_PRODUCTION']),
          toIdsJson,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Reads one fully materialized WorkHistory result from the local cache.
  Future<Map<String, dynamic>?> getWorkHistoryCache(String cacheKey) async {
    final db = await _database;
    return db.transaction((txn) async {
      final metaRows = await txn.query(
        'work_history_cache_meta',
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
        limit: 1,
      );
      if (metaRows.isEmpty) return null;

      // A single read transaction prevents a concurrent refresh from handing
      // the UI a new header paired with old child rows (or vice versa).
      final entryRows = await txn.query(
        'work_history_cache_entries',
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
        orderBy: 'sequence_no ASC',
      );
      final workerRows = await txn.query(
        'work_history_cache_workers',
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
        orderBy: 'sequence_no ASC',
      );

      return {
        'meta': Map<String, dynamic>.from(metaRows.single),
        'entries': _rows(entryRows),
        'workers': _rows(workerRows),
      };
    });
  }

  /// Removes a cache namespace after a known authorization rejection. Queue
  /// data is deliberately untouched: it is durable work, not a read cache.
  Future<void> clearWorkHistoryCacheForSubject(String subjectId) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'work_history_cache_meta',
        where: 'subject_id = ?',
        whereArgs: [subjectId],
      );
    });
  }

  /// Marks every history window for one account as stale without deleting its
  /// last-known values. A later read can show the snapshot while refreshing
  /// it from SAP, including when the device is temporarily offline.
  Future<void> expireWorkHistoryCacheForSubject(String subjectId) async {
    final normalizedSubject = subjectId.trim();
    if (normalizedSubject.isEmpty) return;
    final db = await _database;
    await db.update(
      'work_history_cache_meta',
      {'fetched_at_utc': 0},
      where: 'subject_id = ?',
      whereArgs: [normalizedSubject],
    );
  }

  /// Atomically replaces one WorkHistory cache window.
  Future<void> replaceWorkHistoryCache({
    required String cacheKey,
    required String subjectId,
    required String rangeCode,
    String? requestDateFrom,
    String? requestDateTo,
    required String scopeCode,
    required String resultDateFrom,
    required String resultDateTo,
    required bool isTruncated,
    required int fetchedAtUtc,
    required List<Map<String, Object?>> entries,
    required List<Map<String, Object?>> workers,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'work_history_cache_meta',
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
      );
      await txn.insert('work_history_cache_meta', {
        'cache_key': cacheKey,
        'subject_id': subjectId,
        'range_code': rangeCode,
        'request_date_from': requestDateFrom,
        'request_date_to': requestDateTo,
        'scope_code': scopeCode,
        'result_date_from': resultDateFrom,
        'result_date_to': resultDateTo,
        'is_truncated': isTruncated ? 1 : 0,
        'fetched_at_utc': fetchedAtUtc,
      });

      final batch = txn.batch();
      for (var index = 0; index < entries.length; index++) {
        batch.insert('work_history_cache_entries', {
          'cache_key': cacheKey,
          'sequence_no': index,
          ...entries[index],
        });
      }
      for (var index = 0; index < workers.length; index++) {
        batch.insert('work_history_cache_workers', {
          'cache_key': cacheKey,
          'sequence_no': index,
          ...workers[index],
        });
      }
      await batch.commit(noResult: true);

      // Cache retention is bounded independently from the durable outbox.
      // Deleting cache metadata cascades only to its entry/summary children.
      final expiredBefore = DateTime.now()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      await txn.delete(
        'work_history_cache_meta',
        where: 'fetched_at_utc < ?',
        whereArgs: [expiredBefore],
      );
      await _deleteCacheKeysAfterOffset(
        txn,
        where: 'subject_id = ?',
        whereArgs: [subjectId],
        offset: 20,
      );
      await _deleteCacheKeysAfterOffset(txn, offset: 100);
      await _pruneWorkHistoryCacheBytes(txn, maxBytes: 25 * 1024 * 1024);
    });
  }

  Future<void> _deleteCacheKeysAfterOffset(
    Transaction txn, {
    String? where,
    List<Object?>? whereArgs,
    required int offset,
  }) async {
    final clause = where == null ? '' : 'WHERE $where';
    final rows = await txn.rawQuery(
      'SELECT cache_key FROM work_history_cache_meta '
      '$clause ORDER BY fetched_at_utc DESC, cache_key DESC '
      'LIMIT -1 OFFSET ?',
      [...?whereArgs, offset],
    );
    for (final row in rows) {
      await txn.delete(
        'work_history_cache_meta',
        where: 'cache_key = ?',
        whereArgs: [row['cache_key']],
      );
    }
  }

  /// Workers belonging to any of [teamIds].
  ///
  /// This used to ignore its argument and return every worker, which made the
  /// team filter on the overview screen change nothing but the chip label.
  /// An empty [teamIds] means "no scope", not "everything".
  ///
  /// `to_ids` is a JSON array rather than a junction table, so membership is
  /// filtered in Dart. Master data is a few hundred rows at most and is about to
  /// be served straight from SAP; a join table would buy nothing here.
  Future<List<Map<String, dynamic>>> getEmployeesByTeamIds(
    List<String> teamIds,
  ) async {
    if (teamIds.isEmpty) return const [];
    final scope = (await _resolveTeamScopeIds(teamIds)).toSet();
    final db = await _database;
    final rows = await db.query(
      'employees',
      where: 'vai_tro = ?',
      whereArgs: ['CONG_NHAN'],
    );
    return rows
        .map(_employeeRow)
        .where((e) => (e['to_ids'] as List).any(scope.contains))
        .toList();
  }

  /// Manual selection can reuse identities learned from QR/history before SAP
  /// supplies a team. This does not assign team membership or permissions;
  /// SAP still authorizes the write just as it does for a scanned card.
  Future<List<Map<String, dynamic>>> getWorkersForManualSelection(
    List<String> teamIds, {
    DateTime? now,
  }) async {
    if (teamIds.isEmpty) return const [];
    final scope = (await _resolveTeamScopeIds(teamIds)).toSet();
    final db = await _database;
    final today = _dateOnly(now ?? DateTime.now());
    final rows = await db.query(
      'employees',
      where:
          "vai_tro = 'CONG_NHAN' AND trang_thai = 'ACTIVE' "
          "AND (valid_from IS NULL OR valid_from = '' OR valid_from <= ?) "
          "AND (valid_to IS NULL OR valid_to = '' OR valid_to >= ?)",
      whereArgs: [today, today],
      orderBy: 'ten COLLATE NOCASE, ma_nv',
    );
    return rows.map(_employeeRow).where((worker) {
      final teams = worker['to_ids'] as List;
      return teams.isEmpty || teams.any(scope.contains);
    }).toList();
  }

  /// Whether [employeeId] falls inside a supervisor's team scope.
  ///
  /// Previously returned true unconditionally.
  Future<bool> isEmployeeInScope(
    String employeeId,
    List<String> supervisorToIds,
  ) async {
    if (supervisorToIds.isEmpty) return false;
    final employee = await getEmployeeById(employeeId);
    if (employee == null) return false;
    final scope = supervisorToIds.toSet();
    return (employee['to_ids'] as List).any(scope.contains);
  }

  // ─── Team Queries ─────────────────────────────────────────────────
  Future<Set<String>> getAssignedWorkerIdsForShift({
    required List<String> teamIds,
    required String businessDate,
    required String shiftId,
  }) async {
    final scope = await _resolveTeamScopeIds(teamIds);
    if (scope.isEmpty || shiftId.trim().isEmpty) return {};
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT a.nhan_vien_id FROM assignments a '
      'WHERE a.business_date = ? AND a.shift_id = ? '
      "AND COALESCE(a.sync_status, '') != 'FAILED' "
      'AND a.to_id IN (${List.filled(scope.length, '?').join(',')}) '
      'AND a.assigned_quantity '
      '  - COALESCE((SELECT SUM(p.quantity) FROM production_records p '
      '      WHERE p.phan_cong_id = a.id '
      "        AND COALESCE(p.sync_status, 'PENDING') != 'FAILED'), 0) "
      '  - COALESCE((SELECT SUM(p.defect_quantity) FROM production_records p '
      '      WHERE p.phan_cong_id = a.id '
      "        AND COALESCE(p.sync_status, 'PENDING') != 'FAILED'), 0) "
      '  - COALESCE((SELECT SUM(r.quantity) FROM recall_records r '
      '      WHERE r.phan_cong_id = a.id '
      "        AND COALESCE(r.sync_status, 'PENDING') != 'FAILED'), 0) "
      '  > 0.0001',
      [businessDate, shiftId, ...scope],
    );
    return rows.map((row) => row['nhan_vien_id'].toString()).toSet();
  }

  Future<List<Map<String, dynamic>>> getAllTeams() async {
    final db = await _database;
    return _rows(await db.query('teams'));
  }

  /// Resolves both local team ids (`team-1`) and SAP work-center/team codes
  /// (`TC01`) to one scope. SAP authorization commonly returns `ma_to`, while
  /// locally-created assignments and employee records may still reference the
  /// SQLite primary key. Keeping this translation here prevents each screen
  /// from implementing a subtly different scope rule.
  Future<List<String>> _resolveTeamScopeIds(List<String> teamIds) async {
    final requested = teamIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requested.isEmpty) return const [];

    final db = await _database;
    final rows = await db.query('teams', columns: ['id', 'ma_to']);
    final resolved = <String>{...requested};
    for (final row in rows) {
      final id = row['id']?.toString().trim() ?? '';
      final sapCode = row['ma_to']?.toString().trim() ?? '';
      if (requested.contains(id) || requested.contains(sapCode)) {
        if (id.isNotEmpty) resolved.add(id);
        if (sapCode.isNotEmpty) resolved.add(sapCode);
      }
    }
    return resolved.toList(growable: false);
  }

  /// Local team master data visible inside the supplied SAP scope.
  ///
  /// Matching is intentionally done against both the local id and `ma_to` so
  /// the supervisor filter can still show the real team names when SAP sends
  /// authorization scope as business codes.
  Future<List<Map<String, dynamic>>> getTeamsForScope(
    List<String> teamIds,
  ) async {
    final requested = teamIds
        .map((id) => id.trim().toUpperCase())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requested.isEmpty) return const [];

    final db = await _database;
    final rows = await db.query('teams');
    return _rows(rows).where((team) {
      final id = team['id']?.toString().trim().toUpperCase() ?? '';
      final sapCode = team['ma_to']?.toString().trim().toUpperCase() ?? '';
      return requested.contains(id) || requested.contains(sapCode);
    }).toList();
  }

  // ─── Order / Material Queries ─────────────────────────────────────
  Future<List<Map<String, dynamic>>> getOpenOrders() async {
    final db = await _database;
    return _rows(
      await db.query('orders', where: 'trang_thai = ?', whereArgs: ['OPEN']),
    );
  }

  /// Every order regardless of status.
  ///
  /// Display paths must use this, not [getOpenOrders]: an assignment against an
  /// order that has since closed still needs to render its code and product
  /// name, and filtering by OPEN silently drops it into a fallback label.
  Future<List<Map<String, dynamic>>> getAllOrders() async {
    final db = await _database;
    return _rows(await db.query('orders'));
  }

  Future<Map<String, dynamic>?> getOrderById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'orders',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  Future<Map<String, double>> getOperationQuantitySummary({
    required String orderId,
  }) async {
    final db = await _database;
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(o.so_luong_don, 0) AS operation_quantity,
        COALESCE((SELECT SUM(p.quantity) FROM production_records p
          JOIN assignments pa ON pa.id = p.phan_cong_id
          WHERE pa.don_hang_id = ? AND COALESCE(p.sync_status, 'PENDING') != 'FAILED'), 0)
          AS confirmed_quantity,
        COALESCE((SELECT SUM(p.defect_quantity) FROM production_records p
          JOIN assignments pa ON pa.id = p.phan_cong_id
          WHERE pa.don_hang_id = ? AND COALESCE(p.sync_status, 'PENDING') != 'FAILED'), 0)
          AS defect_quantity,
        COALESCE((SELECT SUM(
            a.assigned_quantity - COALESCE((
              SELECT SUM(r.quantity) FROM recall_records r
              WHERE r.phan_cong_id = a.id
                AND COALESCE(r.sync_status, 'PENDING') != 'FAILED'
            ), 0)
          ) FROM assignments a
          WHERE a.don_hang_id = ?
            AND COALESCE(a.sync_status, 'PENDING') != 'FAILED'), 0)
          AS assigned_quantity
      FROM orders o WHERE o.id = ? LIMIT 1
      ''',
      [orderId, orderId, orderId, orderId],
    );
    if (rows.isEmpty) return const {};
    double number(Object? value) => (value as num?)?.toDouble() ?? 0.0;
    final row = rows.single;
    final operation = number(row['operation_quantity']);
    final confirmed = number(row['confirmed_quantity']);
    final defect = number(row['defect_quantity']);
    final assignedQuantity = number(row['assigned_quantity']);
    return {
      'operationQuantity': operation,
      'confirmedQuantity': confirmed,
      'defectQuantity': defect,
      'assignedQuantity': assignedQuantity,
      'remaining': (operation - assignedQuantity).clamp(0.0, double.infinity),
    };
  }

  /// The live SAP keys a mutation against [assignmentId] must resolve to, or
  /// null if the assignment (or its order) doesn't exist, or the order has
  /// never had `production_order`/`operation` filled in.
  ///
  /// A blank value here is not "no order" — it's an order that predates the
  /// SAP live-key fields, or was created without them. Either way, pushing
  /// that mutation to SAP is meaningless, so callers must treat null as
  /// "cannot sync", not as "sync with empty strings".
  Future<({String productionOrder, String operation})?> getSapOperationKeys(
    String assignmentId,
  ) async {
    final assignment = await getAssignmentById(assignmentId);
    if (assignment == null) return null;
    final order = await getOrderById(assignment['don_hang_id'] as String);
    final productionOrder = order?['production_order'] as String?;
    final operation = order?['operation'] as String?;
    if (productionOrder == null ||
        productionOrder.isEmpty ||
        operation == null ||
        operation.isEmpty) {
      return null;
    }
    return (productionOrder: productionOrder, operation: operation);
  }

  Future<String?> getLocalSetting(String key) async {
    final db = await _database;
    final rows = await db.query(
      'local_settings',
      columns: ['setting_value'],
      where: 'setting_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['setting_value']?.toString();
  }

  Future<void> setLocalSetting(String key, String value) async {
    final db = await _database;
    await db.insert('local_settings', {
      'setting_key': key,
      'setting_value': value,
      'updated_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Resolves a scanned or typed code to exactly one order.
  ///
  /// Matching is exact on the identifier fields only. It used to fall back to a
  /// substring match on the product name, so scanning "a" matched nearly every
  /// order in the table and silently returned the first one.
  Future<Map<String, dynamic>?> getOrderByCode(String code) async {
    final searchKey = _extractOrderKey(code);
    if (searchKey.isEmpty) return null;

    final keyLower = searchKey.toLowerCase();
    final db = await _database;
    final rows = await db.query(
      'orders',
      where:
          'LOWER(ma_qr) = ? OR LOWER(ma_don_hang) = ? '
          'OR LOWER(ma_sp) = ? OR LOWER(id) = ?',
      whereArgs: [keyLower, keyLower, keyLower, keyLower],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// Resolves a real operation QR into a local order row.
  ///
  /// The screen shows only [qr.displayProductName], but the raw payload and
  /// SAP keys remain durable in `orders`. The SAP gateway later reads
  /// `production_order` and `operation` from this row for every queued write.
  Future<Map<String, dynamic>?> upsertOrderFromOperationQr(
    OperationQrResult qr,
  ) async {
    if (!qr.isValid ||
        qr.productionOrder.isEmpty ||
        qr.operation.isEmpty ||
        qr.rawPayload.isEmpty) {
      return null;
    }

    final db = await _database;
    final result = await db.transaction((txn) async {
      final List<Map<String, Object?>> matches = await txn.query(
        'orders',
        where: 'production_order = ? AND operation = ?',
        whereArgs: [qr.productionOrder, qr.operation],
        limit: 1,
      );

      // A product code and an order label are display attributes, not an
      // operation identity. Reusing a row through either field would rewrite
      // the live SAP keys of every existing assignment that references it when
      // the same product is scanned at a later operation. Only this exact
      // Production Order + Operation pair may update an existing row.

      final displayName = qr.displayProductName.isNotEmpty
          ? qr.displayProductName
          : 'Lệnh SX ${qr.productionOrder}';
      final uom = qr.unitOfMeasure;
      final quantity = qr.operationQuantity ?? 0.0;
      final values = <String, Object?>{
        'production_order': qr.productionOrder,
        'operation': qr.operation,
        if (qr.operationName.isNotEmpty) 'operation_name': qr.operationName,
        'operation_qr_payload': qr.rawPayload,
        if (qr.plant.isNotEmpty) 'plant': qr.plant,
        if (qr.workCenter.isNotEmpty) 'work_center': qr.workCenter,
        if (qr.productCode.isNotEmpty) 'ma_sp': qr.productCode,
        if (qr.productName.isNotEmpty) 'ten_sp': qr.productName,
        if (qr.salesOrder.isNotEmpty) 'sales_order': qr.salesOrder,
        if (qr.salesOrderItem.isNotEmpty) 'sales_order_item': qr.salesOrderItem,
        if (qr.workCenterDescription.isNotEmpty)
          'dac_tinh': qr.workCenterDescription,
        if (uom.isNotEmpty) 'uom': uom,
        if (qr.operationQuantity != null) 'so_luong_don': quantity,
      };

      String id;
      if (matches.isNotEmpty) {
        id = matches.first['id'] as String;
        await txn.update('orders', values, where: 'id = ?', whereArgs: [id]);
      } else {
        id = _uuid();
        await txn.insert('orders', {
          'id': id,
          'ma_don_hang': qr.orderCode.isNotEmpty
              ? qr.orderCode
              : qr.productionOrder,
          'ma_qr': '${qr.productionOrder}-${qr.operation}',
          'operation_name': qr.operationName,
          'ma_sp': qr.productCode,
          'ten_sp': displayName,
          'dac_tinh': qr.workCenterDescription,
          'uom': uom,
          'so_luong_don': quantity,
          'trang_thai': 'OPEN',
          ...values,
        });
      }

      final rows = await txn.query(
        'orders',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    });
    if (result != null) _notifyAssignments();
    return result;
  }

  /// Pulls the order identifier out of a QR payload.
  ///
  /// Handles both a bare code and a JSON object. The previous implementation
  /// stripped braces and quotes with a regex and fed the result to
  /// `Uri.splitQueryString`, which breaks on any value containing a comma.
  static String _extractOrderKey(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{')) return trimmed;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return trimmed;

      for (final key in const [
        'productCode',
        'orderCode',
        'ma_qr',
        'ma_sp',
        'ma_don_hang',
      ]) {
        final value = decoded[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
    } on FormatException {
      // Not JSON after all — fall through and treat it as a bare code.
    }
    return trimmed;
  }

  // ─── Assignment Queries ───────────────────────────────────────────
  /// Reconcile one SAP allocation, never a worker/operation aggregate. The
  /// caller must establish that [entries] have a single INITIAL_ASSIGN source.
  /// Imported history is a replaceable balance snapshot; real local writes and
  /// their queue/idempotency keys must survive every refresh.
  Future<String> reconcileHistoryConfirmationAssignment({
    required Map<String, dynamic> assignment,
    required List<WorkHistoryEntry> entries,
  }) async {
    String uuid(Object? value) =>
        (value ?? '').toString().replaceAll('-', '').trim().toUpperCase();
    final initial = entries
        .where((e) => e.transactionType == 'INITIAL_ASSIGN')
        .toList();
    if (initial.length != 1 || uuid(initial.single.transactionUuid).isEmpty) {
      throw const FormatException(
        'Chưa xác định được giao dịch giao việc gốc.',
      );
    }
    final source = initial.single;
    final db = await _database;
    final id = await db.transaction((txn) async {
      // A SAP allocation UUID identifies one worker's allocation. Match on it
      // alone: a screen that knows the worker by SAP code and one that knows
      // the local employee id must land on the same row, not insert a second
      // copy (which the unique idempotency key rejects).
      final matches = await txn.query(
        'assignments',
        where: 'don_hang_id = ?',
        whereArgs: [assignment['don_hang_id']],
      );
      final sameSource = matches
          .where((row) => uuid(row['sap_id']) == uuid(source.transactionUuid))
          .toList();
      for (final row in sameSource) {
        if (row['to_id'] != assignment['to_id'] ||
            row['business_date'] != assignment['business_date'] ||
            row['shift_id'] != assignment['shift_id']) {
          throw const FormatException(
            'Lần giao này thuộc bộ phận, ca hoặc ngày khác với lựa chọn hiện '
            'tại. Hãy chọn đúng ca và bộ phận rồi thử lại.',
          );
        }
      }
      if (sameSource.length > 1) {
        throw const FormatException(
          'Có bản ghi giao việc trùng trên thiết bị. Chưa thể xác định số lượng xác nhận an toàn.',
        );
      }
      final existing = sameSource.firstOrNull;
      final targetId = (existing?['id'] ?? assignment['id']) as String;
      if (existing != null && existing['sync_status'] != 'SYNCED') {
        throw const FormatException(
          'Phân công đang đồng bộ. Vui lòng đợi đồng bộ xong rồi xác nhận.',
        );
      }
      if (existing == null) {
        await txn.insert('assignments', {
          ...assignment,
          'assigned_quantity': source.quantity,
        });
      } else {
        await txn.update(
          'assignments',
          {'assigned_quantity': source.quantity},
          where: 'id = ?',
          whereArgs: [targetId],
        );
      }
      double completed = 0, recalled = 0;
      for (final table in ['production_records', 'recall_records']) {
        final isProduction = table == 'production_records';
        final rows = await txn.query(
          table,
          where: 'phan_cong_id = ?',
          whereArgs: [targetId],
        );
        final imported = rows.where((row) {
          final key = row['idempotency_key'].toString();
          return key.startsWith('history-confirm:') ||
              key.startsWith('history-recall:') ||
              key.startsWith('history-balance:');
        }).toList();
        for (final row in imported) {
          final queued = await txn.query(
            'sync_queue',
            columns: ['id'],
            where: 'entity_id = ?',
            whereArgs: [row['id']],
            limit: 1,
          );
          if (queued.isNotEmpty) {
            throw const FormatException(
              'Bản ghi lịch sử đang được đồng bộ. Vui lòng thử lại.',
            );
          }
          await txn.delete(table, where: 'id = ?', whereArgs: [row['id']]);
        }
        final real = rows
            .where(
              (row) =>
                  !imported.contains(row) && row['sync_status'] != 'FAILED',
            )
            .toList();
        final remote = entries
            .where(
              (e) => isProduction
                  ? const [
                      'CONFIRM',
                      'CORRECTION',
                      'REVERSE',
                    ].contains(e.transactionType)
                  : e.transactionType == 'RECALL',
            )
            .toList();
        final remoteIds = remote.map((e) => uuid(e.transactionUuid)).toSet();
        final remoteTotal = remote.fold<double>(
          0,
          (sum, e) =>
              sum +
              (e.transactionType == 'REVERSE'
                  ? -(e.quantity + e.defectQuantity)
                  : e.quantity + e.defectQuantity),
        );
        final remoteDefectTotal = isProduction
            ? remote.fold<double>(
                0,
                (sum, e) =>
                    sum +
                    (e.transactionType == 'REVERSE'
                        ? -e.defectQuantity
                        : e.defectQuantity),
              )
            : 0.0;
        final representedRows = real
            .where((row) => remoteIds.contains(uuid(row['sap_id'])))
            .toList(growable: false);
        final representedQuantity = representedRows.fold<double>(
          0,
          (sum, row) => sum + _toDouble(row['quantity']),
        );
        final representedDefect = representedRows.fold<double>(
          0,
          (sum, row) => sum + _toDouble(row['defect_quantity']),
        );
        final baselineQuantity = ProductionMath.toSapScale(
          remoteTotal - remoteDefectTotal - representedQuantity,
        );
        final baselineDefect = ProductionMath.toSapScale(
          remoteDefectTotal - representedDefect,
        );
        if (baselineQuantity < 0 || baselineDefect < 0) {
          throw const FormatException(
            'Lịch sử có điều chỉnh chưa khớp với giao dịch trên máy. Chưa thể xác nhận số lượng.',
          );
        }
        if (baselineQuantity + baselineDefect > 0) {
          final key = 'history-balance:$table:$targetId';
          await txn.insert(table, {
            'id': key,
            'phan_cong_id': targetId,
            'quantity': baselineQuantity,
            if (isProduction) 'defect_quantity': baselineDefect,
            'unit_of_measure': source.unitOfMeasure,
            'business_date': assignment['business_date'],
            'shift_id': assignment['shift_id'],
            'created_by': 'SAP_HISTORY',
            'occurred_at_utc': assignment['occurred_at_utc'],
            'device_id': assignment['device_id'],
            'sync_status': 'SYNCED',
            'idempotency_key': key,
            'created_at_utc': assignment['created_at_utc'],
            if (!isProduction) 'reason_code': 'OTHER',
            'note': historyImportedAssignmentNote,
          });
        }
        final total =
            baselineQuantity +
            baselineDefect +
            real.fold<double>(
              0,
              (sum, row) =>
                  sum +
                  _toDouble(row['quantity']) +
                  (isProduction ? _toDouble(row['defect_quantity']) : 0),
            );
        if (isProduction) {
          completed = total;
        } else {
          recalled = total;
        }
      }
      await txn.update(
        'assignments',
        {
          'status': source.quantity - completed - recalled > 0.0001
              ? 'OPEN'
              : 'COMPLETED',
        },
        where: 'id = ?',
        whereArgs: [targetId],
      );
      return targetId;
    });
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
    return id;
  }

  Future<void> insertAssignment(Map<String, dynamic> assignment) async {
    final db = await _database;
    await db.insert('assignments', assignment);
    _notifyAssignments();
  }

  /// Commits the durable assignment envelope as one unit.
  Future<void> createAssignmentAtomically({
    required Map<String, dynamic> assignment,
    required Map<String, dynamic> queueItem,
    required Map<String, dynamic> auditLog,
  }) async {
    _requireFinitePositive(
      assignment['assigned_quantity'],
      'Số lượng giao phải là một số dương hợp lệ.',
    );
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('assignments', assignment);
      await txn.insert('sync_queue', queueItem);
      await txn.insert('audit_log', auditLog);
    });
    _notifyAssignments();
    _notifySyncQueue();
  }

  /// The position the worker's assignments for this operation and shift were
  /// made at on this device, newest first; null when none recorded one.
  ///
  /// Rows SAP rejected are skipped: they never became part of the group.
  Future<String?> getGroupAssignmentPosition({
    required String workerId,
    required String orderId,
    required String businessDate,
    required String shiftId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'assignments',
      columns: ['position_id'],
      where:
          'nhan_vien_id = ? AND don_hang_id = ? AND business_date = ? '
          "AND shift_id = ? AND sync_status <> 'FAILED' "
          "AND position_id IS NOT NULL AND TRIM(position_id) <> ''",
      whereArgs: [workerId, orderId, businessDate, shiftId],
      orderBy: 'created_at_utc DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['position_id']?.toString();
  }

  Future<Map<String, dynamic>?> getAssignmentById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'assignments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// Resolves descriptive fields for history rows using the QR order cache.
  /// SAP history is a transaction ledger and may only carry ProductionOrder +
  /// Operation, so this lookup deliberately keys on that immutable pair.
  Future<Map<String, Map<String, dynamic>>> getOrderMetadataBySapKeys(
    Iterable<(String, String)> keys,
  ) async {
    final pairs = keys
        .where((key) => key.$1.trim().isNotEmpty && key.$2.trim().isNotEmpty)
        .map((key) => (key.$1.trim(), key.$2.trim()))
        .toSet()
        .toList(growable: false);
    if (pairs.isEmpty) return const {};
    final db = await _database;
    final where = List.filled(
      pairs.length,
      '(production_order = ? AND operation = ?)',
    ).join(' OR ');
    final args = <Object?>[
      for (final pair in pairs) ...[pair.$1, pair.$2],
    ];
    final rows = await db.query('orders', where: where, whereArgs: args);
    return {
      for (final row in rows)
        '${row['production_order']}\u0000${row['operation']}':
            Map<String, dynamic>.from(row),
    };
  }

  /// Returns only local transactions that are not confirmed by SAP yet for
  /// one exact production order and operation.
  ///
  /// Pending/syncing/verification rows form the device delta. Callers with a
  /// full operation ledger may also include acknowledged writes missing from
  /// that read model, excluding represented SAP transaction identities. Failed
  /// rows never affect the balance.
  ///
  /// [workId], [businessDate] and [shiftId] describe the window of the SAP
  /// report the result is merged with. They narrow only the acknowledged
  /// (SYNCED) rows that report is missing: a one-day report must not be topped
  /// up with this device's postings from other days, which it never covered.
  /// Queued rows are in no SAP report at all, so they always count.
  /// History-import rows are always excluded: they mirror SAP itself.
  Future<Map<String, double>> getPendingOperationQuantitySummary({
    required String productionOrder,
    required String operation,
    String? workId,
    String? businessDate,
    String? shiftId,
    Set<String> representedTransactionIds = const {},
    bool includeSyncedMissingFromHistory = false,
  }) async {
    if (productionOrder.trim().isEmpty || operation.trim().isEmpty) {
      return const {};
    }
    final db = await _database;
    final work = workId?.trim() ?? '';
    final date = businessDate?.trim() ?? '';
    final shift = shiftId?.trim() ?? '';
    String notImported(String alias) =>
        " AND COALESCE($alias.note, '') != ?"
        " AND $alias.idempotency_key NOT LIKE 'history-%'";
    final args = <Object?>[
      productionOrder.trim(),
      operation.trim(),
      historyImportedAssignmentNote,
    ];
    String normalizedId(String value) =>
        value.replaceAll('-', '').trim().toUpperCase();
    final represented = representedTransactionIds.map(normalizedId).toSet()
      ..remove('');
    // Read a single snapshot so a synchronizing row cannot be counted twice
    // across separate assignment/recall/confirmation reads.
    final rows = await db.rawQuery(
      '''
      SELECT 'ASSIGN' AS kind, a.assigned_quantity AS quantity,
        0 AS defect_quantity,
        a.sync_status, a.sap_id, a.to_id, a.business_date, a.shift_id
        FROM assignments a
        JOIN orders o ON o.id = a.don_hang_id
        WHERE o.production_order = ? AND o.operation = ?${notImported('a')}
      UNION ALL
      SELECT 'RECALL', r.quantity, 0, r.sync_status, r.sap_id, a.to_id,
        r.business_date, r.shift_id FROM recall_records r
        JOIN assignments a ON a.id = r.phan_cong_id
        JOIN orders o ON o.id = a.don_hang_id
        WHERE o.production_order = ? AND o.operation = ?${notImported('r')}
          AND a.sync_status != 'FAILED'
      UNION ALL
      SELECT 'CONFIRM', p.quantity, p.defect_quantity, p.sync_status,
        p.sap_id, a.to_id,
        p.business_date, p.shift_id FROM production_records p
        JOIN assignments a ON a.id = p.phan_cong_id
        JOIN orders o ON o.id = a.don_hang_id
        WHERE o.production_order = ? AND o.operation = ?${notImported('p')}
          AND a.sync_status != 'FAILED'
      ''',
      [...args, ...args, ...args],
    );
    bool inReportWindow(Map<String, Object?> row) =>
        (work.isEmpty || row['to_id']?.toString() == work) &&
        (date.isEmpty || row['business_date']?.toString() == date) &&
        (shift.isEmpty || row['shift_id']?.toString() == shift);
    var initial = 0.0;
    var recalled = 0.0;
    var completed = 0.0;
    var defect = 0.0;
    for (final row in rows) {
      final status = row['sync_status']?.toString() ?? 'PENDING';
      final sapId = row['sap_id']?.toString().trim() ?? '';
      if (sapId.isNotEmpty && represented.contains(normalizedId(sapId))) {
        continue;
      }
      final pending = const {
        'PENDING',
        'SYNCING',
        'NEEDS_VERIFICATION',
      }.contains(status);
      // A successful write may reach SAP before its history read model updates.
      // Only include acknowledged rows with an identity we can later
      // deduplicate, and only those the report's window should have held.
      if (!pending &&
          !(includeSyncedMissingFromHistory &&
              status == 'SYNCED' &&
              sapId.isNotEmpty &&
              inReportWindow(row))) {
        continue;
      }
      final quantity = (row['quantity'] as num).toDouble();
      switch (row['kind']) {
        case 'ASSIGN':
          initial += quantity;
        case 'RECALL':
          recalled += quantity;
        case 'CONFIRM':
          completed += quantity;
          defect += (row['defect_quantity'] as num).toDouble();
      }
    }
    return {
      'initialAssignedQuantity': initial,
      'currentAssignedQuantity': initial - recalled,
      'assignedDelta': initial - recalled,
      'recalledQuantity': recalled,
      'completedQuantity': completed,
      'defectQuantity': defect,
    };
  }

  /// Finds descriptive fields from prior history snapshots for one subject.
  /// Only metadata is returned; transaction quantities and statuses always
  /// come from the current SAP response.
  Future<Map<String, Map<String, dynamic>>>
  getHistoryMetadataBySapKeysForSubject(
    String subjectId,
    Iterable<(String, String, String)> keys,
  ) async {
    final triples = keys
        .where(
          (key) =>
              key.$1.trim().isNotEmpty &&
              key.$2.trim().isNotEmpty &&
              key.$3.trim().isNotEmpty,
        )
        .map((key) => (key.$1.trim(), key.$2.trim(), key.$3.trim()))
        .toSet()
        .toList(growable: false);
    if (triples.isEmpty || subjectId.trim().isEmpty) return const {};
    final db = await _database;
    final result = <String, Map<String, dynamic>>{};
    // Keep comfortably below SQLite's variable/expression limits.
    for (var offset = 0; offset < triples.length; offset += 100) {
      final chunk = triples.skip(offset).take(100).toList(growable: false);
      final where = List.filled(
        chunk.length,
        '(e.production_order = ? AND e.operation = ? AND e.plant = ?)',
      ).join(' OR ');
      final args = <Object?>[subjectId.trim()];
      args.addAll([
        for (final triple in chunk) ...[triple.$1, triple.$2, triple.$3],
      ]);
      final rows = await db.rawQuery('''
        SELECT e.production_order, e.operation, e.plant,
               e.operation_name, e.product_name, e.product_code,
               e.sales_order, e.sales_order_item,
               m.fetched_at_utc
        FROM work_history_cache_entries e
        JOIN work_history_cache_meta m ON m.cache_key = e.cache_key
        WHERE m.subject_id = ? AND ($where)
        ORDER BY m.fetched_at_utc DESC
        ''', args);
      for (final row in rows) {
        final key =
            '${row['production_order']}\u0000${row['operation']}\u0000${row['plant']}';
        final merged = result.putIfAbsent(key, () => <String, dynamic>{});
        for (final field in const [
          'operation_name',
          'product_name',
          'product_code',
          'sales_order',
          'sales_order_item',
        ]) {
          if ((merged[field]?.toString().trim() ?? '').isEmpty &&
              (row[field]?.toString().trim() ?? '').isNotEmpty) {
            merged[field] = row[field];
          }
        }
      }
    }
    return result;
  }

  /// Assignments that exist or may still exist on SAP. A FAILED assignment
  /// (rejected by SAP, or dismissed from the sync screen) was never posted and
  /// must not count as assigned work anywhere; the sync screen keeps its own
  /// view of it for Undo.
  Stream<List<Map<String, dynamic>>> watchAssignmentsByWorker(String workerId) {
    return _watch(_assignmentController, () async {
      final db = await _database;
      return _rows(
        await db.query(
          'assignments',
          where: "nhan_vien_id = ? AND COALESCE(sync_status, '') != 'FAILED'",
          whereArgs: [workerId],
          orderBy: 'created_at_utc DESC',
        ),
      );
    });
  }

  Stream<List<Map<String, dynamic>>> watchAllAssignments() {
    return _watch(_assignmentController, () async {
      final db = await _database;
      return _rows(
        await db.query('assignments', orderBy: 'created_at_utc DESC'),
      );
    });
  }

  Stream<Map<String, dynamic>?> watchAssignmentById(String id) {
    return _ticks(_assignmentController).asyncMap((_) => getAssignmentById(id));
  }

  /// Reads display fields and totals for the caller's already-scoped IDs.
  /// Indexed subqueries avoid multiplying production and recall rows in a
  /// join. Chunking stays below SQLite parameter limits; all chunks share one
  /// snapshot so status and totals cannot come from different commits.
  Future<List<Map<String, dynamic>>> getAssignmentDisplayRows(
    Iterable<String> assignmentIds, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) async {
    final ids = assignmentIds.toSet().toList(growable: false);
    if (ids.isEmpty) return [];
    final db = await _database;
    return db.transaction((txn) async {
      final byId = <String, Map<String, dynamic>>{};
      const chunkSize = 400;
      for (var start = 0; start < ids.length; start += chunkSize) {
        final chunk = ids.skip(start).take(chunkSize).toList(growable: false);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final periodArgs = <Object?>[];
        String period(String alias) {
          final clauses = <String>[];
          if (fromBusinessDate != null) {
            clauses.add('$alias.business_date >= ?');
            periodArgs.add(fromBusinessDate);
          }
          if (toBusinessDate != null) {
            clauses.add('$alias.business_date <= ?');
            periodArgs.add(toBusinessDate);
          }
          if (shiftId != null && shiftId.trim().isNotEmpty) {
            clauses.add('$alias.shift_id = ?');
            periodArgs.add(shiftId.trim());
          }
          return clauses.isEmpty ? '' : ' AND ${clauses.join(' AND ')}';
        }

        // One call per subquery, in SQL order: each call appends its own
        // bind values, so reusing a fragment would leave placeholders unbound.
        final productionPeriod = period('p');
        final defectPeriod = period('p');
        final recallPeriod = period('r');
        final rows = await txn.rawQuery(
          '''
          SELECT a.*, e.ma_nv AS worker_code, e.ten AS worker_name,
                 o.ma_don_hang AS order_code, o.ma_sp AS product_code,
                 o.ten_sp AS product_name,
                 o.production_order AS order_production_order,
                 o.operation AS order_operation,
                 o.operation_name AS order_operation_name,
                 o.plant AS order_plant,
                 o.work_center AS order_work_center,
                 -- The unit frozen onto the assignment wins; `o.uom` is
                 -- only the fallback for rows created before v5. Aliased
                 -- away from `unit_of_measure` so it cannot collide with
                 -- the column `a.*` already supplies.
                 COALESCE(NULLIF(a.unit_of_measure, ''), o.uom) AS display_uom,
                 (SELECT COALESCE(SUM(p.quantity), 0)
                  FROM production_records p
                  WHERE p.phan_cong_id = a.id
                    $productionPeriod
                    AND COALESCE(p.sync_status, 'PENDING') != 'FAILED')
                    AS completed_quantity,
                 (SELECT COALESCE(SUM(p.defect_quantity), 0)
                  FROM production_records p
                  WHERE p.phan_cong_id = a.id
                    $defectPeriod
                    AND COALESCE(p.sync_status, 'PENDING') != 'FAILED')
                    AS defect_quantity,
                 (SELECT COALESCE(SUM(r.quantity), 0)
                  FROM recall_records r
                  WHERE r.phan_cong_id = a.id
                    $recallPeriod
                    AND COALESCE(r.sync_status, 'PENDING') != 'FAILED')
                    AS recalled_quantity
          FROM assignments a
          LEFT JOIN employees e ON e.id = a.nhan_vien_id
          LEFT JOIN orders o ON o.id = a.don_hang_id
          WHERE a.id IN ($placeholders)
        ''',
          [...periodArgs, ...chunk],
        );
        for (final row in rows) {
          final value = Map<String, dynamic>.from(row);
          if (fromBusinessDate != null ||
              toBusinessDate != null ||
              shiftId != null) {
            final date = row['business_date'] as String;
            final assignedInPeriod =
                (fromBusinessDate == null ||
                    date.compareTo(fromBusinessDate) >= 0) &&
                (toBusinessDate == null ||
                    date.compareTo(toBusinessDate) <= 0) &&
                (shiftId == null ||
                    shiftId.trim().isEmpty ||
                    row['shift_id'] == shiftId.trim()) &&
                row['sync_status'] != 'FAILED';
            if (!assignedInPeriod) {
              value['assigned_quantity'] = 0.0;
            }
            if (!assignedInPeriod &&
                _toDouble(value['completed_quantity']) == 0 &&
                _toDouble(value['defect_quantity']) == 0 &&
                _toDouble(value['recalled_quantity']) == 0) {
              continue;
            }
          }
          byId[row['id'] as String] = value;
        }
      }
      return [
        for (final id in ids)
          if (byId.containsKey(id)) byId[id]!,
      ];
    });
  }

  Stream<List<Map<String, dynamic>>> watchAssignmentsByTeams(
    List<String> teamIds,
  ) {
    return _watch(_assignmentController, () async {
      if (teamIds.isEmpty) return const <Map<String, dynamic>>[];
      final db = await _database;
      final resolvedTeamIds = await _resolveTeamScopeIds(teamIds);
      if (resolvedTeamIds.isEmpty) return const <Map<String, dynamic>>[];
      final placeholders = List.filled(resolvedTeamIds.length, '?').join(', ');
      return _rows(
        await db.query(
          'assignments',
          // See watchAssignmentsByWorker: never count FAILED assignments.
          where:
              "to_id IN ($placeholders) AND COALESCE(sync_status, '') != 'FAILED'",
          whereArgs: resolvedTeamIds,
          orderBy: 'created_at_utc DESC',
        ),
      );
    });
  }

  Future<void> updateAssignmentStatus(
    String id,
    String status,
    String syncStatus,
  ) async {
    final db = await _database;
    await db.update(
      'assignments',
      {'status': status, 'sync_status': syncStatus},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyAssignments();
  }

  void _notifyAssignments() => _emit(_assignmentController);

  // ─── Computed helpers ──────────────────────────────────────────────
  Future<double> getEffectiveAssigned(String assignmentId) async {
    final assignment = await getAssignmentById(assignmentId);
    final assigned = _toDouble(assignment?['assigned_quantity']);
    final recalled = await getRecalledQuantity(assignmentId);
    return assigned - recalled;
  }

  Future<double> getRemaining(String assignmentId) async {
    final effective = await getEffectiveAssigned(assignmentId);
    final completed = await getCompletedQuantity(assignmentId);
    final defect = await getDefectQuantity(assignmentId);
    final remaining = effective - completed - defect;
    return remaining < 0 ? 0 : remaining;
  }

  // ─── Production Record Queries ────────────────────────────────────
  Future<void> insertProductionRecord(Map<String, dynamic> record) async {
    final db = await _database;
    await db.insert('production_records', record);
    _notifyProduction();
    _notifyAssignments();
  }

  /// Commits a production record, its queue item and audit event together.
  Future<void> recordProductionAtomically({
    required Map<String, dynamic> record,
    required Map<String, dynamic> queueItem,
    required Map<String, dynamic> auditLog,
    double? expectedRemaining,
  }) async {
    final assignmentId = record['phan_cong_id']?.toString();
    if (assignmentId == null || assignmentId.isEmpty) {
      throw const MutationValidationException('Phân công không tồn tại.');
    }
    final quantity = _requireFiniteNonNegative(
      record['quantity'],
      'Số lượng hoàn thành không hợp lệ.',
    );
    final defectQuantity = _requireFiniteNonNegative(
      record['defect_quantity'] ?? 0,
      'Số lượng phế không hợp lệ.',
    );
    if (quantity + defectQuantity <= 0) {
      throw const MutationValidationException(
        'Số hoàn thành và số phế phải có ít nhất một giá trị lớn hơn 0.',
      );
    }

    final db = await _database;
    await db.transaction((txn) async {
      final assignmentRows = await txn.query(
        'assignments',
        columns: ['assigned_quantity', 'status'],
        where: 'id = ?',
        whereArgs: [assignmentId],
        limit: 1,
      );
      if (assignmentRows.isEmpty) {
        throw const MutationValidationException('Phân công không tồn tại.');
      }

      final assignment = assignmentRows.single;
      if ((assignment['status']?.toString().toUpperCase() ?? '') != 'OPEN') {
        throw const MutationValidationException(
          'Phân công đã đóng hoặc bị thu hồi.',
        );
      }

      final completedRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity + defect_quantity), 0) AS total '
        'FROM production_records WHERE phan_cong_id = ? '
        "AND COALESCE(sync_status, '') != 'FAILED'",
        [assignmentId],
      );
      final recalledRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        'FROM recall_records WHERE phan_cong_id = ? '
        "AND COALESCE(sync_status, '') != 'FAILED'",
        [assignmentId],
      );
      final assigned = _toDouble(assignment['assigned_quantity']);
      final completed = _toDouble(completedRows.single['total']);
      final recalled = _toDouble(recalledRows.single['total']);
      final remaining = (assigned - recalled - completed)
          .clamp(0.0, double.infinity)
          .toDouble();
      if (expectedRemaining != null &&
          ProductionMath.toSapScale(expectedRemaining) !=
              ProductionMath.toSapScale(remaining)) {
        throw const MutationValidationException(
          'Số lượng còn lại đã thay đổi. Vui lòng mở lại và kiểm tra số liệu.',
        );
      }
      // More than what is left may be confirmed: the supervisor is warned on
      // the form, and the assignment simply closes with nothing remaining.
      await txn.insert('production_records', record);
      if (remaining - quantity - defectQuantity <= 0.0001) {
        await txn.update(
          'assignments',
          {'status': 'COMPLETED'},
          where: 'id = ?',
          whereArgs: [assignmentId],
        );
      }
      await txn.insert('sync_queue', queueItem);
      await txn.insert('audit_log', auditLog);
    });
    _notifyProduction();
    _notifyAssignments();
    _notifySyncQueue();
  }

  /// Writes a production record straight to the store, bypassing every business
  /// rule.
  ///
  /// Production code must go through [ProductionRepository.recordProduction],
  /// which enforces the assignment status and the remaining-quantity ceiling.
  /// This entry point exists only so tests can seed the sync queue directly.
  @visibleForTesting
  Future<void> recordProductionOffline({
    required String assignmentId,
    required double quantity,
    double defectQuantity = 0,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    required String deviceId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'prod-${_uuid()}';
    await insertProductionRecord({
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'defect_quantity': defectQuantity,
      'business_date': businessDate,
      'shift_id': shiftId,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'device_id': deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': 'idem-${_uuid()}',
      'created_at_utc': now,
    });
    await insertSyncQueueItem({
      'id': 'sync-${_uuid()}',
      'entity_type': 'PRODUCTION_RECORD',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary':
          'Xác nhận hoàn thành · +${quantity.toStringAsFixed(0)}',
      'created_at_utc': now,
      'retry_count': 0,
      'last_error_code': null,
      'last_error_message': null,
      'device_id': deviceId,
    });
  }

  Future<double> getCompletedQuantity(String assignmentId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) AS total '
      "FROM production_records WHERE phan_cong_id = ? "
      "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
      [assignmentId],
    );
    return _toDouble(rows.first['total']);
  }

  Future<double> getDefectQuantity(String assignmentId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(defect_quantity), 0) AS total '
      "FROM production_records WHERE phan_cong_id = ? "
      "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
      [assignmentId],
    );
    return _toDouble(rows.first['total']);
  }

  Future<Map<String, double>> getDefectQuantitiesByAssignment() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT phan_cong_id, SUM(defect_quantity) AS total '
      "FROM production_records WHERE COALESCE(sync_status, 'PENDING') != 'FAILED' "
      'GROUP BY phan_cong_id',
    );
    return {
      for (final row in rows)
        row['phan_cong_id'].toString(): _toDouble(row['total']),
    };
  }

  /// Completed totals for every assignment, in one pass.
  ///
  /// Callers that need totals for a list of assignments must use this rather
  /// than calling [getCompletedQuantity] per assignment — that turns one
  /// aggregate query into N of them.
  Future<Map<String, double>> getCompletedQuantitiesByAssignment() async {
    return _totalsByAssignment('production_records');
  }

  Future<Map<String, double>> _totalsByAssignment(String table) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT phan_cong_id, SUM(quantity) AS total '
      "FROM $table WHERE COALESCE(sync_status, 'PENDING') != 'FAILED' "
      'GROUP BY phan_cong_id',
    );
    return {
      for (final row in rows)
        row['phan_cong_id'].toString(): _toDouble(row['total']),
    };
  }

  Future<double> getTodayCompleted(String workerId, String businessDate) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(p.quantity), 0) AS total '
      'FROM production_records p '
      'JOIN assignments a ON a.id = p.phan_cong_id '
      "WHERE a.nhan_vien_id = ? AND p.business_date = ? "
      "AND COALESCE(p.sync_status, 'PENDING') != 'FAILED'",
      [workerId, businessDate],
    );
    return _toDouble(rows.first['total']);
  }

  Stream<List<Map<String, dynamic>>> watchRecordsByAssignment(
    String assignmentId,
  ) {
    return _watch(_productionController, () async {
      final db = await _database;
      return _rows(
        await db.query(
          'production_records',
          where: 'phan_cong_id = ?',
          whereArgs: [assignmentId],
          orderBy: 'occurred_at_utc DESC',
        ),
      );
    });
  }

  void _notifyProduction() => _emit(_productionController);

  Future<List<Map<String, dynamic>>> getProductionHistory(
    String employeeId, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) async {
    final db = await _database;
    final where = StringBuffer('a.nhan_vien_id = ?');
    final args = <Object?>[employeeId];
    // Balance snapshots are already represented by the SAP history ledger.
    // Include them in assignment validation, never as an extra visible event.
    where.write(' AND COALESCE(p.note, \'\') != ?');
    args.add(historyImportedAssignmentNote);

    if (fromBusinessDate != null) {
      where.write(' AND p.business_date >= ?');
      args.add(fromBusinessDate);
    }
    if (toBusinessDate != null) {
      where.write(' AND p.business_date <= ?');
      args.add(toBusinessDate);
    }
    final normalizedShiftId = shiftId?.trim() ?? '';
    if (normalizedShiftId.isNotEmpty) {
      where.write(' AND p.shift_id = ?');
      args.add(normalizedShiftId);
    }

    return _rows(
      await db.rawQuery('''
        SELECT p.*,
               COALESCE(o.ten_sp, 'Không rõ sản phẩm') AS ten_sp,
               a.don_hang_id AS ma_don_hang,
               a.to_id AS work_context_id,
               o.plant AS plant,
               o.work_center AS work_center,
               o.production_order AS production_order,
               o.operation AS operation,
               o.operation_name AS operation_name,
               o.ma_sp AS ma_sp,
               COALESCE(e.ten, p.created_by) AS nguoi_xac_nhan
        FROM production_records p
        JOIN assignments a ON a.id = p.phan_cong_id
        LEFT JOIN orders o ON o.id = a.don_hang_id
        LEFT JOIN employees e ON e.ma_nv = p.created_by
        WHERE $where
        ORDER BY p.occurred_at_utc DESC
      ''', args),
    );
  }

  Stream<List<Map<String, dynamic>>> watchProductionHistory(
    String employeeId, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) {
    return _watch(
      _productionController,
      () => getProductionHistory(
        employeeId,
        fromBusinessDate: fromBusinessDate,
        toBusinessDate: toBusinessDate,
        shiftId: shiftId,
      ),
    );
  }

  /// Confirmation and recall rows recorded against [assignmentIds], FAILED
  /// ones excluded: `kind` (CONFIRM/RECALL), quantity, sync status, SAP id and
  /// idempotency key. Used to attribute SAP's ledger rows to allocations.
  Future<List<Map<String, dynamic>>> getConsumptionRowsForAssignments(
    List<String> assignmentIds,
  ) async {
    final ids = assignmentIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    final db = await _database;
    final placeholders = List.filled(ids.length, '?').join(',');
    return _rows(
      await db.rawQuery(
        '''
        SELECT 'CONFIRM' AS kind, phan_cong_id, quantity, defect_quantity,
               sync_status, sap_id, idempotency_key
        FROM production_records
        WHERE phan_cong_id IN ($placeholders)
          AND COALESCE(sync_status, 'PENDING') != 'FAILED'
        UNION ALL
        SELECT 'RECALL', phan_cong_id, quantity, 0, sync_status, sap_id,
               idempotency_key
        FROM recall_records
        WHERE phan_cong_id IN ($placeholders)
          AND COALESCE(sync_status, 'PENDING') != 'FAILED'
        ''',
        [...ids, ...ids],
      ),
    );
  }

  /// Every local assignment, confirmation and recall in a team scope and
  /// business-date window, flattened for [buildLocalPendingLedger].
  ///
  /// History-import rows are excluded: they mirror the SAP report itself (or
  /// a synthetic balance), so overlaying them would count SAP twice.
  Future<List<Map<String, dynamic>>> getLocalLedgerRows({
    required List<String> teamIds,
    required String fromBusinessDate,
    required String toBusinessDate,
    String? shiftId,
  }) async {
    final scope = await _resolveTeamScopeIds(teamIds);
    if (scope.isEmpty) return const [];
    final db = await _database;
    final shift = shiftId?.trim() ?? '';
    final placeholders = List.filled(scope.length, '?').join(',');
    List<Object?> args() => [
      fromBusinessDate,
      toBusinessDate,
      if (shift.isNotEmpty) shift,
      ...scope,
      historyImportedAssignmentNote,
    ];
    String recordQuery(String table, String kind) =>
        '''
        SELECT '$kind' AS kind, a.nhan_vien_id AS worker_id,
               e.ma_nv AS worker_code, t.quantity,
               ${table == 'production_records' ? 't.defect_quantity' : '0'} AS defect_quantity,
               COALESCE(t.unit_of_measure, a.unit_of_measure) AS unit_of_measure,
               t.sync_status, t.sap_id, t.idempotency_key
        FROM $table t
        JOIN assignments a ON a.id = t.phan_cong_id
        LEFT JOIN employees e ON e.id = a.nhan_vien_id
        WHERE COALESCE(a.sync_status, '') != 'FAILED'
          AND t.business_date >= ? AND t.business_date <= ?
          ${shift.isEmpty ? '' : 'AND t.shift_id = ?'}
          AND a.to_id IN ($placeholders)
          AND COALESCE(t.note, '') != ?
          AND t.idempotency_key NOT LIKE 'history-%'
        ''';
    final rows = await db.rawQuery(
      '''
      SELECT 'ASSIGN' AS kind, a.nhan_vien_id AS worker_id,
             e.ma_nv AS worker_code, a.assigned_quantity AS quantity,
             0 AS defect_quantity,
             a.unit_of_measure, a.sync_status, a.sap_id, a.idempotency_key
      FROM assignments a
      LEFT JOIN employees e ON e.id = a.nhan_vien_id
      WHERE COALESCE(a.sync_status, '') != 'FAILED'
        AND a.business_date >= ? AND a.business_date <= ?
        ${shift.isEmpty ? '' : 'AND a.shift_id = ?'}
        AND a.to_id IN ($placeholders)
        AND COALESCE(a.note, '') != ?
        AND a.idempotency_key NOT LIKE 'history-%'
      UNION ALL
      ${recordQuery('production_records', 'CONFIRM')}
      UNION ALL
      ${recordQuery('recall_records', 'RECALL')}
      ''',
      [...args(), ...args(), ...args()],
    );
    return _rows(rows);
  }

  /// [getLocalLedgerRows], re-run on every assignment, confirmation or recall
  /// write — including a queue item turning SYNCED.
  Stream<List<Map<String, dynamic>>> watchLocalLedgerRows({
    required List<String> teamIds,
    required String fromBusinessDate,
    required String toBusinessDate,
    String? shiftId,
  }) {
    return _watchTicks(
      () => _ticksAny([
        _assignmentController,
        _productionController,
        _recallController,
      ]),
      () => getLocalLedgerRows(
        teamIds: teamIds,
        fromBusinessDate: fromBusinessDate,
        toBusinessDate: toBusinessDate,
        shiftId: shiftId,
      ),
    );
  }

  // ─── Recall Record Queries ────────────────────────────────────────
  Stream<List<Map<String, dynamic>>> watchRecallHistory(
    String employeeId, {
    required String fromBusinessDate,
    required String toBusinessDate,
    String? shiftId,
  }) {
    return _watch(_recallController, () async {
      final db = await _database;
      final shift = shiftId?.trim() ?? '';
      return _rows(
        await db.rawQuery(
          '''
        SELECT r.*, a.to_id AS work_context_id,
               o.plant, o.work_center, o.production_order, o.operation,
               o.operation_name, o.ten_sp, o.ma_sp
        FROM recall_records r
        JOIN assignments a ON a.id = r.phan_cong_id
        LEFT JOIN orders o ON o.id = a.don_hang_id
        WHERE a.nhan_vien_id = ? AND r.business_date >= ?
          AND r.business_date <= ?
          AND COALESCE(r.note, '') != ?
          ${shift.isEmpty ? '' : 'AND r.shift_id = ?'}
        ORDER BY r.occurred_at_utc DESC, r.id DESC
      ''',
          [
            employeeId,
            fromBusinessDate,
            toBusinessDate,
            historyImportedAssignmentNote,
            if (shift.isNotEmpty) shift,
          ],
        ),
      );
    });
  }

  Future<void> insertRecallRecord(Map<String, dynamic> record) async {
    final db = await _database;
    await db.insert('recall_records', record);
    _notifyRecalls();
    _notifyAssignments();
  }

  /// Commits a recall record, its queue item and audit event together.
  Future<void> recallAssignmentAtomically({
    required Map<String, dynamic> record,
    required Map<String, dynamic> queueItem,
    required Map<String, dynamic> auditLog,
  }) async {
    final assignmentId = record['phan_cong_id']?.toString();
    if (assignmentId == null || assignmentId.isEmpty) {
      throw const MutationValidationException('Phân công không tồn tại.');
    }
    final quantity = _requireFinitePositive(
      record['quantity'],
      'Số lượng thu hồi phải là một số dương hợp lệ.',
    );
    final reasonCode = record['reason_code']?.toString();
    final note = record['note']?.toString();
    if (reasonCode == 'OTHER' && (note == null || note.trim().isEmpty)) {
      throw const MutationValidationException(
        'Vui lòng nhập ghi chú khi chọn lý do "Khác".',
      );
    }

    final db = await _database;
    await db.transaction((txn) async {
      final assignmentRows = await txn.query(
        'assignments',
        columns: ['assigned_quantity', 'status'],
        where: 'id = ?',
        whereArgs: [assignmentId],
        limit: 1,
      );
      if (assignmentRows.isEmpty) {
        throw const MutationValidationException('Phân công không tồn tại.');
      }

      final assignment = assignmentRows.single;
      if ((assignment['status']?.toString().toUpperCase() ?? '') != 'OPEN') {
        throw const MutationValidationException(
          'Phân công đã đóng hoặc bị thu hồi.',
        );
      }

      final completedRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity + defect_quantity), 0) AS total '
        "FROM production_records WHERE phan_cong_id = ? "
        "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
        [assignmentId],
      );
      final recalledRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        "FROM recall_records WHERE phan_cong_id = ? "
        "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
        [assignmentId],
      );
      final assigned = _toDouble(assignment['assigned_quantity']);
      final completed = _toDouble(completedRows.single['total']);
      final recalled = _toDouble(recalledRows.single['total']);
      final maxRecall = (assigned - completed - recalled)
          .clamp(0.0, double.infinity)
          .toDouble();
      if (quantity > maxRecall + 0.0001) {
        throw MutationValidationException(
          'Số lượng thu hồi vượt quá hạn mức tối đa (${maxRecall.toInt()}).',
        );
      }

      await txn.insert('recall_records', record);
      if (maxRecall - quantity <= 0.0001) {
        await txn.update(
          'assignments',
          {'status': 'RECALLED'},
          where: 'id = ?',
          whereArgs: [assignmentId],
        );
      }
      await txn.insert('sync_queue', queueItem);
      await txn.insert('audit_log', auditLog);
    });
    _notifyRecalls();
    _notifyAssignments();
    _notifySyncQueue();
  }

  Future<double> getRecalledQuantity(String assignmentId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) AS total '
      "FROM recall_records WHERE phan_cong_id = ? "
      "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
      [assignmentId],
    );
    return _toDouble(rows.first['total']);
  }

  /// Recalled totals for every assignment, in one pass. See
  /// [getCompletedQuantitiesByAssignment] for why the per-id variant is unsafe
  /// in a loop.
  Future<Map<String, double>> getRecalledQuantitiesByAssignment() async {
    return _totalsByAssignment('recall_records');
  }

  Stream<List<Map<String, dynamic>>> watchRecallsByAssignment(
    String assignmentId,
  ) {
    return _watch(_recallController, () async {
      final db = await _database;
      return _rows(
        await db.query(
          'recall_records',
          where: 'phan_cong_id = ?',
          whereArgs: [assignmentId],
          orderBy: 'occurred_at_utc DESC',
        ),
      );
    });
  }

  void _notifyRecalls() => _emit(_recallController);

  // ─── Sync Queue Queries ───────────────────────────────────────────
  Future<void> insertSyncQueueItem(Map<String, dynamic> item) async {
    final db = await _database;
    await db.insert('sync_queue', item);
    _notifySyncQueue();
  }

  Stream<List<Map<String, dynamic>>> watchSyncQueue() {
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(await db.query('sync_queue'));
    });
  }

  Stream<List<Map<String, dynamic>>> watchSyncFeed({
    String? actorId,
    List<String>? teamIds,
  }) {
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) {
        return Stream<List<Map<String, dynamic>>>.value(
          const <Map<String, dynamic>>[],
        );
      }
      return _watch(_syncQueueController, () async {
        final db = await _database;
        return _queryScopedSyncQueue(
          db,
          actorId: actorId!,
          teamIds: teamIds!,
          orderBy: 'q.created_at_utc DESC',
        );
      });
    }
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(
        await db.query('sync_queue', orderBy: 'created_at_utc DESC'),
      );
    });
  }

  Future<void> _pruneWorkHistoryCacheBytes(
    Transaction txn, {
    required int maxBytes,
  }) async {
    while (true) {
      final sizeRows = await txn.rawQuery('''
        SELECT
          (SELECT COALESCE(SUM(
            LENGTH(COALESCE(cache_key, '')) + LENGTH(COALESCE(subject_id, ''))
            + LENGTH(COALESCE(scope_code, ''))
            + LENGTH(COALESCE(request_date_from, ''))
            + LENGTH(COALESCE(request_date_to, ''))), 0)
           FROM work_history_cache_meta)
          + (SELECT COALESCE(SUM(
            LENGTH(COALESCE(transaction_uuid, ''))
            + LENGTH(COALESCE(worker_id, '')) + LENGTH(COALESCE(worker_name, ''))
            + LENGTH(COALESCE(production_order, '')) + LENGTH(COALESCE(operation, ''))
            + LENGTH(COALESCE(sales_order, ''))
            + LENGTH(COALESCE(sales_order_item, ''))
            + LENGTH(COALESCE(plant, '')) + LENGTH(COALESCE(work_center, ''))
            + LENGTH(COALESCE(transaction_type, ''))
            + LENGTH(COALESCE(unit_of_measure, ''))
            + LENGTH(COALESCE(transaction_status, ''))), 0)
           FROM work_history_cache_entries)
          + (SELECT COALESCE(SUM(
            LENGTH(COALESCE(worker_id, '')) + LENGTH(COALESCE(worker_name, ''))
            + LENGTH(COALESCE(unit_of_measure, ''))), 0)
           FROM work_history_cache_workers) AS bytes
      ''');
      final bytes = (sizeRows.single['bytes'] as num? ?? 0).toInt();
      if (bytes <= maxBytes) return;
      final oldest = await txn.query(
        'work_history_cache_meta',
        columns: ['cache_key'],
        orderBy: 'fetched_at_utc ASC, cache_key ASC',
        limit: 1,
      );
      if (oldest.isEmpty) return;
      await txn.delete(
        'work_history_cache_meta',
        where: 'cache_key = ?',
        whereArgs: [oldest.single['cache_key']],
      );
    }
  }

  Stream<SyncFeedPage> watchSyncFeedPage({
    required String actorId,
    required List<String> teamIds,
    required SyncFeedFilter filter,
    int pageSize = 50,
  }) {
    return _ticks(_syncQueueController).asyncMap<SyncFeedPage>((_) {
      return getSyncFeedPage(
        actorId: actorId,
        teamIds: teamIds,
        filter: filter,
        pageSize: pageSize,
      );
    });
  }

  Future<SyncFeedPage> getSyncFeedPage({
    required String actorId,
    required List<String> teamIds,
    required SyncFeedFilter filter,
    int pageSize = 50,
    int? beforeCreatedAtUtc,
    String? beforeId,
  }) async {
    final safePageSize = pageSize.clamp(1, 200);
    final db = await _database;
    if (!_hasUsableSyncScope(actorId, teamIds)) {
      return const SyncFeedPage(
        items: [],
        hasMore: false,
        nextCreatedAtUtc: null,
        nextId: null,
        pendingCount: 0,
        verificationCount: 0,
        failedCount: 0,
        totalCount: 0,
      );
    }
    return db.transaction((txn) async {
      final baseFilterClause = switch (filter) {
        SyncFeedFilter.all => '1 = 1',
        SyncFeedFilter.pending => "q.status = 'PENDING'",
        SyncFeedFilter.verification =>
          "(q.status = 'NEEDS_VERIFICATION' OR q.last_error_code = 'WORKER_AUTH_FAILED')",
        SyncFeedFilter.failed =>
          "q.status = 'FAILED' AND (q.last_error_code IS NULL OR "
              "q.last_error_code != 'WORKER_AUTH_FAILED')",
      };
      final failedCutoffUtc =
          DateTime.now().toUtc().millisecondsSinceEpoch -
          syncFailureVisibilityDuration.inMilliseconds;
      // Worker-auth failures are actionable verification items and must remain
      // visible. Other terminal FAILED records expire from this feed after the
      // retention window, while their queue rows stay on disk.
      final visibilityClause =
          "(q.status != 'FAILED' OR q.last_error_code = 'WORKER_AUTH_FAILED' "
          'OR COALESCE(q.updated_at_utc, q.created_at_utc) > ?)';
      final filterClause = '($baseFilterClause) AND $visibilityClause';
      final filterArgs = <Object?>[failedCutoffUtc];
      final cursorClause = beforeCreatedAtUtc != null && beforeId != null
          ? ' AND (q.created_at_utc < ? OR '
                '(q.created_at_utc = ? AND q.id < ?))'
          : '';
      final cursorArgs = beforeCreatedAtUtc != null && beforeId != null
          ? <Object?>[beforeCreatedAtUtc, beforeCreatedAtUtc, beforeId]
          : const <Object?>[];
      final rows = await _queryScopedSyncQueue(
        txn,
        actorId: actorId,
        teamIds: teamIds,
        queueWhere: '($filterClause)$cursorClause',
        queueWhereArgs: [...filterArgs, ...cursorArgs],
        orderBy: 'q.created_at_utc DESC, q.id DESC',
        limit: safePageSize + 1,
      );
      final hasMore = rows.length > safePageSize;
      final items = rows.take(safePageSize).toList(growable: false);
      final last = items.isEmpty ? null : items.last;
      final summaryRows = await _queryScopedSyncQueue(
        txn,
        actorId: actorId,
        teamIds: teamIds,
        select: '''
          COUNT(*) AS total_count,
          SUM(CASE WHEN q.status = 'PENDING' THEN 1 ELSE 0 END) AS pending_count,
          SUM(CASE WHEN q.status = 'NEEDS_VERIFICATION'
                    OR q.last_error_code = 'WORKER_AUTH_FAILED'
                   THEN 1 ELSE 0 END) AS verification_count,
          SUM(CASE WHEN q.status = 'FAILED'
                    AND q.last_error_code != 'WORKER_AUTH_FAILED'
                   THEN 1 ELSE 0 END) AS failed_count
        ''',
        queueWhere: visibilityClause,
        queueWhereArgs: filterArgs,
      );
      final summary = summaryRows.single;
      final filteredSummaryRows = await _queryScopedSyncQueue(
        txn,
        actorId: actorId,
        teamIds: teamIds,
        select: 'COUNT(*) AS filtered_count',
        queueWhere: filterClause,
        queueWhereArgs: filterArgs,
      );
      return SyncFeedPage(
        items: items,
        hasMore: hasMore,
        nextCreatedAtUtc: last?['created_at_utc'] as int?,
        nextId: last?['id'] as String?,
        pendingCount: (summary['pending_count'] as num? ?? 0).toInt(),
        verificationCount: (summary['verification_count'] as num? ?? 0).toInt(),
        failedCount: (summary['failed_count'] as num? ?? 0).toInt(),
        totalCount: (filteredSummaryRows.single['filtered_count'] as num? ?? 0)
            .toInt(),
      );
    });
  }

  Future<Map<String, dynamic>?> getSyncQueueItemById(
    String id, {
    String? actorId,
    List<String>? teamIds,
  }) async {
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) return null;
      final db = await _database;
      final rows = await _queryScopedSyncQueue(
        db,
        actorId: actorId!,
        teamIds: teamIds!,
        queueWhere: 'q.id = ?',
        queueWhereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.single;
    }
    final db = await _database;
    final rows = await db.query(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// All work for one worker that can be sent with one fresh verification.
  /// Assignments are returned before their production/recall descendants so
  /// SAP always has the OriginalTransactionUUID lineage first.
  Future<List<Map<String, dynamic>>> getVerifiableSyncItemsForWorker(
    String workerId, {
    String? actorId,
    List<String>? teamIds,
  }) async {
    final db = await _database;
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) return const [];
      return _queryScopedSyncQueue(
        db,
        actorId: actorId!,
        teamIds: teamIds!,
        queueWhere: '''
          (q.status IN ('PENDING', 'NEEDS_VERIFICATION')
            OR q.last_error_code = 'WORKER_AUTH_FAILED')
          AND COALESCE(
            direct_assignment.nhan_vien_id,
            parent_assignment.nhan_vien_id
          ) = ?
        ''',
        queueWhereArgs: [workerId],
        orderBy:
            "CASE WHEN q.entity_type = 'ASSIGNMENT' THEN 0 ELSE 1 END ASC, "
            'q.created_at_utc ASC, q.id ASC',
      );
    }
    return _rows(
      await db.rawQuery(
        '''
        SELECT q.*
        FROM sync_queue q
        LEFT JOIN assignments direct_assignment
          ON q.entity_type = 'ASSIGNMENT'
         AND direct_assignment.id = q.entity_id
        LEFT JOIN production_records production
          ON q.entity_type IN ('PRODUCTION', 'PRODUCTION_RECORD')
         AND production.id = q.entity_id
        LEFT JOIN recall_records recall
          ON q.entity_type IN ('RECALL', 'RECALL_RECORD')
         AND recall.id = q.entity_id
        LEFT JOIN assignments parent_assignment
          ON parent_assignment.id = COALESCE(
            production.phan_cong_id,
            recall.phan_cong_id
          )
        WHERE (
            q.status IN ('PENDING', 'NEEDS_VERIFICATION')
            OR q.last_error_code = 'WORKER_AUTH_FAILED'
          )
          AND COALESCE(
            direct_assignment.nhan_vien_id,
            parent_assignment.nhan_vien_id
          ) = ?
        ORDER BY
          CASE WHEN q.entity_type = 'ASSIGNMENT' THEN 0 ELSE 1 END ASC,
          q.created_at_utc ASC,
          q.id ASC
        ''',
        [workerId],
      ),
    );
  }

  Stream<int> watchPendingCount() {
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(
        await db.rawQuery(
          "SELECT COUNT(*) AS c FROM sync_queue WHERE status = 'PENDING'",
        ),
      );
    }).map((rows) => rows.first['c'] as int);
  }

  /// Every transaction still waiting for SAP, regardless of whether it is
  /// retrying automatically, needs verification, or needs operator attention.
  Stream<int> watchOutstandingSyncCount({
    String? actorId,
    List<String>? teamIds,
  }) {
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) return Stream<int>.value(0);
      return _watch(_syncQueueController, () async {
        final db = await _database;
        return _queryScopedSyncQueue(
          db,
          actorId: actorId!,
          teamIds: teamIds!,
          select: 'COUNT(*) AS c',
        );
      }).map((rows) => (rows.single['c'] as num).toInt());
    }
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(await db.rawQuery('SELECT COUNT(*) AS c FROM sync_queue'));
    }).map((rows) => rows.first['c'] as int);
  }

  /// Count the records that are currently actionable in the sync screen.
  ///
  /// Terminal failures remain on disk for audit and retry decisions, but the
  /// feed intentionally hides them after the ten-minute visibility window.
  /// Navigation must use the same window; otherwise the tab can show a stale
  /// red badge while the screen itself correctly says there are no records.
  Stream<int> watchVisibleSyncCount({String? actorId, List<String>? teamIds}) {
    int cutoff() =>
        DateTime.now().toUtc().millisecondsSinceEpoch -
        syncFailureVisibilityDuration.inMilliseconds;
    final where =
        "q.status != 'FAILED' OR q.last_error_code = 'WORKER_AUTH_FAILED' "
        'OR COALESCE(q.updated_at_utc, q.created_at_utc) > ?';
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) return Stream<int>.value(0);
      return _watch(_syncQueueController, () async {
        final db = await _database;
        final rows = await _queryScopedSyncQueue(
          db,
          actorId: actorId!,
          teamIds: teamIds!,
          select: 'COUNT(*) AS c',
          queueWhere: where,
          queueWhereArgs: [cutoff()],
        );
        return rows;
      }).map((rows) => (rows.single['c'] as num).toInt());
    }
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(
        await db.rawQuery(
          'SELECT COUNT(*) AS c FROM sync_queue q WHERE ($where)',
          [cutoff()],
        ),
      );
    }).map((rows) => (rows.single['c'] as num).toInt());
  }

  /// Pending items older than [olderThan], which Spec 4.7 requires be surfaced
  /// to the supervisor rather than dropped.
  Stream<int> watchStalePendingCount({
    Duration olderThan = const Duration(hours: 24),
  }) {
    return _watch(_syncQueueController, () async {
      final db = await _database;
      final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
      return _rows(
        await db.rawQuery(
          "SELECT COUNT(*) AS c FROM sync_queue "
          "WHERE status = 'PENDING' AND created_at_utc < ?",
          [cutoff],
        ),
      );
    }).map((rows) => rows.first['c'] as int);
  }

  /// Queue items whose backoff has elapsed, in the order SAP must receive them.
  ///
  /// Ordering by `created_at_utc` is a business requirement, not a nicety: a
  /// recall pushed before the assignment it recalls is rejected by SAP.
  Future<List<Map<String, dynamic>>> getDueSyncItems({
    int? nowUtc,
    int limit = 50,
    String? actorId,
    List<String>? teamIds,
  }) async {
    final db = await _database;
    final now = nowUtc ?? DateTime.now().millisecondsSinceEpoch;
    if (_scopeWasRequested(actorId, teamIds)) {
      if (!_hasUsableSyncScope(actorId, teamIds)) return const [];
      return _queryScopedSyncQueue(
        db,
        actorId: actorId!,
        teamIds: teamIds!,
        queueWhere:
            "q.status = 'PENDING' "
            'AND (q.next_retry_at_utc IS NULL OR q.next_retry_at_utc <= ?)',
        queueWhereArgs: [now],
        orderBy: 'q.priority ASC, q.created_at_utc ASC',
        limit: limit,
      );
    }
    return _rows(
      await db.query(
        'sync_queue',
        where:
            "status = 'PENDING' "
            'AND (next_retry_at_utc IS NULL OR next_retry_at_utc <= ?)',
        whereArgs: [now],
        orderBy: 'priority ASC, created_at_utc ASC',
        limit: limit,
      ),
    );
  }

  /// Source row behind a queue item, or null if the entity type is unknown.
  Future<Map<String, dynamic>?> getSyncSourceRow(
    String entityType,
    String entityId,
  ) async {
    final table = _entitySourceTables[entityType];
    if (table == null) return null;
    final db = await _database;
    final rows = await db.query(
      table,
      where: 'id = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  Future<bool> isSyncQueueItemInScope(
    String id, {
    required String actorId,
    required List<String> teamIds,
  }) async {
    if (!_hasUsableSyncScope(actorId, teamIds)) return false;
    final db = await _database;
    final rows = await _queryScopedSyncQueue(
      db,
      actorId: actorId,
      teamIds: teamIds,
      select: 'q.id',
      queueWhere: 'q.id = ?',
      queueWhereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static bool _scopeWasRequested(String? actorId, List<String>? teamIds) =>
      actorId != null || teamIds != null;

  static bool _hasUsableSyncScope(String? actorId, List<String>? teamIds) =>
      actorId?.trim().isNotEmpty == true &&
      teamIds != null &&
      teamIds.any((teamId) => teamId.trim().isNotEmpty);

  Future<List<Map<String, dynamic>>> _queryScopedSyncQueue(
    DatabaseExecutor executor, {
    required String actorId,
    required List<String> teamIds,
    String select = 'q.*',
    String queueWhere = '1 = 1',
    List<Object?> queueWhereArgs = const [],
    String? orderBy,
    int? limit,
  }) async {
    final normalizedTeams = teamIds
        .map((teamId) => teamId.trim())
        .where((teamId) => teamId.isNotEmpty)
        .toSet()
        .toList();
    if (actorId.trim().isEmpty || normalizedTeams.isEmpty) return const [];
    final teamPlaceholders = List.filled(
      normalizedTeams.length,
      '?',
    ).join(', ');
    final limitClause = limit == null ? '' : 'LIMIT ?';
    final orderClause = orderBy == null ? '' : 'ORDER BY $orderBy';
    final rows = await executor.rawQuery(
      '''
      SELECT $select
      FROM sync_queue q
      LEFT JOIN assignments direct_assignment
        ON q.entity_type = 'ASSIGNMENT'
       AND direct_assignment.id = q.entity_id
      LEFT JOIN production_records production
        ON q.entity_type IN ('PRODUCTION', 'PRODUCTION_RECORD')
       AND production.id = q.entity_id
      LEFT JOIN recall_records recall
        ON q.entity_type IN ('RECALL', 'RECALL_RECORD')
       AND recall.id = q.entity_id
      LEFT JOIN assignments parent_assignment
        ON parent_assignment.id = COALESCE(
          production.phan_cong_id,
          recall.phan_cong_id
        )
      WHERE ($queueWhere)
        AND COALESCE(
          direct_assignment.created_by,
          production.created_by,
          recall.created_by
        ) = ?
        AND (
          COALESCE(direct_assignment.to_id, parent_assignment.to_id)
              IN ($teamPlaceholders)
          -- An operation QR can legitimately omit Plant/Work Center. Until
          -- SAP resolves that write, retain visibility for the same creator
          -- so a verification/rejection is never stranded outside S12.
          OR TRIM(COALESCE(
            direct_assignment.to_id,
            parent_assignment.to_id,
            ''
          )) = ''
        )
      $orderClause
      $limitClause
      ''',
      [...queueWhereArgs, actorId.trim(), ...normalizedTeams, ?limit],
    );
    return _rows(rows);
  }

  /// Empties the queue without touching source rows. Test setup only: the
  /// production path never drops pending work ([deleteSyncQueueItem] only
  /// dismisses FAILED / NEEDS_VERIFICATION items).
  @visibleForTesting
  Future<void> clearSyncQueueForTesting() async {
    final db = await _database;
    await db.delete('sync_queue');
    _notifySyncQueue();
  }

  /// Permanently removes a FAILED / NEEDS_VERIFICATION queue item and the
  /// transaction it would have posted. The operator confirms a warning first;
  /// there is no undo, and nothing of it is kept on the device afterwards.
  ///
  /// Removing an assignment also removes the confirmations and recalls entered
  /// against it (and their queue items): they can never be posted without it.
  /// Removing a confirmation or recall reopens the balance of its assignment.
  /// Pending or synced items are never touched. Returns false when the item is
  /// gone or no longer in a state that may be removed.
  ///
  /// [allowPending] is only for rolling back a transaction the operator just
  /// entered and SAP refused on the spot (see `isLiveRejectionDiscarded`):
  /// a child waiting behind its refused parent is still PENDING.
  Future<bool> deleteSyncQueueItem(
    String id, {
    bool allowPending = false,
  }) async {
    final db = await _database;
    var deleted = false;
    await db.transaction((txn) async {
      final queueRows = await txn.query(
        'sync_queue',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (queueRows.isEmpty) return;

      final queueItem = queueRows.single;
      final queueStatus = queueItem['status']?.toString();
      final errorCode = queueItem['last_error_code']?.toString();
      if (queueStatus != 'FAILED' &&
          queueStatus != 'NEEDS_VERIFICATION' &&
          errorCode != 'WORKER_AUTH_FAILED' &&
          !(allowPending && queueStatus == 'PENDING')) {
        return;
      }
      final entityType = queueItem['entity_type']?.toString() ?? '';
      final entityId = queueItem['entity_id']?.toString() ?? '';
      final table = _entitySourceTables[entityType];

      Future<void> dropQueueFor(List<String> entityIds) async {
        if (entityIds.isEmpty) return;
        await txn.delete(
          'sync_queue',
          where:
              'entity_id IN (${List.filled(entityIds.length, '?').join(',')})',
          whereArgs: entityIds,
        );
      }

      if (table == 'assignments' && entityId.isNotEmpty) {
        final children = <String, List<String>>{};
        for (final childTable in const [
          'production_records',
          'recall_records',
        ]) {
          final rows = await txn.query(
            childTable,
            columns: ['id'],
            where: 'phan_cong_id = ?',
            whereArgs: [entityId],
          );
          children[childTable] = [for (final row in rows) row['id'].toString()];
        }
        await dropQueueFor([
          entityId,
          for (final ids in children.values) ...ids,
        ]);
        for (final entry in children.entries) {
          await txn.delete(
            entry.key,
            where: 'phan_cong_id = ?',
            whereArgs: [entityId],
          );
        }
        await txn.delete('assignments', where: 'id = ?', whereArgs: [entityId]);
      } else if (table != null && entityId.isNotEmpty) {
        // Leave the record out of its assignment's totals first, so the
        // assignment's OPEN/COMPLETED status is recomputed without it.
        await txn.update(
          table,
          {'sync_status': 'FAILED'},
          where: 'id = ?',
          whereArgs: [entityId],
        );
        await _restoreAssignmentStatusAfterRejectedTransaction(
          txn,
          entityType: entityType,
          entityId: entityId,
        );
        await dropQueueFor([entityId]);
        await txn.delete(table, where: 'id = ?', whereArgs: [entityId]);
      }
      await txn.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
      deleted = true;
    });
    if (!deleted) return false;
    _notifySyncQueue();
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
    return true;
  }

  /// Marks a queue item's push attempt as failed.
  ///
  /// [status] decides whether the engine will pick the item up again: a
  /// transient failure stays `PENDING` with a `next_retry_at_utc`, a business
  /// rejection becomes `FAILED` and waits for a supervisor. Retrying a rejected
  /// record forever is what Spec 4.7 calls out as "retry vô hạn".
  Future<void> updateSyncQueueError(
    String id,
    String errorCode,
    String errorMessage, {
    String status = 'FAILED',
    String? failureKind,
    int? nextRetryAtUtc,
  }) async {
    final db = await _database;
    var changed = false;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_queue',
        columns: ['entity_type', 'entity_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final queueItem = rows.first;
      await txn.rawUpdate(
        'UPDATE sync_queue SET '
        'retry_count = retry_count + 1, '
        'last_error_code = ?, last_error_message = ?, '
        'status = ?, failure_kind = ?, next_retry_at_utc = ?, updated_at_utc = ? '
        'WHERE id = ?',
        [
          errorCode,
          errorMessage,
          status,
          failureKind,
          nextRetryAtUtc,
          DateTime.now().millisecondsSinceEpoch,
          id,
        ],
      );

      final table = _entitySourceTables[queueItem['entity_type']];
      if (table != null) {
        await txn.update(
          table,
          {'sync_status': status},
          where: 'id = ?',
          whereArgs: [queueItem['entity_id']],
        );
      }
      if (status == 'FAILED' && table != null && table != 'assignments') {
        await _restoreAssignmentStatusAfterRejectedTransaction(
          txn,
          entityType: queueItem['entity_type'] as String,
          entityId: queueItem['entity_id'] as String,
        );
      }
      changed = true;
    });
    if (!changed) return;
    _notifySyncQueue();
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
  }

  /// A local write is optimistic so the UI can work offline. If SAP
  /// permanently rejects that write, its quantity must stop contributing to
  /// the assignment balance and a locally completed assignment must reopen.
  /// The rejected row stays in the database for audit and troubleshooting.
  Future<void> _restoreAssignmentStatusAfterRejectedTransaction(
    Transaction txn, {
    required String entityType,
    required String entityId,
  }) async {
    final table = _entitySourceTables[entityType];
    if (table == null || table == 'assignments') return;

    final sourceRows = await txn.query(
      table,
      columns: ['phan_cong_id'],
      where: 'id = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (sourceRows.isEmpty) return;
    final assignmentId = sourceRows.single['phan_cong_id']?.toString();
    if (assignmentId == null || assignmentId.isEmpty) return;

    final assignmentRows = await txn.query(
      'assignments',
      columns: ['assigned_quantity'],
      where: 'id = ?',
      whereArgs: [assignmentId],
      limit: 1,
    );
    if (assignmentRows.isEmpty) return;
    final assigned = _toDouble(assignmentRows.single['assigned_quantity']);

    final completedRows = await txn.rawQuery(
      "SELECT COALESCE(SUM(quantity + defect_quantity), 0) AS total "
      "FROM production_records WHERE phan_cong_id = ? "
      "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
      [assignmentId],
    );
    final recalledRows = await txn.rawQuery(
      "SELECT COALESCE(SUM(quantity), 0) AS total "
      "FROM recall_records WHERE phan_cong_id = ? "
      "AND COALESCE(sync_status, 'PENDING') != 'FAILED'",
      [assignmentId],
    );
    final completed = _toDouble(completedRows.single['total']);
    final recalled = _toDouble(recalledRows.single['total']);
    final remaining = assigned - completed - recalled;
    final nextStatus = remaining <= 0.0001
        ? completed >= assigned - 0.0001
              ? 'COMPLETED'
              : 'RECALLED'
        : 'OPEN';

    await txn.update(
      'assignments',
      {'status': nextStatus},
      where: 'id = ?',
      whereArgs: [assignmentId],
    );
  }

  /// Removes a confirmed queue item and stamps its source row as SYNCED.
  ///
  /// Both halves run in one transaction: a crash between them would either
  /// re-push a record SAP already holds or leave a synced row looking pending
  /// forever.
  Future<void> markSyncItemSynced(
    String queueItemId, {
    required String entityType,
    required String entityId,
    String? sapId,
  }) async {
    final db = await _database;
    final table = _entitySourceTables[entityType];
    final syncedAt = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.delete('sync_queue', where: 'id = ?', whereArgs: [queueItemId]);
      if (table != null) {
        await txn.update(
          table,
          {'sync_status': 'SYNCED', 'synced_at_utc': syncedAt, 'sap_id': sapId},
          where: 'id = ?',
          whereArgs: [entityId],
        );
      }
    });

    _notifySyncQueue();
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
    _emit(_remotePostingController);
  }

  Future<bool> retrySyncItem(String id) async {
    final db = await _database;
    // Requeue without deleting the source transaction. The sync engine is
    // responsible for removing the item only after SAP acknowledges it.
    var changed = false;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_queue',
        columns: ['entity_type', 'entity_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final queueItem = rows.first;
      await txn.update(
        'sync_queue',
        {
          'status': 'PENDING',
          'last_error_code': null,
          'last_error_message': null,
          'failure_kind': null,
          'next_retry_at_utc': null,
          'updated_at_utc': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      final table = _entitySourceTables[queueItem['entity_type']];
      if (table != null) {
        await txn.update(
          table,
          {'sync_status': 'PENDING'},
          where: 'id = ?',
          whereArgs: [queueItem['entity_id']],
        );
      }
      changed = true;
    });
    if (!changed) return false;
    _notifySyncQueue();
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
    return true;
  }

  void _notifySyncQueue() => _emit(_syncQueueController);

  void _emit(StreamController<void> controller) {
    if (!controller.isClosed) controller.add(null);
  }

  /// Emits the current snapshot only to the new subscriber, then re-runs [query]
  /// on every write to the table it reads.
  ///
  /// Broadcasting the initial value through the shared controller made every
  /// existing screen rebuild whenever another screen subscribed.
  ///
  /// `asyncMap` also serialises the queries, so two writes landing back to back
  /// cannot emit their snapshots out of order.
  Stream<List<Map<String, dynamic>>> _watch(
    StreamController<void> controller,
    Future<List<Map<String, dynamic>>> Function() query,
  ) => _watchTicks(() => _ticks(controller), query);

  Stream<List<Map<String, dynamic>>> _watchTicks(
    Stream<void> Function() ticks,
    Future<List<Map<String, dynamic>>> Function() query,
  ) {
    // A watcher may be temporarily mounted twice while a list item is being
    // rebuilt or kept alive. Share one upstream subscription while listeners
    // are present, then cancel it when the last listener leaves. A fresh
    // `_ticks` stream is created on the next listen, so remounting still gets
    // its initial snapshot and does not retain obsolete queries.
    // ignore: close_sinks
    late StreamController<List<Map<String, dynamic>>> result;
    // ignore: cancel_subscriptions
    StreamSubscription<List<Map<String, dynamic>>>? upstream;
    result = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: () {
        if (upstream != null) return;
        final source = ticks().asyncMap((_) => query());
        upstream = source.listen(result.add, onError: result.addError);
      },
      onCancel: () async {
        final subscription = upstream;
        upstream = null;
        await subscription?.cancel();
      },
    );
    return result.stream;
  }

  /// One tick now, then one per write.
  ///
  /// Delegating with `yield*` rather than looping with `await for` is load
  /// bearing: an `await for` suspended on a stream that has not emitted yet only
  /// notices cancellation when it next reaches a `yield`, so `cancel()` never
  /// completes and the generator leaks — one per screen the user navigates away
  /// from. `yield*` hands the cancellation straight to the delegated stream.
  Stream<void> _ticks(StreamController<void> controller) async* {
    yield null;
    yield* controller.stream;
  }

  /// [_ticks] over several tables: one tick now, then one per write to any.
  Stream<void> _ticksAny(List<StreamController<void>> controllers) {
    final subscriptions = <StreamSubscription<void>>[];
    // Single-subscription and owned by its listener; cancelling ends it.
    // ignore: close_sinks
    late final StreamController<void> ticks;
    ticks = StreamController<void>(
      onListen: () {
        ticks.add(null);
        for (final controller in controllers) {
          subscriptions.add(controller.stream.listen(ticks.add));
        }
      },
      onCancel: () async {
        final active = List.of(subscriptions);
        subscriptions.clear();
        for (final subscription in active) {
          await subscription.cancel();
        }
      },
    );
    return ticks.stream;
  }

  // ─── Audit Log ────────────────────────────────────────────────────
  Future<void> insertAuditLog(Map<String, dynamic> log) async {
    final db = await _database;
    await db.insert('audit_log', log);
  }

  // ─── Cleanup ──────────────────────────────────────────────────────

  /// Releases the tickers and the underlying SQLite handle.
  ///
  /// Await this when something is going to reopen the same path straight after
  /// — a close still in flight would slam shut the handle its replacement just
  /// took out.
  Future<void> close() async {
    // Clear the static handle first — otherwise `instance` keeps returning this
    // object with all four controllers already closed.
    if (identical(_instance, this)) {
      _instance = null;
    }
    await _assignmentController.close();
    await _syncQueueController.close();
    await _productionController.close();
    await _recallController.close();
    await _remotePostingController.close();
    try {
      await (await _database).close();
    } catch (_) {
      // Opening failed, or it is already shut. Either way there is nothing left
      // to release, and teardown must not throw over it.
    }
  }

  /// Fire-and-forget [close], for call sites with no async context.
  void dispose() => unawaited(close());
}
