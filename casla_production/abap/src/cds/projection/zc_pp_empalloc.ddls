@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'API phân bổ sản lượng nhân công'
define view entity ZC_PP_EmpAlloc
  as projection on ZR_PP_EmpAlloc
{
  key EmployeeAllocationUUID,
      OperationUUID,
      WorkerID,
      InitialAssignedQuantity,
      TransferredInQuantity,
      TransferredOutQuantity,
      CompletedQuantity,
      RemainingQuantity,
      UnitOfMeasure,
      LastExecutionDate,
      LastSyncAt,
      CreatedBy,
      CreatedAt,
      LastChangedBy,
      LocalLastChangedAt,
      _Operation : redirected to parent ZC_PP_OpAlloc
}
