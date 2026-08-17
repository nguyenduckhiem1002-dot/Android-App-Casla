@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'Phân bổ sản lượng công đoạn'
define root view entity ZR_PP_OpAlloc
  as select from ztb_pp_op_alloc
  composition [0..*] of ZR_PP_EmpAlloc as _Employees
  composition [0..*] of ZR_PP_AllocTxn as _Transactions
{
  key operation_uuid       as OperationUUID,
      production_order     as ProductionOrder,
      operation_no         as Operation,
      plant                as Plant,
      work_center          as WorkCenter,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      operation_qty        as OperationQuantity,
      uom                  as UnitOfMeasure,
      operation_status     as OperationStatus,
      created_by           as CreatedBy,
      created_at           as CreatedAt,
      last_changed_by      as LastChangedBy,
      local_last_changed_at as LocalLastChangedAt,
      _Employees,
      _Transactions
}
