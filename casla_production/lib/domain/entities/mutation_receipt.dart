/// What happened after a mutation was durably saved on the device.
///
/// A local commit is not the same thing as a SAP commit. Screens use this
/// receipt to avoid showing a green success message for work that still needs
/// connectivity or the worker's verification.
///
/// [discarded] is the one state where nothing is kept: SAP refused the live
/// submit for a reason the operator must fix on the spot (inactive account,
/// wrong worker password, missing authority), so the local write was rolled
/// back instead of being parked on the Đồng bộ tab.
enum MutationDeliveryState {
  synced,
  queued,
  needsVerification,
  rejected,
  discarded,
}

class MutationReceipt {
  final String id;
  final MutationDeliveryState state;
  final String? code;
  final String? message;

  const MutationReceipt({
    required this.id,
    required this.state,
    this.code,
    this.message,
  });

  /// SAP refused the worker's password; the operator may re-enter it.
  bool get isWrongWorkerPassword =>
      state == MutationDeliveryState.discarded && code == 'WORKER_AUTH_FAILED';

  /// SAP did not accept the transaction (kept for review, or rolled back).
  bool get isRefused =>
      state == MutationDeliveryState.rejected ||
      state == MutationDeliveryState.discarded;
}
