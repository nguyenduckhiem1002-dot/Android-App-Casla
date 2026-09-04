/// What happened after a mutation was durably saved on the device.
///
/// A local commit is not the same thing as a SAP commit. Screens use this
/// receipt to avoid showing a green success message for work that still needs
/// connectivity or the worker's verification.
enum MutationDeliveryState { synced, queued, needsVerification, rejected }

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
}
