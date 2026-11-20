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
/// SAP trả về, và nó chỉ có thể trả về `supervisor` (có ít nhất một trong
/// `PP_INITIAL_ASSIGN` / `PP_CONFIRM` / `PP_RECALL`, kèm `PP_HIST_TEAM`) hoặc
/// `worker` (chỉ có quyền xem lịch sử).
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
/// `AuthRepositoryImpl.parseAuthorization` đọc các FuncID SAP trả về
/// (`PP_INITIAL_ASSIGN`, `PP_CONFIRM`, `PP_RECALL`, `PP_HIST_SELF`,
/// `PP_HIST_TEAM`, `PP_POS_MANAGE`) rồi suy ra tập quyền dưới đây. Trước kia enum này còn mang một
/// getter `code` sinh ra các chuỗi kiểu `ASSIGN_QUANTITY` để so khớp với
/// FuncID — chúng chưa bao giờ tồn tại trong `ztb_mob_func`, và việc so khớp
/// đó chính là thứ đã xếp nhầm tài khoản quản lý thành công nhân. Getter đã
/// bị bỏ để không ai vô tình dùng lại.
enum Permission {
  // Ba quyền thao tác chính, ánh xạ 1-1 với FuncID mà `zbp_r_pp_opalloc`
  // kiểm tra trên từng action: PP_INITIAL_ASSIGN (giao), PP_CONFIRM (xác nhận),
  // PP_RECALL (thu hồi). Có một trong ba là vào được Tổng quan; mỗi quyền chỉ
  // mở menu/nút của chính nó.
  assignQuantity,
  confirmProduction,
  recallAssignment,
  // PP_RECALL_NOPASS, chỉ có nghĩa khi đi kèm PP_RECALL: quản lý được thu hồi
  // toàn bộ phần còn lại của công nhân mà không cần mật khẩu công nhân (công
  // nhân nghỉ, bàn giao cho người khác). `zbp_r_pp_opalloc` nhận WorkerPassword
  // rỗng ở `recall` chỉ khi tài khoản có function này.
  recallWithoutPassword,
  viewTeamProduction,
  viewEmployeeHistory,
  viewSyncStatus,
  switchUser,
  // Hai giá trị dưới đây ánh xạ 1-1 với PP_HIST_SELF / PP_HIST_TEAM trong
  // `zcl_pp_work_history` — một trục RBAC riêng so với nhóm quyền ghi ở trên.
  // Một tài khoản có thể có cái này mà không có cái kia: PP_HIST_SELF luôn chỉ
  // trả về dòng của chính tài khoản đó (WorkerID app gửi lên bị bỏ qua),
  // PP_HIST_TEAM trả về mọi giao dịch tại các WorkID/công đoạn tài khoản được
  // cấp quyền, kể cả việc do quản lý khác giao (bàn giao ca) — xem
  // docs/TEAM_HISTORY_SCOPE.md bên abap_casla_app_mobile.
  viewOwnProductionHistory,
  viewTeamProductionHistory,
  // PP_POS_MANAGE trong `zcl_pp_position_api`: xem sơ đồ vị trí, tạo vị trí,
  // đổi máy và xếp công nhân. SAP chỉ cho phép trên Work Center được cấp
  // function này, app chỉ dùng nó để hiện tab Vị trí.
  managePositions,
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
