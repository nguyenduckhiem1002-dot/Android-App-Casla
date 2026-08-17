@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'Phân bổ sản lượng nhân công'
define view entity ZR_PP_EmpAlloc
  as select from ztb_pp_emp_alloc
  association to parent ZR_PP_OpAlloc as _Operation
    on $projection.OperationUUID = _Operation.OperationUUID
{
  key emp_alloc_uuid       as EmployeeAllocationUUID,
      operation_uuid       as OperationUUID,
      worker_id            as WorkerID,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      initial_assigned_qty as InitialAssignedQuantity,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      transferred_in_qty   as TransferredInQuantity,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      transferred_out_qty  as TransferredOutQuantity,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      completed_qty        as CompletedQuantity,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      remaining_qty        as RemainingQuantity,
      uom                  as UnitOfMeasure,
      last_execution_date  as LastExecutionDate,
      last_sync_at         as LastSyncAt,
      created_by           as CreatedBy,
      created_at           as CreatedAt,
      last_changed_by      as LastChangedBy,
      local_last_changed_at as LocalLastChangedAt,
      _Operation
}
