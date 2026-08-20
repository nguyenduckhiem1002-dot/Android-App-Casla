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
  final String productCode;
  final String productName;
  final String uom;
  final double assignedQuantity;
  final double completedQuantity;
  final double recalledQuantity;
  final String businessDate;
  final String shiftId;
  final AssignmentStatus status;
  final String? note;
  final String createdBy;
  final String idempotencyKey;
  final SyncStatus syncStatus;

  const Assignment({
    required this.id,
    required this.workerId,
    required this.workerMaNv,
    required this.workerName,
    required this.teamId,
    required this.orderId,
    required this.orderCode,
    required this.productCode,
    required this.productName,
    required this.uom,
    required this.assignedQuantity,
    required this.completedQuantity,
    required this.recalledQuantity,
    required this.businessDate,
    required this.shiftId,
    required this.status,
    this.note,
    required this.createdBy,
    required this.idempotencyKey,
    required this.syncStatus,
  });

  /// Giao hiệu lực = Giao ban đầu − Đã thu hồi (Spec 3.1)
  double get effectiveAssigned =>
      (assignedQuantity - recalledQuantity).clamp(0.0, double.infinity);

  /// Còn lại = Giao hiệu lực − Hoàn thành lũy kế (Spec 3.1)
  double get remaining =>
      (effectiveAssigned - completedQuantity).clamp(0.0, double.infinity);

  /// Có thể thu hồi = Giao ban đầu − Hoàn thành − Đã thu hồi (Spec 3.1)
  double get maxRecall =>
      (assignedQuantity - completedQuantity - recalledQuantity).clamp(
        0.0,
        double.infinity,
      );

  /// Tỷ lệ hoàn thành
  double get completionRate =>
      effectiveAssigned > 0 ? completedQuantity / effectiveAssigned : 0.0;

  /// Có thể ghi nhận? (Spec 3.2)
  bool get canRecord => status == AssignmentStatus.open && remaining > 0;

  Assignment copyWith({
    double? completedQuantity,
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
      productCode: productCode,
      productName: productName,
      uom: uom,
      assignedQuantity: assignedQuantity,
      completedQuantity: completedQuantity ?? this.completedQuantity,
      recalledQuantity: recalledQuantity ?? this.recalledQuantity,
      businessDate: businessDate,
      shiftId: shiftId,
      status: status ?? this.status,
      note: note,
      createdBy: createdBy,
      idempotencyKey: idempotencyKey,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

/// Ghi nhận sản lượng (Spec 8.9)
class ProductionRecord {
  final String id;
  final String assignmentId;
  final double quantity;
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

/// Phiên đăng nhập
class UserSession {
  final String id;
  final String maNv;
  final String fullName;
  final String teamName;
  final String email;
  final String accessToken;
  final bool passwordChangeRequired;
  final UserRole role;
  final Set<Permission> permissions;
  final List<String> toIds;

  const UserSession({
    required this.id,
    required this.maNv,
    required this.fullName,
    required this.teamName,
    this.email = '',
    this.accessToken = '',
    this.passwordChangeRequired = false,
    required this.role,
    required this.permissions,
    this.toIds = const [],
  });

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
