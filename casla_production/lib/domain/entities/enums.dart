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
/// Chỉ hai vai trò này tồn tại: `parseAuthorization` suy ra vai trò từ FuncID
/// SAP trả về, và nó chỉ có thể trả về `supervisor` (có `PP_INITIAL_ASSIGN`)
/// hoặc `worker` (chỉ có quyền xem lịch sử).
enum UserRole {
  worker,
  supervisor;

  String get label {
    switch (this) {
      case UserRole.worker:
        return 'Công nhân';
      case UserRole.supervisor:
        return 'Supervisor';
    }
  }
}

/// Ma trận quyền chi tiết (Spec 2.1)
///
/// Đây là các cổng chặn màn hình *nội bộ app*, không phải FuncID của SAP.
/// SAP chỉ phát hành ba FuncID (`PP_INITIAL_ASSIGN`, `PP_HIST_SELF`,
/// `PP_HIST_TEAM`); `AuthRepositoryImpl.parseAuthorization` đọc ba mã đó rồi
/// suy ra tập quyền dưới đây từ vai trò. Trước kia enum này còn mang một
/// getter `code` sinh ra các chuỗi kiểu `ASSIGN_QUANTITY` để so khớp với
/// FuncID — chúng chưa bao giờ tồn tại trong `ztb_mob_func`, và việc so khớp
/// đó chính là thứ đã xếp nhầm tài khoản quản lý thành công nhân. Getter đã
/// bị bỏ để không ai vô tình dùng lại.
enum Permission {
  assignQuantity,
  recallAssignment,
  viewTeamProduction,
  viewEmployeeHistory,
  viewSyncStatus,
  switchUser,
  // Hai giá trị dưới đây ánh xạ 1-1 với PP_HIST_SELF / PP_HIST_TEAM trong
  // `zcl_pp_work_history` — một trục RBAC riêng so với nhóm quyền ghi ở trên.
  // Một tài khoản có thể có cái này mà không có cái kia: PP_HIST_SELF luôn chỉ
  // trả về dòng của chính tài khoản đó (WorkerID app gửi lên bị bỏ qua),
  // PP_HIST_TEAM trả về những người mà tài khoản đó đứng tên tổ trưởng.
  viewOwnProductionHistory,
  viewTeamProductionHistory,
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
