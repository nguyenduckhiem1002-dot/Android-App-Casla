// Domain Entities — Casla Group
// Spec: Section 8 (Data Model)
// Using plain Dart classes (Freezed can be added later with code generation)

import 'enums.dart';

/// Phân công (Spec 8.8) + computed fields (Spec 3.1)
class Assignment {
  final String id;
  final String workerId;
  final String workerMaNv;
  final String workerName;
  final String teamId;
  final String orderId;
  final String orderCode;
  final String productionOrder;
  final String operation;
  final String operationName;
  final String productCode;
  final String productName;
  final String plant;
  final String workCenter;
  final String uom;
  final double assignedQuantity;
  final double completedQuantity;
  final double defectQuantity;
  final double recalledQuantity;
  final String businessDate;
  final String shiftId;
  final AssignmentStatus status;
  final String? note;
  final String createdBy;
  final String idempotencyKey;
  final String sapId;
  final SyncStatus syncStatus;
  final int createdAtUtc;

  const Assignment({
    required this.id,
    required this.workerId,
    required this.workerMaNv,
    required this.workerName,
    required this.teamId,
    required this.orderId,
    required this.orderCode,
    this.productionOrder = '',
    this.operation = '',
    this.operationName = '',
    required this.productCode,
    required this.productName,
    this.plant = '',
    this.workCenter = '',
    required this.uom,
    required this.assignedQuantity,
    required this.completedQuantity,
    this.defectQuantity = 0,
    required this.recalledQuantity,
    required this.businessDate,
    required this.shiftId,
    required this.status,
    this.note,
    required this.createdBy,
    required this.idempotencyKey,
    this.sapId = '',
    required this.syncStatus,
    this.createdAtUtc = 0,
  });

  /// Giao hiệu lực = Giao ban đầu − Đã thu hồi (Spec 3.1)
  double get effectiveAssigned =>
      (assignedQuantity - recalledQuantity).clamp(0.0, double.infinity);

  /// Còn lại = Giao hiệu lực − Hoàn thành lũy kế (Spec 3.1)
  double get remaining =>
      (effectiveAssigned - completedQuantity - defectQuantity).clamp(
        0.0,
        double.infinity,
      );

  /// Có thể thu hồi = Giao ban đầu − Hoàn thành − Đã thu hồi (Spec 3.1)
  double get maxRecall =>
      (assignedQuantity - completedQuantity - defectQuantity - recalledQuantity)
          .clamp(0.0, double.infinity);

  /// Tỷ lệ hoàn thành
  double get completionRate =>
      effectiveAssigned > 0 ? completedQuantity / effectiveAssigned : 0.0;

  /// Có thể ghi nhận? (Spec 3.2)
  bool get canRecord => status == AssignmentStatus.open && remaining > 0;

  Assignment copyWith({
    double? completedQuantity,
    double? defectQuantity,
    double? recalledQuantity,
    AssignmentStatus? status,
    SyncStatus? syncStatus,
  }) {
    return Assignment(
      id: id,
      workerId: workerId,
      workerMaNv: workerMaNv,
      workerName: workerName,
      teamId: teamId,
      orderId: orderId,
      orderCode: orderCode,
      productionOrder: productionOrder,
      operation: operation,
      operationName: operationName,
      productCode: productCode,
      productName: productName,
      plant: plant,
      workCenter: workCenter,
      uom: uom,
      assignedQuantity: assignedQuantity,
      completedQuantity: completedQuantity ?? this.completedQuantity,
      defectQuantity: defectQuantity ?? this.defectQuantity,
      recalledQuantity: recalledQuantity ?? this.recalledQuantity,
      businessDate: businessDate,
      shiftId: shiftId,
      status: status ?? this.status,
      note: note,
      createdBy: createdBy,
      idempotencyKey: idempotencyKey,
      sapId: sapId,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAtUtc: createdAtUtc,
    );
  }
}

/// Ghi nhận sản lượng (Spec 8.9)
class ProductionRecord {
  final String id;
  final String assignmentId;
  final double quantity;
  final double defectQuantity;
  final String businessDate;
  final String shiftId;
  final String? note;
  final String createdBy;
  final int occurredAtUtc;
  final String deviceId;
  final String idempotencyKey;
  final SyncStatus syncStatus;

  const ProductionRecord({
    required this.id,
    required this.assignmentId,
    required this.quantity,
    this.defectQuantity = 0,
    required this.businessDate,
    required this.shiftId,
    this.note,
    required this.createdBy,
    required this.occurredAtUtc,
    required this.deviceId,
    required this.idempotencyKey,
    required this.syncStatus,
  });
}

/// Một phạm vi sản xuất mà SAP cấp cho phiên hiện tại.
///
/// Các trường khớp trực tiếp với `ZA_MOB_WorkContext` trong EDMX
/// `ZUI_MOB_AUTH`; giữ lại tên/mã thực từ SAP để UI không phải suy đoán tên tổ
/// từ mã SQLite cục bộ.
class UserWorkContext {
  final String workId;
  final String workName;
  final String plant;

  /// Human-readable plant name returned by SAP when available.
  final String plantName;
  final String workCenter;

  /// Human-readable Work Center (Xưởng) name returned by SAP when available.
  final String workCenterName;
  final String boPhan;
  final String location;

  const UserWorkContext({
    required this.workId,
    required this.workName,
    this.plant = '',
    this.plantName = '',
    this.workCenter = '',
    this.workCenterName = '',
    this.boPhan = '',
    this.location = '',
  });

  /// Xưởng name for display: SAP's Work Center text, else its Location.
  String get workCenterDisplayName {
    final name = workCenterName.trim();
    return name.isNotEmpty ? name : location.trim();
  }

  /// `CL100077 (Xưởng may 2)`, or whichever half SAP returned.
  String get workCenterLabel {
    final code = workCenter.trim();
    final name = workCenterDisplayName;
    if (code.isEmpty) return name;
    return name.isEmpty ? code : '$code ($name)';
  }

  /// `XM2.002 - MAY CHI TIẾT PHỤ-XM2`: Bộ phận code and name only.
  String get departmentLabel {
    final id = workId.trim();
    final name = workName.trim();
    if (id.isEmpty) return name;
    return name.isEmpty ? id : '$id - $name';
  }
}

/// Phiên đăng nhập
class UserSession {
  final String id;
  final String maNv;
  final String fullName;
  final String teamName;
  final String email;
  final String accessToken;

  /// Rotates on every `refresh` call — SyncSessionAdapter overwrites this
  /// after each successful refresh, since the old value is single-use and
  /// rejected on the next attempt.
  final String refreshToken;
  final bool passwordChangeRequired;
  final UserRole role;
  final Set<Permission> permissions;
  final List<String> toIds;

  /// Full SAP work contexts, not only their ids. `toIds` remains the compact
  /// authorization scope consumed by repositories and sync code.
  final List<UserWorkContext> workContexts;

  const UserSession({
    required this.id,
    required this.maNv,
    required this.fullName,
    required this.teamName,
    this.email = '',
    this.accessToken = '',
    this.refreshToken = '',
    this.passwordChangeRequired = false,
    required this.role,
    required this.permissions,
    this.toIds = const [],
    this.workContexts = const [],
  });

  UserSession copyWithTokens({
    required String accessToken,
    required String refreshToken,
  }) => UserSession(
    id: id,
    maNv: maNv,
    fullName: fullName,
    teamName: teamName,
    email: email,
    accessToken: accessToken,
    refreshToken: refreshToken,
    passwordChangeRequired: passwordChangeRequired,
    role: role,
    permissions: permissions,
    toIds: toIds,
    workContexts: workContexts,
  );

  String get userName => fullName;

  bool hasPermission(Permission permission) => permissions.contains(permission);

  String get initials {
    final parts = fullName.split(' ');
    if (parts.length >= 2) {
      return '${parts[parts.length - 2][0]}${parts.last[0]}';
    }
    return fullName.isNotEmpty ? fullName[0] : 'CG';
  }
}
