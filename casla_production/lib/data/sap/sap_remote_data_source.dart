// SAP Integration — Remote Data Source Interface + Mock
// Spec: Section 9
// When integrating with SAP, implement SapRealRemoteDataSource.

import '../../domain/entities/entities.dart';

/// Remote data source contract for SAP communication.
/// MVP uses MockRemoteDataSource. SAP phase swaps to SapRealRemoteDataSource.
abstract class SapRemoteDataSource {
  Future<bool> syncAssignment(Assignment assignment);
  Future<bool> syncProductionRecord(ProductionRecord record);
  Future<bool> syncRecallRecord(RecallRecord record);
  Future<Employee?> fetchEmployee(String maNv);
  Future<List<Map<String, dynamic>>> fetchMasterData(String entityType);
}

/// Mock implementation for MVP / offline development
class MockRemoteDataSource implements SapRemoteDataSource {
  @override
  Future<bool> syncAssignment(Assignment assignment) async {
    // Simulate network delay
    await Future.delayed(const Duration(milliseconds: 1000));
    return true;
  }

  @override
  Future<bool> syncProductionRecord(ProductionRecord record) async {
    await Future.delayed(const Duration(milliseconds: 800));
    return true;
  }

  @override
  Future<bool> syncRecallRecord(RecallRecord record) async {
    await Future.delayed(const Duration(milliseconds: 800));
    return true;
  }

  @override
  Future<Employee?> fetchEmployee(String maNv) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return null; // Use local cache in MVP
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMasterData(String entityType) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return []; // Use local seed data in MVP
  }
}
