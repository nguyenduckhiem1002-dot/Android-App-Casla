@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'Giao dịch phân bổ sản lượng'
define view entity ZR_PP_AllocTxn
  as select from ztb_pp_alloc_txn
  association to parent ZR_PP_OpAlloc as _Operation
    on $projection.OperationUUID = _Operation.OperationUUID
{
  key transaction_uuid          as TransactionUUID,
      operation_uuid            as OperationUUID,
      original_transaction_uuid as OriginalTransactionUUID,
      sync_item_uuid            as SyncItemUUID,
      transaction_type          as TransactionType,
      from_worker_id            as FromWorkerID,
      to_worker_id              as ToWorkerID,
      worker_id                 as WorkerID,
      @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
      quantity                  as Quantity,
      uom                       as UnitOfMeasure,
      execution_date            as ExecutionDate,
      transaction_status        as TransactionStatus,
      sap_confirmation_group    as SAPConfirmationGroup,
      sap_confirmation_count    as SAPConfirmationCount,
      sap_error_code            as SAPErrorCode,
      sap_error_text            as SAPErrorText,
      created_by                as CreatedBy,
      created_at                as CreatedAt,
      local_last_changed_at     as LocalLastChangedAt,
      _Operation
}
