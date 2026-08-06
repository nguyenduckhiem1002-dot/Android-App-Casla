// Core Database — Casla Production
// Spec: Section 8 (Data model & database)
// In-memory storage for MVP (Drift requires code generation setup)

import 'dart:async';
import 'dart:math';

/// In-memory mock database for MVP development.
class CaslaDatabase {
  // ─── In-memory storage ────────────────────────────────────────────
  final List<Map<String, dynamic>> _employees = [];
  final List<Map<String, dynamic>> _teams = [];
  final List<Map<String, dynamic>> _orders = [];
  final List<Map<String, dynamic>> _assignments = [];
  final List<Map<String, dynamic>> _productionRecords = [];
  final List<Map<String, dynamic>> _recallRecords = [];
  final List<Map<String, dynamic>> _syncQueue = [];
  final List<Map<String, dynamic>> _auditLog = [];

  final _assignmentController = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _syncQueueController = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _productionController = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _recallController = StreamController<List<Map<String, dynamic>>>.broadcast();

  static CaslaDatabase? _instance;
  static CaslaDatabase get instance {
    _instance ??= CaslaDatabase._();
    return _instance!;
  }
  CaslaDatabase._() {
    _seedData();
  }

  String _uuid() => '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';

  // ─── Seed Data ──────────────────────────────────────────────────────
  // 5 User Demo:
  //   1. Supervisor:  tranthib / 123456 (Trần Thị B - Supervisor Tổ Cắt 1-3)
  //   2. Worker SYNCED: vana123  / 123456 (Nguyễn Văn A - Tổ Cắt 2)
  //   3. Worker PENDING: lethic   / 123456 (Lê Thị C - Tổ Cắt 1)
  //   4. Worker FAILED:  phamvand / 123456 (Phạm Văn D - Tổ Cắt 3)
  //   5. Worker OPEN:    hoangvane/ 123456 (Hoàng Văn E - Tổ Cắt 2)
  void _seedData() {
    _employees.addAll([
      {
        'id': 'emp-4', 'ma_nv': 'MNV00100', 'ten': 'Trần Thị B', 'bo_phan': 'Supervisor Tổ Cắt 1–3',
        'trang_thai': 'ACTIVE', 'tai_khoan': 'tranthib', 'mat_khau_hash': '123456',
        'vai_tro': 'SUPERVISOR',
        'quyen_han': ['ASSIGN_QUANTITY', 'CONFIRM_COMPLETION', 'RECALL_ASSIGNMENT', 'VIEW_TEAM_PRODUCTION', 'VIEW_SYNC_STATUS'],
        'to_ids': ['team-1', 'team-2', 'team-3'],
      },
      {
        'id': 'emp-1', 'ma_nv': 'MNV00123', 'ten': 'Nguyễn Văn A', 'bo_phan': 'Tổ Cắt 2',
        'trang_thai': 'ACTIVE', 'tai_khoan': 'vana123', 'mat_khau_hash': '123456',
        'vai_tro': 'CONG_NHAN', 'quyen_han': ['VIEW_OWN_PRODUCTION'],
        'to_ids': ['team-2'],
      },
      {
        'id': 'emp-2', 'ma_nv': 'MNV00147', 'ten': 'Lê Thị C', 'bo_phan': 'Tổ Cắt 1',
        'trang_thai': 'ACTIVE', 'tai_khoan': 'lethic', 'mat_khau_hash': '123456',
        'vai_tro': 'CONG_NHAN', 'quyen_han': ['VIEW_OWN_PRODUCTION'],
        'to_ids': ['team-1'],
      },
      {
        'id': 'emp-3', 'ma_nv': 'MNV00158', 'ten': 'Phạm Văn D', 'bo_phan': 'Tổ Cắt 3',
        'trang_thai': 'ACTIVE', 'tai_khoan': 'phamvand', 'mat_khau_hash': '123456',
        'vai_tro': 'CONG_NHAN', 'quyen_han': ['VIEW_OWN_PRODUCTION'],
        'to_ids': ['team-3'],
      },
      {
        'id': 'emp-5', 'ma_nv': 'MNV00199', 'ten': 'Hoàng Văn E', 'bo_phan': 'Tổ Cắt 2',
        'trang_thai': 'ACTIVE', 'tai_khoan': 'hoangvane', 'mat_khau_hash': '123456',
        'vai_tro': 'CONG_NHAN', 'quyen_han': ['VIEW_OWN_PRODUCTION'],
        'to_ids': ['team-2'],
      },
    ]);

    _teams.addAll([
      {'id': 'team-1', 'ma_to': 'TC01', 'ten_to': 'Tổ Cắt 1', 'bo_phan': 'Xưởng May', 'trang_thai': 'ACTIVE'},
      {'id': 'team-2', 'ma_to': 'TC02', 'ten_to': 'Tổ Cắt 2', 'bo_phan': 'Xưởng May', 'trang_thai': 'ACTIVE'},
      {'id': 'team-3', 'ma_to': 'TC03', 'ten_to': 'Tổ Cắt 3', 'bo_phan': 'Xưởng May', 'trang_thai': 'ACTIVE'},
    ]);

    _orders.addAll([
      {
        'id': 'ord-1', 'ma_don_hang': 'DH-2026-00417', 'ma_qr': 'QR-AKG-L',
        'ma_sp': 'SP-AKG', 'ten_sp': 'Áo khoác gió — size L',
        'dac_tinh': 'Vải dù 2 lớp, chống nước, màu navy, size L',
        'uom': 'cái', 'so_luong_don': 1000.0, 'trang_thai': 'OPEN',
      },
      {
        'id': 'ord-2', 'ma_don_hang': 'DH-2026-00391', 'ma_qr': 'QR-QJN-32',
        'ma_sp': 'SP-QJN', 'ten_sp': 'Quần jean nam — size 32',
        'dac_tinh': 'Denim 12oz, form slim, size 32',
        'uom': 'cái', 'so_luong_don': 500.0, 'trang_thai': 'OPEN',
      },
      {
        'id': 'ord-3', 'ma_don_hang': 'DH-2026-00502', 'ma_qr': 'QR-ATN-01',
        'ma_sp': 'SP-ATN', 'ten_sp': 'Áo thun nam Polo',
        'dac_tinh': 'Cotton 100%, cổ bẻ, màu trắng, freesize',
        'uom': 'cái', 'so_luong_don': 800.0, 'trang_thai': 'OPEN',
      },
    ]);

    final now = DateTime.now().millisecondsSinceEpoch;

    _assignments.addAll([
      // emp-1: Nguyễn Văn A (Status: SYNCED)
      {
        'id': 'asg-001', 'nhan_vien_id': 'emp-1', 'don_hang_id': 'ord-1', 'to_id': 'team-2',
        'assigned_quantity': 650.0, 'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'status': 'OPEN', 'note': 'Giao ca sáng', 'created_by': 'MNV00100',
        'occurred_at_utc': now, 'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-key-001', 'created_at_utc': now,
      },
      // emp-2: Lê Thị C (Status: PENDING)
      {
        'id': 'asg-003', 'nhan_vien_id': 'emp-2', 'don_hang_id': 'ord-3', 'to_id': 'team-1',
        'assigned_quantity': 320.0, 'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'status': 'OPEN', 'note': null, 'created_by': 'MNV00100',
        'occurred_at_utc': now, 'device_id': 'PDA-CT01-A03', 'sync_status': 'PENDING',
        'idempotency_key': 'demo-key-003', 'created_at_utc': now,
      },
      // emp-3: Phạm Văn D (Status: FAILED)
      {
        'id': 'asg-004', 'nhan_vien_id': 'emp-3', 'don_hang_id': 'ord-1', 'to_id': 'team-3',
        'assigned_quantity': 300.0, 'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'status': 'OPEN', 'note': null, 'created_by': 'MNV00100',
        'occurred_at_utc': now, 'device_id': 'PDA-CT03-A09', 'sync_status': 'FAILED',
        'idempotency_key': 'demo-key-004', 'created_at_utc': now,
      },
      // emp-5: Hoàng Văn E (Status: OPEN / CHƯA XÁC NHẬN)
      {
        'id': 'asg-005', 'nhan_vien_id': 'emp-5', 'don_hang_id': 'ord-2', 'to_id': 'team-2',
        'assigned_quantity': 400.0, 'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'status': 'OPEN', 'note': 'Mới giao ca', 'created_by': 'MNV00100',
        'occurred_at_utc': now, 'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-key-005', 'created_at_utc': now,
      },
      // Dữ liệu quá khứ (Hôm qua) để test xem lịch sử quá khứ
      {
        'id': 'asg-002', 'nhan_vien_id': 'emp-1', 'don_hang_id': 'ord-2', 'to_id': 'team-2',
        'assigned_quantity': 200.0, 'business_date': _yesterdayStr(), 'shift_id': 'SHIFT_1',
        'status': 'CLOSED', 'note': 'Đã xong ngày hôm qua', 'created_by': 'MNV00100',
        'occurred_at_utc': now - 86400000, 'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-key-002', 'created_at_utc': now - 86400000,
      },
    ]);

    _productionRecords.addAll([
      {
        'id': 'prod-001', 'phan_cong_id': 'asg-001', 'quantity': 236.0,
        'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100', 'occurred_at_utc': now - 7200000,
        'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-001', 'created_at_utc': now - 7200000,
      },
      {
        'id': 'prod-003', 'phan_cong_id': 'asg-001', 'quantity': 200.0,
        'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100', 'occurred_at_utc': now - 3600000,
        'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-003', 'created_at_utc': now - 3600000,
      },
      {
        'id': 'prod-005', 'phan_cong_id': 'asg-003', 'quantity': 214.0,
        'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100', 'occurred_at_utc': now - 5400000,
        'device_id': 'PDA-CT01-A03', 'sync_status': 'PENDING',
        'idempotency_key': 'demo-prod-005', 'created_at_utc': now - 5400000,
      },
      {
        'id': 'prod-006', 'phan_cong_id': 'asg-004', 'quantity': 201.0,
        'business_date': _todayStr(), 'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100', 'occurred_at_utc': now - 1800000,
        'device_id': 'PDA-CT03-A09', 'sync_status': 'FAILED',
        'idempotency_key': 'demo-prod-006', 'created_at_utc': now - 1800000,
      },
      // Quá khứ
      {
        'id': 'prod-004', 'phan_cong_id': 'asg-002', 'quantity': 200.0,
        'business_date': _yesterdayStr(), 'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100', 'occurred_at_utc': now - 90000000,
        'device_id': 'PDA-CT02-A17', 'sync_status': 'SYNCED',
        'idempotency_key': 'demo-prod-004', 'created_at_utc': now - 90000000,
      },
    ]);

    _syncQueue.addAll([
      {
        'id': 'sync-001', 'entity_type': 'PRODUCTION_RECORD', 'entity_id': 'prod-006',
        'action': 'CREATE', 'payload_summary': 'Xác nhận hoàn thành · +201 · DH-2026-00417',
        'created_at_utc': now - 1800000, 'retry_count': 1,
        'last_error_code': 'ERR_VALIDATION', 'last_error_message': 'Lỗi xác thực số lượng',
        'device_id': 'PDA-CT03-A09',
      },
      {
        'id': 'sync-002', 'entity_type': 'PRODUCTION_RECORD', 'entity_id': 'prod-005',
        'action': 'CREATE', 'payload_summary': 'Xác nhận hoàn thành · +214 · DH-2026-00502',
        'created_at_utc': now - 5400000, 'retry_count': 0,
        'last_error_code': null, 'last_error_message': null,
        'device_id': 'PDA-CT01-A03',
      },
    ]);

    _auditLog.add({
      'id': 'audit-001', 'action': 'ASSIGNMENT_CREATED', 'entity_id': 'asg-001',
      'performed_by': 'MNV00100', 'occurred_at_utc': now,
    });
  }

  String _todayStr() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  String _yesterdayStr() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // ─── Auth / Employee Queries ──────────────────────────────────────
  Future<Map<String, dynamic>?> login(String taiKhoan, String matKhau) async {
    try {
      final emp = _employees.firstWhere((e) =>
          e['tai_khoan'] == taiKhoan && e['trang_thai'] == 'ACTIVE');
      if (emp['mat_khau_hash'] != matKhau) return null;
      return emp;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEmployeeByCode(String code) async {
    try {
      return _employees.firstWhere((e) =>
          e['ma_nv'] == code || e['tai_khoan'] == code || e['id'] == code);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEmployeeById(String id) async {
    try {
      return _employees.firstWhere((e) => e['id'] == id);
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllEmployees() async => List.from(_employees);

  Future<List<Map<String, dynamic>>> getEmployeesByTeamIds(List<String> teamIds) async {
    return _employees.where((e) {
      if (e['vai_tro'] == 'SUPERVISOR') return false; // Chỉ lấy công nhân
      final ids = (e['to_ids'] as List).cast<String>();
      return ids.any((t) => teamIds.contains(t));
    }).toList();
  }

  Future<bool> isEmployeeInScope(String employeeId, List<String> supervisorToIds) async {
    final emp = await getEmployeeById(employeeId);
    if (emp == null) return false;
    final ids = (emp['to_ids'] as List).cast<String>();
    return ids.any((t) => supervisorToIds.contains(t));
  }

  // ─── Team Queries ─────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getAllTeams() async => List.from(_teams);

  // ─── Order / Material Queries ─────────────────────────────────────
  Future<List<Map<String, dynamic>>> getOpenOrders() async {
    return _orders.where((o) => o['trang_thai'] == 'OPEN').toList();
  }

  Future<Map<String, dynamic>?> getOrderByCode(String code) async {
    try {
      String searchKey = code.trim();
      if (searchKey.startsWith('{') && searchKey.endsWith('}')) {
        try {
          final Map<String, dynamic> json = Map<String, dynamic>.from(
              Uri.splitQueryString(searchKey.replaceAll(RegExp(r'[{}"\s]'), '')));
          searchKey = json['productCode'] ?? json['orderCode'] ?? json['ma_qr'] ?? json['ma_sp'] ?? json['ma_don_hang'] ?? searchKey;
        } catch (_) {}
      }

      final keyLower = searchKey.toLowerCase();
      return _orders.firstWhere((o) {
        final maQr = (o['ma_qr'] ?? '').toString().toLowerCase();
        final maDonHang = (o['ma_don_hang'] ?? '').toString().toLowerCase();
        final maSp = (o['ma_sp'] ?? '').toString().toLowerCase();
        final id = (o['id'] ?? '').toString().toLowerCase();
        final tenSp = (o['ten_sp'] ?? '').toString().toLowerCase();
        return maQr == keyLower ||
            maDonHang == keyLower ||
            maSp == keyLower ||
            id == keyLower ||
            tenSp.contains(keyLower);
      });
    } catch (_) {
      return null;
    }
  }

  // ─── Assignment Queries ───────────────────────────────────────────
  Future<void> insertAssignment(Map<String, dynamic> assignment) async {
    _assignments.add(assignment);
    _notifyAssignments();
  }

  Future<void> createAssignmentFromScan({
    required String employeeId,
    required String orderId,
    required double quantity,
    required String toId,
    required String shiftId,
    required String businessDate,
    required String createdBy,
    required String deviceId,
    String? note,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'asg-${_uuid()}';
    final assignment = {
      'id': id, 'nhan_vien_id': employeeId, 'don_hang_id': orderId, 'to_id': toId,
      'assigned_quantity': quantity, 'business_date': businessDate, 'shift_id': shiftId,
      'status': 'OPEN', 'note': note, 'created_by': createdBy,
      'occurred_at_utc': now, 'device_id': deviceId, 'sync_status': 'PENDING',
      'idempotency_key': 'idem-${_uuid()}', 'created_at_utc': now,
    };
    await insertAssignment(assignment);
    await insertSyncQueueItem({
      'id': 'sync-${_uuid()}', 'entity_type': 'ASSIGNMENT', 'entity_id': id,
      'action': 'CREATE', 'payload_summary': 'Giao việc · ${quantity.toStringAsFixed(0)}',
      'created_at_utc': now, 'retry_count': 0,
      'last_error_code': null, 'last_error_message': null, 'device_id': deviceId,
    });
  }

  Future<Map<String, dynamic>?> getAssignmentById(String id) async {
    try {
      return _assignments.firstWhere((a) => a['id'] == id);
    } catch (_) {
      return null;
    }
  }

  Stream<List<Map<String, dynamic>>> watchAssignmentsByWorker(String workerId) {
    Future.microtask(() => _notifyAssignments());
    return _assignmentController.stream.map((all) =>
        all.where((a) => a['nhan_vien_id'] == workerId).toList()
          ..sort((a, b) => (b['created_at_utc'] as int).compareTo(a['created_at_utc'] as int)));
  }

  Stream<List<Map<String, dynamic>>> watchAllAssignments() {
    Future.microtask(() => _notifyAssignments());
    return _assignmentController.stream.map((all) =>
        List.from(all)..sort((a, b) => (b['created_at_utc'] as int).compareTo(a['created_at_utc'] as int)));
  }

  Stream<List<Map<String, dynamic>>> watchAssignmentsByTeams(List<String> teamIds) {
    Future.microtask(() => _notifyAssignments());
    return _assignmentController.stream.map((all) =>
        all.where((a) => teamIds.contains(a['to_id'])).toList()
          ..sort((a, b) => (b['created_at_utc'] as int).compareTo(a['created_at_utc'] as int)));
  }

  Future<void> updateAssignmentStatus(String id, String status, String syncStatus) async {
    final idx = _assignments.indexWhere((a) => a['id'] == id);
    if (idx != -1) {
      _assignments[idx]['status'] = status;
      _assignments[idx]['sync_status'] = syncStatus;
      _notifyAssignments();
    }
  }

  void _notifyAssignments() => _assignmentController.add(List.from(_assignments));

  // ─── Computed helpers ──────────────────────────────────────────────
  Future<double> getEffectiveAssigned(String assignmentId) async {
    final assigned = (await getAssignmentById(assignmentId))?['assigned_quantity'] as double? ?? 0.0;
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
    _productionRecords.add(record);
    _notifyProduction();
    _notifyAssignments();
  }

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
    final record = {
      'id': id, 'phan_cong_id': assignmentId, 'quantity': quantity,
      'business_date': businessDate, 'shift_id': shiftId,
      'created_by': createdBy, 'occurred_at_utc': now,
      'device_id': deviceId, 'sync_status': 'PENDING',
      'idempotency_key': 'idem-${_uuid()}', 'created_at_utc': now,
    };
    await insertProductionRecord(record);
    await insertSyncQueueItem({
      'id': 'sync-${_uuid()}', 'entity_type': 'PRODUCTION_RECORD', 'entity_id': id,
      'action': 'CREATE', 'payload_summary': 'Xác nhận hoàn thành · +${quantity.toStringAsFixed(0)}',
      'created_at_utc': now, 'retry_count': 0,
      'last_error_code': null, 'last_error_message': null, 'device_id': deviceId,
    });
  }

  Future<double> getCompletedQuantity(String assignmentId) async {
    return _productionRecords
        .where((r) => r['phan_cong_id'] == assignmentId)
        .fold<double>(0.0, (sum, r) => sum + (r['quantity'] as double));
  }

  Future<double> getTodayCompleted(String workerId, String businessDate) async {
    final workerAssignmentIds = _assignments
        .where((a) => a['nhan_vien_id'] == workerId)
        .map((a) => a['id'] as String)
        .toSet();
    return _productionRecords
        .where((r) =>
            workerAssignmentIds.contains(r['phan_cong_id']) &&
            r['business_date'] == businessDate)
        .fold<double>(0.0, (sum, r) => sum + (r['quantity'] as double));
  }

  Stream<List<Map<String, dynamic>>> watchRecordsByAssignment(String assignmentId) {
    Future.microtask(() => _notifyProduction());
    return _productionController.stream.map((all) =>
        all.where((r) => r['phan_cong_id'] == assignmentId).toList()
          ..sort((a, b) => (b['occurred_at_utc'] as int).compareTo(a['occurred_at_utc'] as int)));
  }

  void _notifyProduction() => _productionController.add(List.from(_productionRecords));

  Future<List<Map<String, dynamic>>> getProductionHistory(
    String employeeId, {
    String? fromBusinessDate,
    String? toBusinessDate,
  }) async {
    final assignmentIds = _assignments
        .where((a) => a['nhan_vien_id'] == employeeId)
        .map((a) => a['id'] as String)
        .toSet();

    final records = _productionRecords.where((r) {
      if (!assignmentIds.contains(r['phan_cong_id'])) return false;
      final d = r['business_date'] as String;
      if (fromBusinessDate != null && d.compareTo(fromBusinessDate) < 0) return false;
      if (toBusinessDate != null && d.compareTo(toBusinessDate) > 0) return false;
      return true;
    }).toList();

    return records.map((r) {
      final asg = _assignments.firstWhere((a) => a['id'] == r['phan_cong_id']);
      final order = _orders.firstWhere((o) => o['id'] == asg['don_hang_id'],
          orElse: () => {'ten_sp': 'Không rõ sản phẩm'});
      final confirmer = _employees.firstWhere(
          (e) => e['ma_nv'] == r['created_by'],
          orElse: () => {'ten': r['created_by']});
      return {
        ...r,
        'ten_sp': order['ten_sp'],
        'ma_don_hang': asg['don_hang_id'],
        'nguoi_xac_nhan': confirmer['ten'],
      };
    }).toList()
      ..sort((a, b) => (b['occurred_at_utc'] as int).compareTo(a['occurred_at_utc'] as int));
  }

  // ─── Recall Record Queries ────────────────────────────────────────
  Future<void> insertRecallRecord(Map<String, dynamic> record) async {
    _recallRecords.add(record);
    _notifyRecalls();
    _notifyAssignments();
  }

  Future<void> recordRecallOffline({
    required String assignmentId,
    required double quantity,
    required String reason,
    String? note,
    required String createdBy,
    required String deviceId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'recall-${_uuid()}';
    final record = {
      'id': id, 'phan_cong_id': assignmentId, 'quantity': quantity,
      'reason': reason, 'note': note, 'created_by': createdBy,
      'occurred_at_utc': now, 'device_id': deviceId, 'sync_status': 'PENDING',
      'idempotency_key': 'idem-${_uuid()}', 'created_at_utc': now,
    };
    await insertRecallRecord(record);

    final remaining = await getRemaining(assignmentId);
    if (remaining <= 0) {
      await updateAssignmentStatus(assignmentId, 'CLOSED', 'PENDING');
    }

    await insertSyncQueueItem({
      'id': 'sync-${_uuid()}', 'entity_type': 'RECALL_RECORD', 'entity_id': id,
      'action': 'CREATE', 'payload_summary': 'Thu hồi phân công · −${quantity.toStringAsFixed(0)}',
      'created_at_utc': now, 'retry_count': 0,
      'last_error_code': null, 'last_error_message': null, 'device_id': deviceId,
    });
  }

  Future<double> getRecalledQuantity(String assignmentId) async {
    return _recallRecords
        .where((r) => r['phan_cong_id'] == assignmentId)
        .fold<double>(0.0, (sum, r) => sum + (r['quantity'] as double));
  }

  Stream<List<Map<String, dynamic>>> watchRecallsByAssignment(String assignmentId) {
    Future.microtask(() => _notifyRecalls());
    return _recallController.stream.map((all) =>
        all.where((r) => r['phan_cong_id'] == assignmentId).toList()
          ..sort((a, b) => (b['occurred_at_utc'] as int).compareTo(a['occurred_at_utc'] as int)));
  }

  void _notifyRecalls() => _recallController.add(List.from(_recallRecords));

  // ─── Sync Queue Queries ───────────────────────────────────────────
  Future<void> insertSyncQueueItem(Map<String, dynamic> item) async {
    _syncQueue.add(item);
    _notifySyncQueue();
  }

  Stream<List<Map<String, dynamic>>> watchSyncQueue() {
    Future.microtask(() => _notifySyncQueue());
    return _syncQueueController.stream;
  }

  Stream<List<Map<String, dynamic>>> watchSyncFeed() {
    Future.microtask(() => _notifySyncQueue());
    return _syncQueueController.stream.map((items) => items.map((i) {
          final status = i['last_error_code'] != null ? 'FAILED' : 'PENDING';
          return {...i, 'status': status};
        }).toList()
          ..sort((a, b) => (b['created_at_utc'] as int).compareTo(a['created_at_utc'] as int)));
  }

  Stream<int> watchPendingCount() {
    return watchSyncQueue().map((items) =>
        items.where((i) => i['last_error_code'] == null).length);
  }

  Future<void> deleteSyncQueueItem(String id) async {
    _syncQueue.removeWhere((i) => i['id'] == id);
    _notifySyncQueue();
  }

  Future<void> updateSyncQueueError(String id, String errorCode, String errorMessage) async {
    final idx = _syncQueue.indexWhere((i) => i['id'] == id);
    if (idx != -1) {
      _syncQueue[idx]['retry_count'] = (_syncQueue[idx]['retry_count'] as int) + 1;
      _syncQueue[idx]['last_error_code'] = errorCode;
      _syncQueue[idx]['last_error_message'] = errorMessage;
      _notifySyncQueue();
    }
  }

  Future<bool> retrySyncItem(String id) async {
    await Future.delayed(const Duration(milliseconds: 600));
    final idx = _syncQueue.indexWhere((i) => i['id'] == id);
    if (idx == -1) return false;
    await deleteSyncQueueItem(id);
    return true;
  }

  void _notifySyncQueue() => _syncQueueController.add(List.from(_syncQueue));

  // ─── Audit Log ────────────────────────────────────────────────────
  Future<void> insertAuditLog(Map<String, dynamic> log) async {
    _auditLog.add(log);
  }

  // ─── Cleanup ──────────────────────────────────────────────────────
  void dispose() {
    _assignmentController.close();
    _syncQueueController.close();
    _productionController.close();
    _recallController.close();
  }
}
