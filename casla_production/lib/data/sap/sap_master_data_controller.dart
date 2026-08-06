// SAP Integration — Master Data Controller
// Spec: Section 9 (Repository, API)
// Pulls master data from SAP → local cache

import 'sap_endpoints.dart';
import 'sap_odata_client.dart';

/// Controller for syncing master data (employees, orders, teams, shifts)
/// from SAP to local SQLite cache.
/// Spec: Cache master data — Giữ đủ để offline một ngày; refresh khi mở phiên/có mạng.
class SapMasterDataController {
  final SapODataClient client;
  late final SapEndpoints endpoints;

  SapMasterDataController(this.client) {
    endpoints = SapEndpoints(client);
  }

  /// Pull employees from SAP and return raw data for local storage
  Future<List<Map<String, dynamic>>> fetchEmployees() async {
    try {
      final response = await client.dio.get(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/Employees',
      );
      if (response.statusCode == 200) {
        final results = response.data['d']?['results'] as List<dynamic>?;
        return results?.cast<Map<String, dynamic>>() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Pull production orders from SAP
  Future<List<Map<String, dynamic>>> fetchOrders() async {
    try {
      final response = await client.dio.get(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/ProductionOrders',
        queryParameters: {'status': 'OPEN'},
      );
      if (response.statusCode == 200) {
        final results = response.data['d']?['results'] as List<dynamic>?;
        return results?.cast<Map<String, dynamic>>() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Pull teams from SAP
  Future<List<Map<String, dynamic>>> fetchTeams() async {
    try {
      final response = await client.dio.get(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/Teams',
      );
      if (response.statusCode == 200) {
        final results = response.data['d']?['results'] as List<dynamic>?;
        return results?.cast<Map<String, dynamic>>() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Pull shifts from SAP
  Future<List<Map<String, dynamic>>> fetchShifts() async {
    try {
      final response = await client.dio.get(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/Shifts',
      );
      if (response.statusCode == 200) {
        final results = response.data['d']?['results'] as List<dynamic>?;
        return results?.cast<Map<String, dynamic>>() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Full master data refresh (called on session start or reconnection)
  Future<Map<String, List<Map<String, dynamic>>>> refreshAll() async {
    final results = await Future.wait([
      fetchEmployees(),
      fetchOrders(),
      fetchTeams(),
      fetchShifts(),
    ]);

    return {
      'employees': results[0],
      'orders': results[1],
      'teams': results[2],
      'shifts': results[3],
    };
  }
}
