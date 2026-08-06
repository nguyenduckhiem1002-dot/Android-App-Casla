// SAP Integration — Data Transfer Objects
// Spec: Section 9.3 (Payload), 9.5 (OData/RAP mapping)

/// SAP API generic response wrapper
class SapApiResponse<T> {
  final T? data;
  final SapApiError? error;

  SapApiResponse({this.data, this.error});

  bool get isSuccess => error == null && data != null;
  bool get isError => error != null;

  factory SapApiResponse.fromJson(Map<String, dynamic> json) {
    return SapApiResponse(
      data: json['d'] as T?,
      error: json['error'] != null
          ? SapApiError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// SAP API error structure (Spec 9.4)
class SapApiError {
  final String code;
  final String message;

  SapApiError({required this.code, required this.message});

  factory SapApiError.fromJson(Map<String, dynamic> json) {
    return SapApiError(
      code: json['code'] as String? ?? 'UNKNOWN',
      message: json['message'] is Map
          ? json['message']['value'] as String? ?? 'Unknown error'
          : json['message'] as String? ?? 'Unknown error',
    );
  }
}

/// Assignment DTO for SAP (Spec 9.5: ZC_ProductionAssignment)
class SapAssignmentDto {
  final String idempotencyKey;
  final String workerId;
  final String orderId;
  final String teamId;
  final double assignedQuantity;
  final String businessDate;
  final String shiftId;
  final String status;
  final String? note;

  SapAssignmentDto({
    required this.idempotencyKey,
    required this.workerId,
    required this.orderId,
    required this.teamId,
    required this.assignedQuantity,
    required this.businessDate,
    required this.shiftId,
    this.status = 'OPEN',
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'idempotencyKey': idempotencyKey,
        'workerId': workerId,
        'orderId': orderId,
        'teamId': teamId,
        'assignedQuantity': assignedQuantity,
        'businessDate': businessDate,
        'shiftId': shiftId,
        'status': status,
        if (note != null) 'note': note,
      };
}

/// Production Entry DTO (Spec 9.3 payload)
class SapProductionEntryDto {
  final String idempotencyKey;
  final String assignmentId;
  final double quantity;
  final String businessDate;
  final String shiftId;
  final String occurredAtUtc;
  final String deviceId;

  SapProductionEntryDto({
    required this.idempotencyKey,
    required this.assignmentId,
    required this.quantity,
    required this.businessDate,
    required this.shiftId,
    required this.occurredAtUtc,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'idempotencyKey': idempotencyKey,
        'assignmentId': assignmentId,
        'quantity': quantity,
        'businessDate': businessDate,
        'shiftId': shiftId,
        'occurredAtUtc': occurredAtUtc,
        'deviceId': deviceId,
      };
}

/// Assignment Recall DTO
class SapAssignmentRecallDto {
  final String idempotencyKey;
  final String assignmentId;
  final double quantity;
  final String reasonCode;
  final String? note;
  final String businessDate;
  final String shiftId;
  final String occurredAtUtc;
  final String deviceId;

  SapAssignmentRecallDto({
    required this.idempotencyKey,
    required this.assignmentId,
    required this.quantity,
    required this.reasonCode,
    this.note,
    required this.businessDate,
    required this.shiftId,
    required this.occurredAtUtc,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'idempotencyKey': idempotencyKey,
        'assignmentId': assignmentId,
        'quantity': quantity,
        'reasonCode': reasonCode,
        if (note != null) 'note': note,
        'businessDate': businessDate,
        'shiftId': shiftId,
        'occurredAtUtc': occurredAtUtc,
        'deviceId': deviceId,
      };
}
