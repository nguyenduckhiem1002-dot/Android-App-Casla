// SAP Integration — API Endpoints
// Spec: Section 9.2 (Logical endpoints), Section 9.5 (OData/RAP mapping)

import 'sap_dtos.dart';
import 'sap_odata_client.dart';

/// SAP OData/RAP endpoint methods
/// Tên entity cuối cùng do đội SAP chốt. Flutter chỉ phụ thuộc repository/domain model;
/// mapping nằm trong SapRemoteDataSource.
class SapEndpoints {
  final SapODataClient client;

  SapEndpoints(this.client);

  // ─── Employee ─────────────────────────────────────────────────────
  /// GET /employees/{maNV}
  Future<SapApiResponse<Map<String, dynamic>>> getEmployee(String maNv) async {
    final response = await client.dio.get(
      "sap/opu/odata/sap/ZC_PRODUCTION_SRV/Employees('$maNv')",
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Permissions ──────────────────────────────────────────────────
  /// GET /me/permissions
  Future<SapApiResponse<Map<String, dynamic>>> getMyPermissions() async {
    final response = await client.dio.get(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/MyPermissions',
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Supervisor Scope ─────────────────────────────────────────────
  /// GET /supervisors/me/scope
  Future<SapApiResponse<List<dynamic>>> getSupervisorScope() async {
    final response = await client.dio.get(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/SupervisorScope',
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Assignments ──────────────────────────────────────────────────
  /// GET /assignments?employeeId=...
  Future<SapApiResponse<List<dynamic>>> getAssignments({
    String? employeeId,
    String? teamId,
  }) async {
    final queryParams = <String, dynamic>{};
    if (employeeId != null) queryParams['employeeId'] = employeeId;
    if (teamId != null) queryParams['teamId'] = teamId;

    final response = await client.dio.get(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_ProductionAssignment',
      queryParameters: queryParams,
    );
    return SapApiResponse.fromJson(response.data);
  }

  /// POST /assignments (Idempotent — Spec 9.4)
  Future<SapApiResponse<Map<String, dynamic>>> createAssignment(
      SapAssignmentDto dto) async {
    final response = await client.dio.post(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_ProductionAssignment',
      data: dto.toJson(),
      options: Options(headers: {'x-idempotency-key': dto.idempotencyKey}),
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Production Entries ───────────────────────────────────────────
  /// POST /production-entries (Idempotent — Spec 9.3)
  Future<SapApiResponse<Map<String, dynamic>>> postProductionEntry(
      SapProductionEntryDto dto) async {
    final response = await client.dio.post(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_ProductionEntry',
      data: dto.toJson(),
      options: Options(headers: {'x-idempotency-key': dto.idempotencyKey}),
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Assignment Recalls ───────────────────────────────────────────
  /// POST /assignment-recalls (Idempotent)
  Future<SapApiResponse<Map<String, dynamic>>> postAssignmentRecall(
      SapAssignmentRecallDto dto) async {
    final response = await client.dio.post(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_AssignmentRecall',
      data: dto.toJson(),
      options: Options(headers: {'x-idempotency-key': dto.idempotencyKey}),
    );
    return SapApiResponse.fromJson(response.data);
  }

  // ─── Summary & Logs ───────────────────────────────────────────────
  /// GET /employees/{id}/summary
  Future<SapApiResponse<Map<String, dynamic>>> getEmployeeSummary(
    String employeeId, {
    String? dateFrom,
    String? dateTo,
    List<String>? shiftIds,
  }) async {
    final response = await client.dio.get(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_EmployeeProductionSummary',
      queryParameters: {
        'employeeId': employeeId,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
        if (shiftIds != null) 'shiftIds': shiftIds.join(','),
      },
    );
    return SapApiResponse.fromJson(response.data);
  }

  /// GET /employees/{id}/logs
  Future<SapApiResponse<List<dynamic>>> getEmployeeLogs(
    String employeeId, {
    String? dateFrom,
    String? dateTo,
  }) async {
    final response = await client.dio.get(
      'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ZC_ProductionLog',
      queryParameters: {
        'employeeId': employeeId,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      },
    );
    return SapApiResponse.fromJson(response.data);
  }
}
