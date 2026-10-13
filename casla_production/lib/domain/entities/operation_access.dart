/// Result of SAP's operation access/quantity check used before an assignment.
///
/// The values are the server snapshot. The caller may add local pending
/// transactions before showing the final device-side balance.
class OperationAccessResult {
  final bool isAllowed;
  final String errorCode;
  final String message;
  final String productionOrder;
  final String operation;
  final String maCongDoan;
  final String plant;
  final String workCenter;
  final String workId;
  final String shiftId;
  final String workDate;
  final String unitOfMeasure;
  final double operationQuantity;
  final double initialAssignedQuantity;
  final double currentAssignedQuantity;
  final double completedQuantity;
  final double defectQuantity;
  final double recalledQuantity;
  final double remainingQuantity;
  final double transferredInQuantity;
  final double transferredOutQuantity;
  final double unassignedQuantity;

  const OperationAccessResult({
    required this.isAllowed,
    this.errorCode = '',
    this.message = '',
    this.productionOrder = '',
    this.operation = '',
    this.maCongDoan = '',
    this.plant = '',
    this.workCenter = '',
    this.workId = '',
    this.shiftId = '',
    this.workDate = '',
    this.unitOfMeasure = '',
    this.operationQuantity = 0,
    this.initialAssignedQuantity = 0,
    this.currentAssignedQuantity = 0,
    this.completedQuantity = 0,
    this.defectQuantity = 0,
    this.recalledQuantity = 0,
    this.remainingQuantity = 0,
    this.transferredInQuantity = 0,
    this.transferredOutQuantity = 0,
    this.unassignedQuantity = 0,
  });

  factory OperationAccessResult.fromJson(Map<String, dynamic> json) {
    double number(Object? value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString().trim() ?? '') ?? 0;
    }

    String text(String key) => (json[key] ?? '').toString().trim();
    final allowedValue = json['IsAllowed'];
    final isAllowed = allowedValue is bool
        ? allowedValue
        : const {
            'true',
            '1',
            'x',
          }.contains(allowedValue?.toString().trim().toLowerCase());

    return OperationAccessResult(
      isAllowed: isAllowed,
      errorCode: text('ErrorCode'),
      message: text('Message'),
      productionOrder: text('ProductionOrder'),
      operation: text('Operation'),
      maCongDoan: text('MaCongDoan'),
      plant: text('Plant'),
      workCenter: text('WorkCenter'),
      workId: text('WorkID'),
      shiftId: text('ShiftID'),
      workDate: text('WorkDate'),
      unitOfMeasure: text('UnitOfMeasure'),
      operationQuantity: number(json['OperationQuantity']),
      initialAssignedQuantity: number(json['InitialAssignedQuantity']),
      currentAssignedQuantity: number(json['CurrentAssignedQuantity']),
      completedQuantity: number(json['CompletedQuantity']),
      defectQuantity: number(json['DefectQuantity']),
      recalledQuantity: number(json['RecalledQuantity']),
      remainingQuantity: number(json['RemainingQuantity']),
      transferredInQuantity: number(json['TransferredInQuantity']),
      transferredOutQuantity: number(json['TransferredOutQuantity']),
      unassignedQuantity: number(json['UnassignedQuantity']),
    );
  }
}
