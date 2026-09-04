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
    await db.insert(
      'employees',
      {
        'id': id,
        'ma_nv': maNv,
        'ten': name,
        'bo_phan': department,
        'trang_thai': 'ACTIVE',
        'vai_tro': 'CONG_NHAN',
        'quyen_han': jsonEncode(['VIEW_OWN_PRODUCTION']),
        'to_ids': jsonEncode([]),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
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
    final scope = teamIds.toSet();
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

  Stream<List<Map<String, dynamic>>> watchAssignmentsByTeams(
    List<String> teamIds,
  ) {
    return _watch(_assignmentController, () async {
      if (teamIds.isEmpty) return const <Map<String, dynamic>>[];
      final db = await _database;
      final placeholders = List.filled(teamIds.length, '?').join(', ');
      return _rows(
        await db.query(
          'assignments',
          where: 'to_id IN ($placeholders)',
          whereArgs: teamIds,
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
    String? assignmentStatus,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('production_records', record);
      if (assignmentStatus != null) {
        await txn.update(
          'assignments',
          {'status': assignmentStatus},
          where: 'id = ?',
          whereArgs: [record['phan_cong_id']],
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
    String? assignmentStatus,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('recall_records', record);
      if (assignmentStatus != null) {
        await txn.update(
          'assignments',
          {'status': assignmentStatus},
          where: 'id = ?',
          whereArgs: [record['phan_cong_id']],
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

  Stream<List<Map<String, dynamic>>> watchSyncFeed() {
    return _watch(_syncQueueController, () async {
      final db = await _database;
      return _rows(
        await db.query('sync_queue', orderBy: 'created_at_utc DESC'),
      );
    });
  }

  Future<Map<String, dynamic>?> getSyncQueueItemById(String id) async {
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
    String workerId,
  ) async {
    final db = await _database;
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
  Stream<int> watchOutstandingSyncCount() {
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
  }) async {
    final db = await _database;
    final now = nowUtc ?? DateTime.now().millisecondsSinceEpoch;
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
