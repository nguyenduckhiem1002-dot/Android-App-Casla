@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'API phân bổ sản lượng công đoạn'
define root view entity ZC_PP_OpAlloc
  provider contract transactional_query
  as projection on ZR_PP_OpAlloc
{
  key OperationUUID,
      ProductionOrder,
      Operation,
      Plant,
      WorkCenter,
      OperationQuantity,
      UnitOfMeasure,
      OperationStatus,
      CreatedBy,
      CreatedAt,
      LastChangedBy,
      LocalLastChangedAt,
      _Employees : redirected to composition child ZC_PP_EmpAlloc,
      _Transactions : redirected to composition child ZC_PP_AllocTxn
}
