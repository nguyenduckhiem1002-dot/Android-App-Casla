@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'Tham chiếu nhân công để kiểm tra'
define view entity ZI_PP_WorkerRef
  as select from ztb_kb_nhancong
{
  key uuid_nhancong as WorkerUUID,
      worker_id     as WorkerID,
      from_date     as ValidFrom,
      to_date       as ValidTo,
      work_center   as WorkCenter,
      plant         as Plant,
      worker_name   as WorkerName
}
