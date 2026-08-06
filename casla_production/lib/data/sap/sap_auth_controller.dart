// SAP Integration — Auth Controller
// Spec: Section 4.1 (Login flow), Section 10 (Security)
// Base auth flow: badge scan → cache check → SAP verify

import 'sap_odata_client.dart';
import 'sap_endpoints.dart';

/// Handles SAP authentication flow.
/// MVP Phase: Uses local cache only.
/// SAP Phase: Verifies against SAP backend.
class SapAuthController {
  final SapODataClient client;
  late final SapEndpoints endpoints;

  SapAuthController(this.client) {
    endpoints = SapEndpoints(client);
  }

  /// Authenticate user against SAP backend.
  /// Spec 4.1 Step 2: Tra cache; nếu có mạng xác thực SAP.
  /// Returns SAP user data or null if not found/unauthorized.
  Future<Map<String, dynamic>?> authenticateWithSap(String maNv) async {
    try {
      final response = await endpoints.getEmployee(maNv);
      if (response.isSuccess) {
        return response.data;
      }
      return null;
    } catch (e) {
      // If SAP unavailable, return null (use cache)
      return null;
    }
  }

  /// Fetch user permissions from SAP (Spec 2.1)
  Future<List<String>> fetchPermissions() async {
    try {
      final response = await endpoints.getMyPermissions();
      if (response.isSuccess && response.data != null) {
        final permissions = response.data!['permissions'] as List<dynamic>?;
        return permissions?.map((e) => e.toString()).toList() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Fetch supervisor scope (teams managed) from SAP (Spec 2)
  Future<List<String>> fetchSupervisorScope() async {
    try {
      final response = await endpoints.getSupervisorScope();
      if (response.isSuccess && response.data != null) {
        return response.data!.map((e) => e['teamId'].toString()).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Login with username/password (Spec S02b)
  Future<Map<String, dynamic>?> loginWithCredentials(
      String username, String password) async {
    try {
      final response = await client.dio.post(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/Login',
        data: {'username': username, 'password': password},
      );

      if (response.statusCode == 200) {
        final token = response.data['token'] as String?;
        if (token != null) {
          client.setAuthToken(token);
        }
        return response.data;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Refresh auth token
  Future<bool> refreshToken() async {
    try {
      final response = await client.dio.post(
        'sap/opu/odata/sap/ZC_PRODUCTION_SRV/RefreshToken',
      );
      if (response.statusCode == 200) {
        final token = response.data['token'] as String?;
        if (token != null) {
          client.setAuthToken(token);
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Logout — clear token
  void logout() {
    client.setAuthToken(null);
  }
}
