CLASS zcl_pp_worker_validator DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS is_worker_active
      IMPORTING
        worker_id      TYPE c LENGTH 8
        plant          TYPE c LENGTH 4
        work_center    TYPE c LENGTH 8
        execution_date TYPE d
      RETURNING
        VALUE(result)  TYPE abap_bool.
ENDCLASS.

CLASS zcl_pp_worker_validator IMPLEMENTATION.
  METHOD is_worker_active.
    SELECT SINGLE FROM zi_pp_workerref
      FIELDS @abap_true
      WHERE WorkerID   = @worker_id
        AND Plant      = @plant
        AND WorkCenter = @work_center
        AND ValidFrom <= @execution_date
        AND ValidTo   >= @execution_date
      INTO @result.
  ENDMETHOD.
ENDCLASS.

