@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'API giao dịch phân bổ sản lượng'
define view entity ZC_PP_AllocTxn
  as projection on ZR_PP_AllocTxn
{
  key TransactionUUID,
      OperationUUID,
      OriginalTransactionUUID,
      SyncItemUUID,
      TransactionType,
      FromWorkerID,
      ToWorkerID,
      WorkerID,
      Quantity,
      UnitOfMeasure,
      ExecutionDate,
      TransactionStatus,
      SAPConfirmationGroup,
      SAPConfirmationCount,
      SAPErrorCode,
      SAPErrorText,
      CreatedBy,
      CreatedAt,
      LocalLastChangedAt,
      _Operation : redirected to parent ZC_PP_OpAlloc
}
