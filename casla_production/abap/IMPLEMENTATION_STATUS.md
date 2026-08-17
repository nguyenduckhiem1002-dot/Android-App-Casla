# Implementation status

## Implemented in this milestone

- Five custom persistence tables.
- `ZI_PP_WorkerRef` validation view over existing `ZTB_KB_NHANCONG`.
- Flat and deep abstract entities for RAP action contracts.
- Operation allocation composition tree:
  - `ZR_PP_OpAlloc`
  - `ZR_PP_EmpAlloc`
  - `ZR_PP_AllocTxn`
- Projection entities and projection behavior.
- Managed RAP interface behavior with root locking and ETag.
- Root validation and worker validation utility class.
- Service definition `ZUI_PP_OPALLOC`.

## Deliberately fail-closed

The following actions are declared but currently return an error message:

- `initialAssign`
- `transfer`
- `confirm`
- `reverse`

This prevents incomplete logic from changing production quantities. They will be
enabled incrementally after the base objects activate on the target tenant.

## Required target-system checks

1. Confirm all built-in types and released objects in the tenant release.
2. Generate/adjust behavior-pool method signatures using ADT quick fixes.
3. Create database secondary indexes:
   - `ZTB_PP_SYNC_H`: `MANDT + DEVICE_ID + EXTERNAL_ID` unique.
   - `ZTB_PP_SYNC_I`: `MANDT + SYNC_UUID + EXTERNAL_ITEM_ID` unique.
   - `ZTB_PP_OP_ALLOC`: `MANDT + PRODUCTION_ORDER + OPERATION_NO` unique.
   - `ZTB_KB_NHANCONG`: lookup index on plant/work center/worker/from date.
4. Add overlap validation to the worker-maintenance BO.
5. Confirm the released Production Order read interface used for live quantity,
   UoM, Plant, Work Center, TECO and CLSD checks.
6. Decide and verify `I_ProductionOrdConfirmationTP` versus
   `API_PROD_ORDER_CONFIRMATION_2_SRV`.
7. Replace allow-all authorization skeleton with the final authorization object.

## Next implementation slice

1. Implement `initialAssign` atomically with balance and ledger creation.
2. Add ABAP Unit tests for capacity and worker validity rules.
3. Implement `transfer`, including auto-create of the target employee balance.
4. Build the Sync Inbox RAP BO and `submitSync` idempotency flow.
5. Run the bgPF per-header versus per-item PoC.
