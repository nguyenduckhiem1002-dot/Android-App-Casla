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
    await db.update(
      'employees',
      values,
      where: 'ma_nv = ?',
      whereArgs: [maNv],
    );
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

    final deduplicated = <String, String>{};
    for (final worker in workers) {
      final workerId = worker['worker_id']?.trim() ?? '';
      if (workerId.isEmpty) continue;
      final workerName = worker['worker_name']?.trim();
      deduplicated[workerId] = workerName == null || workerName.isEmpty
          ? workerId
          : workerName;
    }
    if (deduplicated.isEmpty) return;

    final db = await _database;
    final batch = db.batch();
    for (final entry in deduplicated.entries) {
      batch.rawInsert(
        '''
        INSERT INTO employees (
          id, ma_nv, ten, bo_phan, trang_thai, vai_tro, quyen_han, to_ids
        ) VALUES (?, ?, ?, ?, 'ACTIVE', 'CONG_NHAN', ?, ?)
        ON CONFLICT(ma_nv) DO UPDATE SET
          ten = excluded.ten,
          trang_thai = 'ACTIVE'
        ''',
        [
          'sap-worker:${entry.key}',
          entry.key,
          entry.value,
          'Công nhân sản xuất',
          jsonEncode(['VIEW_OWN_PRODUCTION']),
          jsonEncode(<String>[]),
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
      List<Map<String, Object?>> matches = await txn.query(
        'orders',
        where: 'production_order = ? AND operation = ?',
        whereArgs: [qr.productionOrder, qr.operation],
        limit: 1,
      );

      if (matches.isEmpty && qr.orderCode.isNotEmpty) {
        matches = await txn.query(
          'orders',
          where: 'LOWER(ma_don_hang) = ?',
          whereArgs: [qr.orderCode.toLowerCase()],
          limit: 1,
        );
      }
      if (matches.isEmpty && qr.productCode.isNotEmpty) {
        matches = await txn.query(
          'orders',
          where: 'LOWER(ma_sp) = ?',
          whereArgs: [qr.productCode.toLowerCase()],
          limit: 1,
        );
      }

      final displayName = qr.displayProductName.isNotEmpty
          ? qr.displayProductName
          : 'Lệnh SX ${qr.productionOrder}';
      final uom = qr.unitOfMeasure;
      final quantity = qr.operationQuantity ?? 0.0;
      final values = <String, Object?>{
        'production_order': qr.productionOrder,
        'operation': qr.operation,
        'operation_qr_payload': qr.rawPayload,
        if (qr.productCode.isNotEmpty) 'ma_sp': qr.productCode,
        if (qr.productName.isNotEmpty) 'ten_sp': qr.productName,
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

  Stream<List<Map<String, dynamic>>> watchAssignmentsByWorker(String workerId) {
    return _watch(_assignmentController, () async {
      final db = await _database;
      return _rows(
        await db.query(
          'assignments',
          where: 'nhan_vien_id = ?',
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
    Iterable<String> assignmentIds,
  ) async {
    final ids = assignmentIds.toSet().toList(growable: false);
    if (ids.isEmpty) return [];
    final db = await _database;
    return db.transaction((txn) async {
      final byId = <String, Map<String, dynamic>>{};
      const chunkSize = 400;
      for (var start = 0; start < ids.length; start += chunkSize) {
        final chunk = ids.skip(start).take(chunkSize).toList(growable: false);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await txn.rawQuery('''
          SELECT a.*, e.ma_nv AS worker_code, e.ten AS worker_name,
                 o.ma_don_hang AS order_code, o.ma_sp AS product_code,
                 o.ten_sp AS product_name, o.uom AS unit_of_measure,
                 (SELECT COALESCE(SUM(p.quantity), 0)
                  FROM production_records p WHERE p.phan_cong_id = a.id)
                    AS completed_quantity,
                 (SELECT COALESCE(SUM(r.quantity), 0)
                  FROM recall_records r WHERE r.phan_cong_id = a.id)
                    AS recalled_quantity
          FROM assignments a
          LEFT JOIN employees e ON e.id = a.nhan_vien_id
          LEFT JOIN orders o ON o.id = a.don_hang_id
          WHERE a.id IN ($placeholders)
        ''', chunk);
        for (final row in rows) {
          byId[row['id'] as String] = Map<String, dynamic>.from(row);
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
          where: 'to_id IN ($placeholders)',
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
    final remaining = effective - completed;
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
  }) async {
    final assignmentId = record['phan_cong_id']?.toString();
    if (assignmentId == null || assignmentId.isEmpty) {
      throw const MutationValidationException('Phân công không tồn tại.');
    }
    final quantity = _requireFinitePositive(
      record['quantity'],
      'Số lượng hoàn thành phải là một số dương hợp lệ.',
    );

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
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        'FROM production_records WHERE phan_cong_id = ?',
        [assignmentId],
      );
      final recalledRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        'FROM recall_records WHERE phan_cong_id = ?',
        [assignmentId],
      );
      final assigned = _toDouble(assignment['assigned_quantity']);
      final completed = _toDouble(completedRows.single['total']);
      final recalled = _toDouble(recalledRows.single['total']);
      final remaining = (assigned - recalled - completed)
          .clamp(0.0, double.infinity)
          .toDouble();
      if (quantity > remaining + 0.0001) {
        throw MutationValidationException(
          'Số lượng vượt quá số lượng còn lại (${remaining.toInt()}).',
        );
      }

      await txn.insert('production_records', record);
      if (remaining - quantity <= 0.0001) {
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
      'FROM production_records WHERE phan_cong_id = ?',
      [assignmentId],
    );
    return _toDouble(rows.first['total']);
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
      'FROM $table GROUP BY phan_cong_id',
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
      'WHERE a.nhan_vien_id = ? AND p.business_date = ?',
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
  }) async {
    final db = await _database;
    final where = StringBuffer('a.nhan_vien_id = ?');
    final args = <Object?>[employeeId];

    if (fromBusinessDate != null) {
      where.write(' AND p.business_date >= ?');
      args.add(fromBusinessDate);
    }
    if (toBusinessDate != null) {
      where.write(' AND p.business_date <= ?');
      args.add(toBusinessDate);
    }

    return _rows(
      await db.rawQuery('''
        SELECT p.*,
               COALESCE(o.ten_sp, 'Không rõ sản phẩm') AS ten_sp,
               a.don_hang_id AS ma_don_hang,
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
  }) {
    return _watch(
      _productionController,
      () => getProductionHistory(
        employeeId,
        fromBusinessDate: fromBusinessDate,
        toBusinessDate: toBusinessDate,
      ),
    );
  }

  // ─── Recall Record Queries ────────────────────────────────────────
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
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        'FROM production_records WHERE phan_cong_id = ?',
        [assignmentId],
      );
      final recalledRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total '
        'FROM recall_records WHERE phan_cong_id = ?',
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
      'FROM recall_records WHERE phan_cong_id = ?',
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
      final filterClause = switch (filter) {
        SyncFeedFilter.all => '1 = 1',
        SyncFeedFilter.pending => "q.status = 'PENDING'",
        SyncFeedFilter.verification =>
          "(q.status = 'NEEDS_VERIFICATION' OR q.last_error_code = 'WORKER_AUTH_FAILED')",
        SyncFeedFilter.failed =>
          "q.status = 'FAILED' AND (q.last_error_code IS NULL OR "
              "q.last_error_code != 'WORKER_AUTH_FAILED')",
      };
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
        queueWhereArgs: cursorArgs,
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
      );
      final summary = summaryRows.single;
      final filteredSummaryRows = await _queryScopedSyncQueue(
        txn,
        actorId: actorId,
        teamIds: teamIds,
        select: 'COUNT(*) AS filtered_count',
        queueWhere: filterClause,
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
        AND COALESCE(direct_assignment.to_id, parent_assignment.to_id)
            IN ($teamPlaceholders)
      $orderClause
      $limitClause
      ''',
      [...queueWhereArgs, actorId.trim(), ...normalizedTeams, ?limit],
    );
    return _rows(rows);
  }

  Future<void> deleteSyncQueueItem(String id) async {
    final db = await _database;
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
    _notifySyncQueue();
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
      changed = true;
    });
    if (!changed) return;
    _notifySyncQueue();
    _notifyAssignments();
    _notifyProduction();
    _notifyRecalls();
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
  ) {
    return _ticks(controller).asyncMap((_) => query());
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
