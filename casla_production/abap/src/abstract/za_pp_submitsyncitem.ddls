@EndUserText.label: 'Tham số chi tiết đồng bộ di động'
define abstract entity ZA_PP_SubmitSyncItem
{
  ExternalItemID : abap.char(64);
  TransactionType : abap.char(20);
  ProductionOrder : abap.char(12);
  Operation : abap.char(4);
  FromWorkerID : abap.char(8);
  ToWorkerID : abap.char(8);
  WorkerID : abap.char(8);
  @Semantics.quantity.unitOfMeasure: 'UnitOfMeasure'
  Quantity : abap.quan(15,3);
  UnitOfMeasure : abap.unit(3);
  ExecutionDate : abap.dats;
  MobileChangedAt : abap.utclong;
}
