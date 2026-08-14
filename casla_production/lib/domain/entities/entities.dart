// Domain Entities — Casla Group
// Spec: Section 8 (Data Model)
// Using plain Dart classes (Freezed can be added later with code generation)

import 'enums.dart';

/// Nhân viên (Spec 8.2)
class Employee {
  final String id;
  final String maNv;
  final String fullName;
  final String department;
  final String status;
  final String? sapId;
  final int? updatedAtUtc;

  const Employee({
    required this.id,
    required this.maNv,
    required this.fullName,
    required this.department,
    this.status = 'ACTIVE',
    this.sapId,
    this.updatedAtUtc,
  });

  String get initials {
    final parts = fullName.split(' ');
    if (parts.length >= 2) {
      return '${parts[parts.length - 2][0]}${parts.last[0]}';
    }
    return fullName.isNotEmpty ? fullName[0] : 'CG';
  }
}

/// Tổ sản xuất (Spec 8.3)
class Team {
  final String id;
  final String maTo;
  final String tenTo;
  final String department;
  final String status;
  final String? sapId;

  const Team({
    required this.id,
    required this.maTo,
    required this.tenTo,
    required this.department,
    this.status = 'ACTIVE',
    this.sapId,
  });
}

/// Đơn hàng sản xuất (Spec 8.6)
class ProductionOrder {
  final String id;
  final String orderCode;
  final String productCode;
  final String productName;
  final String uom;
  final double totalQuantity;
  final String status;
  final String? sapId;

  const ProductionOrder({
    required this.id,
    required this.orderCode,
    required this.productCode,
    required this.productName,
    required this.uom,
    required this.totalQuantity,
    this.status = 'OPEN',
    this.sapId,
  });
}

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

/// Thu hồi phân công (Spec 8.10)
class RecallRecord {
  final String id;
  final String assignmentId;
  final double quantity;
  final String reasonCode;
  final String? note;
  final String businessDate;
  final String shiftId;
  final String createdBy;
  final int occurredAtUtc;
  final String deviceId;
  final String idempotencyKey;
  final SyncStatus syncStatus;

  const RecallRecord({
    required this.id,
    required this.assignmentId,
    required this.quantity,
    required this.reasonCode,
    this.note,
    required this.businessDate,
    required this.shiftId,
    required this.createdBy,
    required this.occurredAtUtc,
    required this.deviceId,
    required this.idempotencyKey,
    required this.syncStatus,
  });
}

/// SyncQueue item (Spec 8.11)
class SyncQueueItem {
  final String id;
  final String entityType;
  final String entityId;
  final String action;
  final int priority;
  final int retryCount;
  final int? nextRetryAtUtc;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int createdAtUtc;

  const SyncQueueItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.priority = 1,
    this.retryCount = 0,
    this.nextRetryAtUtc,
    this.lastErrorCode,
    this.lastErrorMessage,
    required this.createdAtUtc,
  });
}

/// Audit log item (Spec 8.12)
class AuditLogItem {
  final String id;
  final String eventType;
  final String actorId;
  final String? targetEmployeeId;
  final String? entityType;
  final String? entityId;
  final String? businessDate;
  final String? shiftId;
  final int occurredAtUtc;
  final String deviceId;
  final String? metadataJson;

  const AuditLogItem({
    required this.id,
    required this.eventType,
    required this.actorId,
    this.targetEmployeeId,
    this.entityType,
    this.entityId,
    this.businessDate,
    this.shiftId,
    required this.occurredAtUtc,
    required this.deviceId,
    this.metadataJson,
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
    this.toIds = const ['team-1', 'team-2', 'team-3'],
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

/// Thông tin ca làm việc (Spec 3.3)
class ShiftInfo {
  final String shiftId;
  final String shiftName;
  final String businessDate;

  const ShiftInfo({
    required this.shiftId,
    required this.shiftName,
    required this.businessDate,
  });
}

/// Tóm tắt hôm nay của công nhân
class WorkerTodaySummary {
  final double effectiveAssigned;
  final double completedToday;
  final double cumulativeCompleted;
  final double remaining;
  final int pendingSyncCount;

  const WorkerTodaySummary({
    required this.effectiveAssigned,
    required this.completedToday,
    required this.cumulativeCompleted,
    required this.remaining,
    required this.pendingSyncCount,
  });
}

/// Tổng quan Supervisor
class SupervisorOverviewSummary {
  final double totalEffectiveAssigned;
  final double totalCompleted;
  final int activeWorkersCount;
  final int openAssignmentsCount;

  const SupervisorOverviewSummary({
    required this.totalEffectiveAssigned,
    required this.totalCompleted,
    required this.activeWorkersCount,
    required this.openAssignmentsCount,
  });
}
