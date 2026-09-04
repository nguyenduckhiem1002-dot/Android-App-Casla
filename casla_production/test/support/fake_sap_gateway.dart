// A gateway for tests that exercise local business rules / queue bookkeeping
// and never actually mean to reach SAP.
//
// Every push fails (with a plain "unimplemented" error, deliberately not one
// of the classified SAP exception types) — repositories still write and queue
// locally either way, and this keeps a stray real network call from ever
// happening in a unit test.

import 'package:casla_production/core/sync/sap_write_gateway.dart';

class NoopSapGateway implements SapWriteGateway {
  @override
  Future<SapWriteResult> push(SyncPushRequest request) {
    throw UnimplementedError('NoopSapGateway does not push');
  }

  @override
  Future<bool> refreshSession() async => false;
}
