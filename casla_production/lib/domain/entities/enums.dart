// Domain Enums — Casla Group
// Spec: Section 3.2 (Assignment Status), Section 2 (Roles/Permissions)

/// Trạng thái phân công (Spec 3.2)
enum AssignmentStatus {
  open,
  completed,
  recalled,
  closed,
  suspended;

  String get label {
    switch (this) {
      case AssignmentStatus.open:
        return 'OPEN';
      case AssignmentStatus.completed:
        return 'COMPLETED';
      case AssignmentStatus.recalled:
        return 'RECALLED';
      case AssignmentStatus.closed:
        return 'CLOSED';
      case AssignmentStatus.suspended:
        return 'SUSPENDED';
    }
  }

  bool get canRecord => this == AssignmentStatus.open;
}

/// Trạng thái đồng bộ SAP
enum SyncStatus {
  pending,
  syncing,
  needsVerification,
  synced,
  failed;

  static SyncStatus fromStorage(Object? value) {
    return switch (value?.toString().toUpperCase()) {
      'SYNCING' => SyncStatus.syncing,
      'NEEDS_VERIFICATION' => SyncStatus.needsVerification,
      'SYNCED' => SyncStatus.synced,
      'FAILED' => SyncStatus.failed,
      _ => SyncStatus.pending,
    };
  }

  String get label {
    switch (this) {
      case SyncStatus.pending:
        return 'PENDING';
      case SyncStatus.syncing:
        return 'SYNCING';
      case SyncStatus.needsVerification:
        return 'NEEDS_VERIFICATION';
      case SyncStatus.synced:
        return 'SYNCED';
      case SyncStatus.failed:
        return 'FAILED';
    }
  }
}

/// Vai trò người dùng (Spec 2)
enum UserRole {
  worker,
  supervisor,
  inspector,
  sapAdmin;

  String get label {
    switch (this) {
      case UserRole.worker:
        return 'Công nhân';
      case UserRole.supervisor:
        return 'Supervisor';
      case UserRole.inspector:
        return 'Kiểm tra';
      case UserRole.sapAdmin:
        return 'Quản trị SAP';
    }
  }
}

/// Ma trận quyền chi tiết (Spec 2.1)
///
/// Chỉ ba giá trị có [code] bắt đầu bằng `PP_` là FuncID có thật trong
/// `ztb_mob_func` — SAP chỉ phát hành `PP_INITIAL_ASSIGN`, `PP_HIST_SELF` và
/// `PP_HIST_TEAM`. Các [code] còn lại (`ASSIGN_QUANTITY`, `VIEW_SYNC_STATUS`,
/// …) là từ vựng nội bộ của app từ bản spec cũ; backend không hề biết đến
/// chúng, nên tuyệt đối không dùng để so khớp với FuncID SAP trả về —
/// `AuthRepositoryImpl.parseAuthorization` suy ra chúng từ vai trò.
enum Permission {
  viewOwnProduction,
  recordOwnProduction,
  assignQuantity,
  recallAssignment,
  viewTeamProduction,
  viewEmployeeHistory,
  viewSyncStatus,
  switchUser,
  // Real FuncIDs from ZUI_PP_OPALLOC's getWorkHistory (zcl_pp_work_history) —
  // a separate RBAC axis from the write permissions above. An account can
  // hold either without the other: PP_HIST_SELF only ever returns that
  // account's own rows (WorkerID sent from the app is ignored server-side),
  // PP_HIST_TEAM returns whoever the account booked as a supervisor.
  viewOwnProductionHistory,
  viewTeamProductionHistory;

  String get code {
    switch (this) {
      case Permission.viewOwnProduction:
        return 'VIEW_OWN_PRODUCTION';
      case Permission.recordOwnProduction:
        return 'RECORD_OWN_PRODUCTION';
      case Permission.assignQuantity:
        return 'ASSIGN_QUANTITY';
      case Permission.recallAssignment:
        return 'RECALL_ASSIGNMENT';
      case Permission.viewTeamProduction:
        return 'VIEW_TEAM_PRODUCTION';
      case Permission.viewEmployeeHistory:
        return 'VIEW_EMPLOYEE_HISTORY';
      case Permission.viewSyncStatus:
        return 'VIEW_SYNC_STATUS';
      case Permission.switchUser:
        return 'SWITCH_USER';
      case Permission.viewOwnProductionHistory:
        return 'PP_HIST_SELF';
      case Permission.viewTeamProductionHistory:
        return 'PP_HIST_TEAM';
    }
  }
}

/// Lý do thu hồi (Spec 5.3 S09)
enum RecallReason {
  notFinished('NOT_FINISHED', 'Không làm hết phần giao'),
  reassigned('REASSIGNED', 'Điều chuyển nhân sự'),
  planChange('PLAN_CHANGE', 'Thay đổi kế hoạch sản xuất'),
  terminated('TERMINATED', 'Kết thúc ca / Hủy đơn'),
  other('OTHER', 'Lý do khác');

  const RecallReason(this.code, this.title);
  final String code;
  final String title;
}
