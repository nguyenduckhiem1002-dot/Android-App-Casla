CLASS lhc_operationallocation DEFINITION
  INHERITING FROM cl_abap_behavior_handler.

  PRIVATE SECTION.
    TYPES reported_response TYPE RESPONSE FOR REPORTED zr_pp_opalloc.
    TYPES failed_response TYPE RESPONSE FOR FAILED zr_pp_opalloc.
    TYPES: BEGIN OF operation_context,
             is_valid         TYPE abap_bool,
             error_code       TYPE c LENGTH 40,
             operation_uuid   TYPE ztb_pp_op_alloc-operation_uuid,
             production_order TYPE ztb_pp_op_alloc-production_order,
             operation_no     TYPE ztb_pp_op_alloc-operation_no,
             ma_congdoan      TYPE ztb_pp_op_alloc-ma_congdoan,
             plant            TYPE ztb_pp_op_alloc-plant,
             work_center      TYPE ztb_pp_op_alloc-work_center,
             operation_qty    TYPE ztb_pp_op_alloc-operation_qty,
             uom              TYPE ztb_pp_op_alloc-uom,
           END OF operation_context.

    METHODS get_global_authorizations FOR GLOBAL AUTHORIZATION
      IMPORTING REQUEST requested_authorizations FOR OperationAllocation
      RESULT result.

    METHODS validateOperation FOR VALIDATE ON SAVE
      IMPORTING keys FOR OperationAllocation~validateOperation.

    METHODS initialAssign FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~initialAssign
      RESULT result.
    METHODS transfer FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~transfer
      RESULT result.
    METHODS recall FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~recall
      RESULT result.
    METHODS confirm FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~confirm
      RESULT result.
    METHODS reverse FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~reverse
      RESULT result.
    METHODS correctConfirm FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~correctConfirm
      RESULT result.

    METHODS submitInitialAssign FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~submitInitialAssign
      RESULT result.
    METHODS submitTransfer FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~submitTransfer
      RESULT result.
    METHODS submitRecall FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~submitRecall
      RESULT result.
    METHODS submitConfirm FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~submitConfirm
      RESULT result.
    METHODS submitReverse FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~submitReverse
      RESULT result.
    METHODS getSyncStatus FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~getSyncStatus
      RESULT result.
    METHODS getWorkHistory FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~getWorkHistory
      RESULT result.

    METHODS ensure_operation
      IMPORTING
        production_order TYPE ztb_pp_op_alloc-production_order
        operation_no     TYPE ztb_pp_op_alloc-operation_no
      RETURNING VALUE(value) TYPE operation_context.

    METHODS report_instance_failure
      IMPORTING operation_uuid TYPE ztb_pp_op_alloc-operation_uuid
                text TYPE string
      CHANGING failed TYPE failed_response reported TYPE reported_response.

    METHODS forward_action_failure
      IMPORTING cid TYPE string
                operation_uuid TYPE ztb_pp_op_alloc-operation_uuid
                action_reported TYPE reported_response
      CHANGING failed TYPE failed_response reported TYPE reported_response.

    METHODS report_failure
      IMPORTING cid TYPE string text TYPE string
      CHANGING failed TYPE failed_response reported TYPE reported_response.
ENDCLASS.

CLASS lhc_employeeallocation DEFINITION
  INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    METHODS validateBalance FOR VALIDATE ON SAVE
      IMPORTING keys FOR EmployeeAllocation~validateBalance.
ENDCLASS.

CLASS lhc_employeeallocation IMPLEMENTATION.
  METHOD validateBalance.
    READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
      ENTITY EmployeeAllocation
      FIELDS ( InitialAssignedQuantity TransferredInQuantity
               TransferredOutQuantity RecalledQuantity CompletedQuantity
               RemainingQuantity )
      WITH CORRESPONDING #( keys )
      RESULT DATA(allocations).

    LOOP AT allocations ASSIGNING FIELD-SYMBOL(<allocation>).
      DATA expected_remaining TYPE ztb_pp_emp_alloc-remaining_qty.
      expected_remaining =
        <allocation>-InitialAssignedQuantity
        + <allocation>-TransferredInQuantity
        - <allocation>-TransferredOutQuantity
        - <allocation>-RecalledQuantity
        - <allocation>-CompletedQuantity.
      IF expected_remaining < 0
         OR <allocation>-RemainingQuantity <> expected_remaining.
        APPEND VALUE #( %tky = <allocation>-%tky ) TO failed-employeeallocation.
        APPEND VALUE #(
          %tky = <allocation>-%tky
          %element-RemainingQuantity = if_abap_behv=>mk-on
          %msg = new_message_with_text(
            severity = if_abap_behv_message=>severity-error
            text = 'Số lượng còn lại không khớp với sổ phân bổ' ) )
          TO reported-employeeallocation.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.

CLASS lhc_operationallocation IMPLEMENTATION.
  METHOD get_global_authorizations.
    "API mobile không expose raw CRUD. Các domain action tự xác thực CASLA token
    "khi request xuất phát từ mobile; projection mobile chỉ expose các static
    "facade action có kiểm soát.
    result-%create = if_abap_behv=>auth-unauthorized.
    result-%update = if_abap_behv=>auth-unauthorized.
    result-%action-initialAssign = if_abap_behv=>auth-allowed.
    result-%action-transfer = if_abap_behv=>auth-allowed.
    result-%action-recall = if_abap_behv=>auth-allowed.
    result-%action-confirm = if_abap_behv=>auth-allowed.
    result-%action-reverse = if_abap_behv=>auth-allowed.
    result-%action-correctConfirm = if_abap_behv=>auth-allowed.
    result-%action-submitInitialAssign = if_abap_behv=>auth-allowed.
    result-%action-submitTransfer = if_abap_behv=>auth-allowed.
    result-%action-submitRecall = if_abap_behv=>auth-allowed.
    result-%action-submitConfirm = if_abap_behv=>auth-allowed.
    result-%action-submitReverse = if_abap_behv=>auth-allowed.
    result-%action-getSyncStatus = if_abap_behv=>auth-allowed.
    result-%action-getWorkHistory = if_abap_behv=>auth-allowed.
  ENDMETHOD.

  METHOD validateOperation.
    READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
      ENTITY OperationAllocation
      FIELDS ( ProductionOrder Operation MaCongDoan OperationQuantity
               UnitOfMeasure Plant WorkCenter )
      WITH CORRESPONDING #( keys )
      RESULT DATA(operations).

    LOOP AT operations ASSIGNING FIELD-SYMBOL(<operation>).
      IF <operation>-ProductionOrder IS INITIAL
         OR <operation>-Operation IS INITIAL
         OR <operation>-MaCongDoan IS INITIAL
         OR <operation>-OperationQuantity <= 0
         OR <operation>-UnitOfMeasure IS INITIAL
         OR <operation>-Plant IS INITIAL
         OR <operation>-WorkCenter IS INITIAL.
        APPEND VALUE #( %tky = <operation>-%tky ) TO failed-operationallocation.
        APPEND VALUE #(
          %tky = <operation>-%tky
          %msg = new_message_with_text(
            severity = if_abap_behv_message=>severity-error
            text = 'Dữ liệu snapshot công đoạn không đầy đủ' ) )
          TO reported-operationallocation.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD ensure_operation.
    DATA(live) = zcl_pp_operation_guard=>resolve(
      production_order = production_order
      operation_no = operation_no ).
    IF live-is_valid = abap_false.
      value-error_code = live-error_code.
      RETURN.
    ENDIF.

    SELECT FROM ztb_pp_op_alloc
      FIELDS operation_uuid, production_order, operation_no, ma_congdoan,
             plant, work_center, operation_qty, uom
      WHERE production_order = @production_order
        AND operation_no = @operation_no
      INTO TABLE @DATA(existing)
      UP TO 2 ROWS.

    IF lines( existing ) > 1.
      value-error_code = 'OPERATION_SNAPSHOT_DUPLICATE'.
      RETURN.
    ENDIF.

    IF existing IS INITIAL.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation CREATE FIELDS
          ( ProductionOrder Operation MaCongDoan Plant WorkCenter
            OperationQuantity UnitOfMeasure OperationStatus )
        WITH VALUE #( ( %cid = 'OP'
          ProductionOrder = live-production_order
          Operation = live-operation_no
          MaCongDoan = live-ma_congdoan
          Plant = live-plant
          WorkCenter = live-work_center
          OperationQuantity = live-operation_qty
          UnitOfMeasure = live-uom
          OperationStatus = 'REL' ) )
        MAPPED DATA(mapped)
        FAILED DATA(create_failed).
      IF create_failed-operationallocation IS NOT INITIAL
         OR mapped-operationallocation IS INITIAL.
        value-error_code = 'OPERATION_SNAPSHOT_CREATE_FAILED'.
        RETURN.
      ENDIF.
      value-operation_uuid = mapped-operationallocation[ 1 ]-OperationUUID.
    ELSE.
      DATA(snapshot) = existing[ 1 ].
      value-operation_uuid = snapshot-operation_uuid.
      IF snapshot-ma_congdoan <> live-ma_congdoan
         OR snapshot-plant <> live-plant
         OR snapshot-work_center <> live-work_center
         OR snapshot-operation_qty <> live-operation_qty
         OR snapshot-uom <> live-uom.
        MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY OperationAllocation UPDATE FIELDS
            ( MaCongDoan Plant WorkCenter OperationQuantity UnitOfMeasure
              OperationStatus )
          WITH VALUE #( ( OperationUUID = snapshot-operation_uuid
            MaCongDoan = live-ma_congdoan
            Plant = live-plant
            WorkCenter = live-work_center
            OperationQuantity = live-operation_qty
            UnitOfMeasure = live-uom
            OperationStatus = 'REL' ) )
          FAILED DATA(update_failed).
        IF update_failed-operationallocation IS NOT INITIAL.
          value-error_code = 'OPERATION_SNAPSHOT_UPDATE_FAILED'.
          RETURN.
        ENDIF.
      ENDIF.
    ENDIF.

    value-is_valid = abap_true.
    value-production_order = live-production_order.
    value-operation_no = live-operation_no.
    value-ma_congdoan = live-ma_congdoan.
    value-plant = live-plant.
    value-work_center = live-work_center.
    value-operation_qty = live-operation_qty.
    value-uom = live-uom.
  ENDMETHOD.

  METHOD initialAssign.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken )
            device_id = input-DeviceID
            required_func = 'PP_INITIAL_ASSIGN' ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'Không thể xác thực yêu cầu'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = CONV string( auth-error_code )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-Quantity <= 0
         OR input-ToWorkerID IS INITIAL OR input-SyncItemUUID IS INITIAL
         OR input-ExecutionDate IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'Thiếu dữ liệu giao việc bắt buộc'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      IF zcl_mob_token_validator=>has_work_scope(
           user_uuid = auth-user_uuid plant = operation-Plant
           work_center = operation-WorkCenter ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORK_CONTEXT_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF input-UnitOfMeasure <> operation-UnitOfMeasure.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'UNIT_OF_MEASURE_MISMATCH'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF zcl_pp_worker_validator=>is_worker_active(
           worker_id = input-ToWorkerID plant = operation-Plant
           work_center = operation-WorkCenter
           execution_date = input-ExecutionDate ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      TRY.
          DATA(worker_auth) = zcl_mob_token_validator=>verify_worker_password(
            worker_id = input-ToWorkerID
            password = CONV string( input-WorkerPassword ) ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'WORKER_AUTH_FAILED'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF worker_auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_AUTH_FAILED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, operation_uuid, transaction_type,
               to_worker_id, quantity, uom, execution_date
        WHERE sync_item_uuid = @input-SyncItemUUID
        INTO TABLE @DATA(existing_txns)
        UP TO 2 ROWS.
      IF lines( existing_txns ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SYNC_RECEIPT_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF existing_txns IS NOT INITIAL.
        DATA(existing_txn) = existing_txns[ 1 ].
        IF existing_txn-operation_uuid = operation-OperationUUID
           AND existing_txn-transaction_type = zcl_pp_txn_type=>initial_assign
           AND existing_txn-to_worker_id = input-ToWorkerID
           AND existing_txn-quantity = input-Quantity
           AND existing_txn-uom = input-UnitOfMeasure
           AND existing_txn-execution_date = input-ExecutionDate.
          APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        ELSE.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'IDEMPOTENCY_KEY_REUSED'
            CHANGING failed = failed reported = reported ).
        ENDIF.
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_emp_alloc
        FIELDS SUM( remaining_qty ) AS remaining,
               SUM( completed_qty ) AS completed
        WHERE operation_uuid = @operation-OperationUUID
        INTO @DATA(operation_balance).
      IF operation_balance-remaining + operation_balance-completed + input-Quantity
         > operation-OperationQuantity.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'OPERATION_QUANTITY_EXCEEDED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, initial_assigned_qty, remaining_qty
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id = @input-ToWorkerID
        INTO TABLE @DATA(worker_balances)
        UP TO 2 ROWS.
      IF lines( worker_balances ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_BALANCE_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(balance) = VALUE #( worker_balances[ 1 ] OPTIONAL ).
      IF balance IS INITIAL.
        MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY OperationAllocation CREATE BY \_Employees FIELDS
            ( WorkerID InitialAssignedQuantity RemainingQuantity UnitOfMeasure
              LastExecutionDate )
          WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
            ( %cid = |EMP{ sy-tabix }| WorkerID = input-ToWorkerID
              InitialAssignedQuantity = input-Quantity
              RemainingQuantity = input-Quantity
              UnitOfMeasure = input-UnitOfMeasure
              LastExecutionDate = input-ExecutionDate ) ) ) ).
      ELSE.
        MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY EmployeeAllocation UPDATE FIELDS
            ( InitialAssignedQuantity RemainingQuantity LastExecutionDate )
          WITH VALUE #( ( EmployeeAllocationUUID = balance-emp_alloc_uuid
            InitialAssignedQuantity = balance-initial_assigned_qty + input-Quantity
            RemainingQuantity = balance-remaining_qty + input-Quantity
            LastExecutionDate = input-ExecutionDate ) ).
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( SyncItemUUID ActorUserUUID VerifiedWorkerUserUUID WorkerVerifiedAt
            InitiatorSessionID DeviceID VerificationMethod TransactionType
            WorkerID ToWorkerID Quantity UnitOfMeasure ExecutionDate
            TransactionStatus SourceChannel )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |TXN{ sy-tabix }| SyncItemUUID = input-SyncItemUUID
            ActorUserUUID = auth-user_uuid
            VerifiedWorkerUserUUID = worker_auth-worker_user_uuid
            WorkerVerifiedAt = utclong_current( )
            InitiatorSessionID = auth-session_id DeviceID = input-DeviceID
            VerificationMethod = 'PASSWORD'
            TransactionType = zcl_pp_txn_type=>initial_assign
            WorkerID = input-ToWorkerID ToWorkerID = input-ToWorkerID
            Quantity = input-Quantity UnitOfMeasure = input-UnitOfMeasure
            ExecutionDate = input-ExecutionDate
            TransactionStatus = zcl_pp_txn_type=>posted
            SourceChannel = zcl_pp_txn_type=>source_mobile ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD transfer.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'Không thể xác thực yêu cầu điều chuyển'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = CONV string( auth-error_code )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-Quantity <= 0
         OR input-FromWorkerID IS INITIAL OR input-ToWorkerID IS INITIAL
         OR input-FromWorkerID = input-ToWorkerID OR input-SyncItemUUID IS INITIAL
         OR input-ExecutionDate IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'Thiếu hoặc sai dữ liệu điều chuyển'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      IF zcl_mob_token_validator=>has_work_scope(
           user_uuid = auth-user_uuid plant = operation-Plant
           work_center = operation-WorkCenter ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORK_CONTEXT_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      TRY.
          DATA(worker_auth) = zcl_mob_token_validator=>verify_worker_password(
            worker_id = input-ToWorkerID password = CONV string( input-WorkerPassword ) ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'WORKER_AUTH_FAILED'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF worker_auth-is_valid = abap_false OR input-UnitOfMeasure <> operation-UnitOfMeasure
         OR zcl_pp_worker_validator=>is_worker_active(
           worker_id = input-ToWorkerID plant = operation-Plant
           work_center = operation-WorkCenter
           execution_date = input-ExecutionDate ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_AUTH_FAILED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, operation_uuid, transaction_type,
               from_worker_id, to_worker_id, quantity, uom, execution_date
        WHERE sync_item_uuid = @input-SyncItemUUID
        INTO TABLE @DATA(existing_txns) UP TO 2 ROWS.
      IF lines( existing_txns ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SYNC_RECEIPT_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF existing_txns IS NOT INITIAL.
        DATA(existing_txn) = existing_txns[ 1 ].
        IF existing_txn-operation_uuid = operation-OperationUUID
           AND existing_txn-transaction_type = zcl_pp_txn_type=>transfer
           AND existing_txn-from_worker_id = input-FromWorkerID
           AND existing_txn-to_worker_id = input-ToWorkerID
           AND existing_txn-quantity = input-Quantity
           AND existing_txn-uom = input-UnitOfMeasure
           AND existing_txn-execution_date = input-ExecutionDate.
          APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        ELSE.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'IDEMPOTENCY_KEY_REUSED'
            CHANGING failed = failed reported = reported ).
        ENDIF.
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, worker_id, transferred_in_qty,
               transferred_out_qty, remaining_qty, uom
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id IN ( @input-FromWorkerID, @input-ToWorkerID )
        INTO TABLE @DATA(balances).
      DATA(source) = VALUE #( balances[ worker_id = input-FromWorkerID ] OPTIONAL ).
      DATA(target) = VALUE #( balances[ worker_id = input-ToWorkerID ] OPTIONAL ).
      IF source IS INITIAL OR source-uom <> input-UnitOfMeasure
         OR source-remaining_qty < input-Quantity.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SOURCE_BALANCE_INSUFFICIENT'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY EmployeeAllocation UPDATE FIELDS
          ( TransferredOutQuantity RemainingQuantity LastExecutionDate )
        WITH VALUE #( ( EmployeeAllocationUUID = source-emp_alloc_uuid
          TransferredOutQuantity = source-transferred_out_qty + input-Quantity
          RemainingQuantity = source-remaining_qty - input-Quantity
          LastExecutionDate = input-ExecutionDate ) ).
      IF target IS INITIAL.
        MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY OperationAllocation CREATE BY \_Employees FIELDS
            ( WorkerID TransferredInQuantity RemainingQuantity UnitOfMeasure LastExecutionDate )
          WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
            ( %cid = |TRG{ sy-tabix }| WorkerID = input-ToWorkerID
              TransferredInQuantity = input-Quantity RemainingQuantity = input-Quantity
              UnitOfMeasure = input-UnitOfMeasure LastExecutionDate = input-ExecutionDate ) ) ) ).
      ELSE.
        MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY EmployeeAllocation UPDATE FIELDS
            ( TransferredInQuantity RemainingQuantity LastExecutionDate )
          WITH VALUE #( ( EmployeeAllocationUUID = target-emp_alloc_uuid
            TransferredInQuantity = target-transferred_in_qty + input-Quantity
            RemainingQuantity = target-remaining_qty + input-Quantity
            LastExecutionDate = input-ExecutionDate ) ).
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( SyncItemUUID ActorUserUUID VerifiedWorkerUserUUID WorkerVerifiedAt
            InitiatorSessionID DeviceID VerificationMethod TransactionType
            FromWorkerID ToWorkerID Quantity UnitOfMeasure ExecutionDate
            TransactionStatus SourceChannel )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |TRN{ sy-tabix }| SyncItemUUID = input-SyncItemUUID
            ActorUserUUID = auth-user_uuid
            VerifiedWorkerUserUUID = worker_auth-worker_user_uuid
            WorkerVerifiedAt = utclong_current( ) InitiatorSessionID = auth-session_id
            DeviceID = input-DeviceID VerificationMethod = 'PASSWORD'
            TransactionType = zcl_pp_txn_type=>transfer
            FromWorkerID = input-FromWorkerID ToWorkerID = input-ToWorkerID
            Quantity = input-Quantity UnitOfMeasure = input-UnitOfMeasure
            ExecutionDate = input-ExecutionDate TransactionStatus = zcl_pp_txn_type=>posted
            SourceChannel = zcl_pp_txn_type=>source_mobile ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD recall.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'Không thể xác thực yêu cầu thu hồi'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = CONV string( auth-error_code )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-Quantity <= 0 OR input-WorkerID IS INITIAL
         OR input-SyncItemUUID IS INITIAL OR input-OriginalTransactionUUID IS INITIAL
         OR input-ExecutionDate IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'Thiếu dữ liệu thu hồi bắt buộc'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      IF zcl_mob_token_validator=>has_work_scope(
           user_uuid = auth-user_uuid plant = operation-Plant
           work_center = operation-WorkCenter ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORK_CONTEXT_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      TRY.
          DATA(worker_auth) = zcl_mob_token_validator=>verify_worker_password(
            worker_id = input-WorkerID password = CONV string( input-WorkerPassword ) ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'WORKER_AUTH_FAILED'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF worker_auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_AUTH_FAILED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, operation_uuid, original_transaction_uuid,
               transaction_type, worker_id, quantity, uom, execution_date
        WHERE sync_item_uuid = @input-SyncItemUUID
        INTO TABLE @DATA(existing_txns) UP TO 2 ROWS.
      IF lines( existing_txns ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SYNC_RECEIPT_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF existing_txns IS NOT INITIAL.
        DATA(existing_txn) = existing_txns[ 1 ].
        IF existing_txn-operation_uuid = operation-OperationUUID
           AND existing_txn-original_transaction_uuid = input-OriginalTransactionUUID
           AND existing_txn-transaction_type = zcl_pp_txn_type=>recall
           AND existing_txn-worker_id = input-WorkerID
           AND existing_txn-quantity = input-Quantity
           AND existing_txn-uom = input-UnitOfMeasure
           AND existing_txn-execution_date = input-ExecutionDate.
          APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        ELSE.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'IDEMPOTENCY_KEY_REUSED'
            CHANGING failed = failed reported = reported ).
        ENDIF.
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_type
        WHERE transaction_uuid = @input-OriginalTransactionUUID
          AND operation_uuid = @operation-OperationUUID
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(root_transactions) UP TO 1 ROWS.
      DATA(root_type) = VALUE #( root_transactions[ 1 ]-transaction_type OPTIONAL ).
      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, recalled_qty, remaining_qty, uom
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id = @input-WorkerID
        INTO TABLE @DATA(worker_balances) UP TO 2 ROWS.
      IF lines( worker_balances ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_BALANCE_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(balance) = VALUE #( worker_balances[ 1 ] OPTIONAL ).
      IF ( root_type <> zcl_pp_txn_type=>initial_assign
           AND root_type <> zcl_pp_txn_type=>transfer )
         OR balance IS INITIAL OR balance-uom <> input-UnitOfMeasure
         OR balance-remaining_qty < input-Quantity.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'RECALL_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY EmployeeAllocation UPDATE FIELDS
          ( RecalledQuantity RemainingQuantity LastExecutionDate )
        WITH VALUE #( ( EmployeeAllocationUUID = balance-emp_alloc_uuid
          RecalledQuantity = balance-recalled_qty + input-Quantity
          RemainingQuantity = balance-remaining_qty - input-Quantity
          LastExecutionDate = input-ExecutionDate ) )
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( OriginalTransactionUUID OriginalTransactionType SyncItemUUID ActorUserUUID
            VerifiedWorkerUserUUID WorkerVerifiedAt InitiatorSessionID DeviceID
            VerificationMethod TransactionType WorkerID FromWorkerID Quantity
            UnitOfMeasure ExecutionDate TransactionStatus SourceChannel )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |RCL{ sy-tabix }| OriginalTransactionUUID = input-OriginalTransactionUUID
            OriginalTransactionType = root_type SyncItemUUID = input-SyncItemUUID
            ActorUserUUID = auth-user_uuid
            VerifiedWorkerUserUUID = worker_auth-worker_user_uuid
            WorkerVerifiedAt = utclong_current( ) InitiatorSessionID = auth-session_id
            DeviceID = input-DeviceID VerificationMethod = 'PASSWORD'
            TransactionType = zcl_pp_txn_type=>recall WorkerID = input-WorkerID
            FromWorkerID = input-WorkerID Quantity = input-Quantity
            UnitOfMeasure = input-UnitOfMeasure ExecutionDate = input-ExecutionDate
            TransactionStatus = zcl_pp_txn_type=>posted
            SourceChannel = zcl_pp_txn_type=>source_mobile ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD confirm.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'Không thể xác thực yêu cầu xác nhận'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = CONV string( auth-error_code )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-Quantity <= 0 OR input-WorkerID IS INITIAL
         OR input-ExecutionDate IS INITIAL OR input-SyncItemUUID IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CONFIRM_INPUT_INVALID'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      IF zcl_mob_token_validator=>has_work_scope(
           user_uuid = auth-user_uuid plant = operation-Plant
           work_center = operation-WorkCenter ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORK_CONTEXT_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF input-UnitOfMeasure <> operation-UnitOfMeasure.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'UNIT_OF_MEASURE_MISMATCH'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF zcl_pp_worker_validator=>is_worker_active(
           worker_id = input-WorkerID plant = operation-Plant
           work_center = operation-WorkCenter execution_date = input-ExecutionDate ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      TRY.
          DATA(worker_auth) = zcl_mob_token_validator=>verify_worker_password(
            worker_id = input-WorkerID password = CONV string( input-WorkerPassword ) ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'WORKER_AUTH_FAILED'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF worker_auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_AUTH_FAILED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, operation_uuid, transaction_type,
               original_transaction_uuid, worker_id, quantity, uom, execution_date
        WHERE sync_item_uuid = @input-SyncItemUUID
        INTO TABLE @DATA(existing_txns) UP TO 2 ROWS.
      IF lines( existing_txns ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SYNC_RECEIPT_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF existing_txns IS NOT INITIAL.
        DATA(existing_txn) = existing_txns[ 1 ].
        IF existing_txn-operation_uuid = operation-OperationUUID
           AND existing_txn-transaction_type = zcl_pp_txn_type=>confirm
           AND existing_txn-worker_id = input-WorkerID
           AND existing_txn-quantity = input-Quantity
           AND existing_txn-uom = input-UnitOfMeasure
           AND existing_txn-execution_date = input-ExecutionDate
           AND existing_txn-original_transaction_uuid = input-OriginalTransactionUUID.
          APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        ELSE.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'IDEMPOTENCY_KEY_REUSED'
            CHANGING failed = failed reported = reported ).
        ENDIF.
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, completed_qty, remaining_qty, uom
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id = @input-WorkerID
        INTO TABLE @DATA(worker_balances) UP TO 2 ROWS.
      IF lines( worker_balances ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_BALANCE_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(balance) = VALUE #( worker_balances[ 1 ] OPTIONAL ).
      IF balance IS INITIAL OR balance-uom <> input-UnitOfMeasure
         OR balance-remaining_qty < input-Quantity.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CONFIRM_QUANTITY_EXCEEDED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      DATA original_type TYPE ztb_pp_alloc_txn-transaction_type.
      IF input-OriginalTransactionUUID IS NOT INITIAL.
        READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
          ENTITY AllocationTransaction
            FIELDS ( OperationUUID TransactionType TransactionStatus )
            WITH VALUE #(
              ( %key-TransactionUUID = input-OriginalTransactionUUID ) )
            RESULT DATA(original_transactions).
        DATA(original_transaction) = VALUE #( original_transactions[ 1 ] OPTIONAL ).
        IF original_transaction IS INITIAL
           OR original_transaction-OperationUUID <> operation-OperationUUID
           OR original_transaction-TransactionStatus <> zcl_pp_txn_type=>posted.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'ORIGINAL_TRANSACTION_NOT_FOUND'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
        ENDIF.
        original_type = original_transaction-TransactionType.
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY EmployeeAllocation UPDATE FIELDS
          ( CompletedQuantity RemainingQuantity LastExecutionDate LastSyncAt )
        WITH VALUE #( ( EmployeeAllocationUUID = balance-emp_alloc_uuid
          CompletedQuantity = balance-completed_qty + input-Quantity
          RemainingQuantity = balance-remaining_qty - input-Quantity
          LastExecutionDate = input-ExecutionDate LastSyncAt = utclong_current( ) ) )
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( OriginalTransactionUUID OriginalTransactionType SyncItemUUID ActorUserUUID
            VerifiedWorkerUserUUID WorkerVerifiedAt InitiatorSessionID DeviceID
            VerificationMethod TransactionType WorkerID Quantity UnitOfMeasure
            ExecutionDate TransactionStatus SourceChannel )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |CFM{ sy-tabix }| OriginalTransactionUUID = input-OriginalTransactionUUID
            OriginalTransactionType = original_type SyncItemUUID = input-SyncItemUUID
            ActorUserUUID = auth-user_uuid
            VerifiedWorkerUserUUID = worker_auth-worker_user_uuid
            WorkerVerifiedAt = utclong_current( ) InitiatorSessionID = auth-session_id
            DeviceID = input-DeviceID VerificationMethod = 'PASSWORD'
            TransactionType = zcl_pp_txn_type=>confirm WorkerID = input-WorkerID
            Quantity = input-Quantity UnitOfMeasure = input-UnitOfMeasure
            ExecutionDate = input-ExecutionDate TransactionStatus = zcl_pp_txn_type=>posted
            SourceChannel = zcl_pp_txn_type=>source_mobile ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD reverse.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'Không thể xác thực yêu cầu đảo xác nhận'
            CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = CONV string( auth-error_code )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-TransactionUUID IS INITIAL
         OR input-SyncItemUUID IS INITIAL OR input-Reason IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'REVERSE_INPUT_INVALID'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      IF zcl_mob_token_validator=>has_work_scope(
           user_uuid = auth-user_uuid plant = operation-Plant
           work_center = operation-WorkCenter ) = abap_false.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORK_CONTEXT_NOT_ALLOWED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, operation_uuid, original_transaction_uuid,
               transaction_type, reason_text
        WHERE sync_item_uuid = @input-SyncItemUUID
        INTO TABLE @DATA(existing_receipts) UP TO 2 ROWS.
      IF lines( existing_receipts ) > 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'SYNC_RECEIPT_DUPLICATE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF existing_receipts IS NOT INITIAL.
        DATA(existing_receipt) = existing_receipts[ 1 ].
        IF existing_receipt-operation_uuid = operation-OperationUUID
           AND existing_receipt-transaction_type = zcl_pp_txn_type=>reverse
           AND existing_receipt-original_transaction_uuid = input-TransactionUUID.
          APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        ELSE.
          report_instance_failure(
            EXPORTING operation_uuid = <key>-%tky-OperationUUID
                      text = 'IDEMPOTENCY_KEY_REUSED'
            CHANGING failed = failed reported = reported ).
        ENDIF.
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, worker_id, quantity, uom, execution_date
        WHERE transaction_uuid = @input-TransactionUUID
          AND operation_uuid = @operation-OperationUUID
          AND transaction_type = @zcl_pp_txn_type=>confirm
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(originals) UP TO 2 ROWS.
      IF lines( originals ) <> 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CONFIRM_TRANSACTION_NOT_FOUND'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(original) = originals[ 1 ].

      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid
        WHERE original_transaction_uuid = @input-TransactionUUID
          AND transaction_type = @zcl_pp_txn_type=>reverse
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(reversals) UP TO 1 ROWS.
      IF reversals IS NOT INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'TRANSACTION_ALREADY_REVERSED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn
        FIELDS SUM( quantity ) AS correction_qty
        WHERE original_transaction_uuid = @input-TransactionUUID
          AND transaction_type = @zcl_pp_txn_type=>correction
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO @DATA(corrections).
      DATA effective_qty TYPE ztb_pp_alloc_txn-quantity.
      effective_qty = original-quantity + corrections.
      IF effective_qty <= 0.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'NOTHING_TO_REVERSE'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, completed_qty, remaining_qty, uom
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id = @original-worker_id
        INTO TABLE @DATA(worker_balances) UP TO 2 ROWS.
      IF lines( worker_balances ) <> 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_BALANCE_NOT_FOUND'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(balance) = worker_balances[ 1 ].
      IF balance-uom <> original-uom OR balance-completed_qty < effective_qty.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'REVERSE_BALANCE_INCONSISTENT'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY EmployeeAllocation UPDATE FIELDS
          ( CompletedQuantity RemainingQuantity LastExecutionDate LastSyncAt )
        WITH VALUE #( ( EmployeeAllocationUUID = balance-emp_alloc_uuid
          CompletedQuantity = balance-completed_qty - effective_qty
          RemainingQuantity = balance-remaining_qty + effective_qty
          LastExecutionDate = cl_abap_context_info=>get_system_date( )
          LastSyncAt = utclong_current( ) ) )
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( OriginalTransactionUUID OriginalTransactionType SyncItemUUID ActorUserUUID
            InitiatorSessionID DeviceID VerificationMethod TransactionType WorkerID
            Quantity UnitOfMeasure ExecutionDate TransactionStatus ReasonCode ReasonText
            SourceChannel ReversalReason )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |REV{ sy-tabix }| OriginalTransactionUUID = input-TransactionUUID
            OriginalTransactionType = zcl_pp_txn_type=>confirm
            SyncItemUUID = input-SyncItemUUID ActorUserUUID = auth-user_uuid
            InitiatorSessionID = auth-session_id DeviceID = input-DeviceID
            VerificationMethod = 'SESSION'
            TransactionType = zcl_pp_txn_type=>reverse WorkerID = original-worker_id
            Quantity = effective_qty UnitOfMeasure = original-uom
            ExecutionDate = cl_abap_context_info=>get_system_date( )
            TransactionStatus = zcl_pp_txn_type=>posted ReasonCode = 'USER_REVERSAL'
            ReasonText = input-Reason ReversalReason = input-Reason
            SourceChannel = zcl_pp_txn_type=>source_mobile ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD correctConfirm.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation ALL FIELDS
        WITH VALUE #( ( %tky = <key>-%tky ) ) RESULT DATA(operations).
      IF operations IS INITIAL OR input-TransactionUUID IS INITIAL
         OR input-NewQuantity < 0 OR input-ReasonCode IS INITIAL
         OR input-ReasonText IS INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CORRECTION_INPUT_INVALID'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(operation) = operations[ 1 ].
      SELECT FROM ztb_pp_alloc_txn
        FIELDS transaction_uuid, worker_id, quantity, uom
        WHERE transaction_uuid = @input-TransactionUUID
          AND operation_uuid = @operation-OperationUUID
          AND transaction_type = @zcl_pp_txn_type=>confirm
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(originals) UP TO 2 ROWS.
      IF lines( originals ) <> 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CONFIRM_TRANSACTION_NOT_FOUND'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(original) = originals[ 1 ].
      IF input-UnitOfMeasure <> original-uom.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'UOM_MISMATCH'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      SELECT FROM ztb_pp_alloc_txn FIELDS transaction_uuid
        WHERE original_transaction_uuid = @input-TransactionUUID
          AND transaction_type = @zcl_pp_txn_type=>reverse
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(reversals) UP TO 1 ROWS.
      IF reversals IS NOT INITIAL.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'TRANSACTION_ALREADY_REVERSED'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      SELECT FROM ztb_pp_alloc_txn FIELDS SUM( quantity ) AS correction_qty
        WHERE original_transaction_uuid = @input-TransactionUUID
          AND transaction_type = @zcl_pp_txn_type=>correction
          AND transaction_status = @zcl_pp_txn_type=>posted
        INTO @DATA(corrections).
      DATA current_qty TYPE ztb_pp_alloc_txn-quantity.
      DATA delta TYPE ztb_pp_alloc_txn-quantity.
      current_qty = original-quantity + corrections.
      delta = input-NewQuantity - current_qty.
      IF delta = 0.
        APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
        CONTINUE.
      ENDIF.
      SELECT FROM ztb_pp_emp_alloc
        FIELDS emp_alloc_uuid, completed_qty, remaining_qty, uom
        WHERE operation_uuid = @operation-OperationUUID
          AND worker_id = @original-worker_id
        INTO TABLE @DATA(worker_balances) UP TO 2 ROWS.
      IF lines( worker_balances ) <> 1.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'WORKER_BALANCE_NOT_FOUND'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(balance) = worker_balances[ 1 ].
      IF balance-uom <> original-uom
         OR ( delta > 0 AND balance-remaining_qty < delta )
         OR balance-completed_qty + delta < 0.
        report_instance_failure(
          EXPORTING operation_uuid = <key>-%tky-OperationUUID
                    text = 'CORRECTION_BALANCE_INVALID'
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY EmployeeAllocation UPDATE FIELDS
          ( CompletedQuantity RemainingQuantity LastExecutionDate )
        WITH VALUE #( ( EmployeeAllocationUUID = balance-emp_alloc_uuid
          CompletedQuantity = balance-completed_qty + delta
          RemainingQuantity = balance-remaining_qty - delta
          LastExecutionDate = cl_abap_context_info=>get_system_date( ) ) )
        ENTITY OperationAllocation CREATE BY \_Transactions FIELDS
          ( OriginalTransactionUUID OriginalTransactionType TransactionType WorkerID
            Quantity UnitOfMeasure ExecutionDate TransactionStatus ReasonCode ReasonText
            SourceChannel VerificationMethod )
        WITH VALUE #( ( %tky = operation-%tky %target = VALUE #(
          ( %cid = |COR{ sy-tabix }| OriginalTransactionUUID = input-TransactionUUID
            OriginalTransactionType = zcl_pp_txn_type=>confirm
            TransactionType = zcl_pp_txn_type=>correction WorkerID = original-worker_id
            Quantity = delta UnitOfMeasure = original-uom
            ExecutionDate = cl_abap_context_info=>get_system_date( )
            TransactionStatus = zcl_pp_txn_type=>posted
            ReasonCode = input-ReasonCode ReasonText = input-ReasonText
            SourceChannel = zcl_pp_txn_type=>source_fiori
            VerificationMethod = 'IAM' ) ) ) ).
      APPEND VALUE #( %tky = operation-%tky %param = operation ) TO result.
    ENDLOOP.
  ENDMETHOD.

  METHOD submitInitialAssign.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( auth-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(context) = ensure_operation( production_order = input-ProductionOrder
                                        operation_no = input-Operation ).
      IF context-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( context-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation EXECUTE initialAssign
        FROM VALUE #( ( %tky = VALUE #( OperationUUID = context-operation_uuid )
                        %param = input ) )
        FAILED DATA(action_failed)
        REPORTED DATA(action_reported).
      IF action_failed-operationallocation IS NOT INITIAL.
        forward_action_failure(
          EXPORTING cid = cid
                    operation_uuid = context-operation_uuid
                    action_reported = action_reported
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation BY \_Transactions
          FIELDS ( TransactionUUID SyncItemUUID )
          WITH VALUE #( ( %key-OperationUUID = context-operation_uuid ) )
          RESULT DATA(receipt_rows).
      DATA(receipt_count) = 0.
      DATA txn_uuid TYPE ztb_pp_alloc_txn-transaction_uuid.
      LOOP AT receipt_rows ASSIGNING FIELD-SYMBOL(<receipt>)
        WHERE SyncItemUUID = input-SyncItemUUID.
        receipt_count = receipt_count + 1.
        txn_uuid = <receipt>-TransactionUUID.
        IF receipt_count > 1.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF receipt_count <> 1.
        report_failure( EXPORTING cid = cid
                          text = COND string(
                            WHEN receipt_count = 0 THEN 'SYNC_RECEIPT_NOT_FOUND'
                            ELSE 'SYNC_RECEIPT_DUPLICATE' )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID TransactionUUID = txn_uuid
        ProductionOrder = context-production_order Operation = context-operation_no
        MaCongDoan = context-ma_congdoan Message = 'Đã ghi nhận giao việc' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD submitTransfer.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( auth-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(context) = ensure_operation( production_order = input-ProductionOrder
                                        operation_no = input-Operation ).
      IF context-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( context-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation EXECUTE transfer
        FROM VALUE #( ( %tky = VALUE #( OperationUUID = context-operation_uuid ) %param = input ) )
        FAILED DATA(action_failed)
        REPORTED DATA(action_reported).
      IF action_failed-operationallocation IS NOT INITIAL.
        "Forward the instance action's own message (WORKER_AUTH_FAILED,
        "WORK_CONTEXT_NOT_ALLOWED, ...). Collapsing everything to
        "BUSINESS_VALIDATION_FAILED told the app this was a business
        "rejection, so a mistyped worker password was filed as FAILED
        "instead of reopening the password prompt.
        forward_action_failure(
          EXPORTING cid = cid
                    operation_uuid = context-operation_uuid
                    action_reported = action_reported
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation BY \_Transactions
          FIELDS ( TransactionUUID SyncItemUUID )
          WITH VALUE #( ( %key-OperationUUID = context-operation_uuid ) )
          RESULT DATA(receipt_rows).
      DATA(receipt_count) = 0.
      DATA txn_uuid TYPE ztb_pp_alloc_txn-transaction_uuid.
      LOOP AT receipt_rows ASSIGNING FIELD-SYMBOL(<receipt>)
        WHERE SyncItemUUID = input-SyncItemUUID.
        receipt_count = receipt_count + 1.
        txn_uuid = <receipt>-TransactionUUID.
        IF receipt_count > 1.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF receipt_count <> 1.
        report_failure( EXPORTING cid = cid
                          text = COND string(
                            WHEN receipt_count = 0 THEN 'SYNC_RECEIPT_NOT_FOUND'
                            ELSE 'SYNC_RECEIPT_DUPLICATE' )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID TransactionUUID = txn_uuid
        ProductionOrder = context-production_order Operation = context-operation_no
        MaCongDoan = context-ma_congdoan Message = 'Đã ghi nhận điều chuyển' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD submitRecall.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( auth-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(context) = ensure_operation( production_order = input-ProductionOrder
                                        operation_no = input-Operation ).
      IF context-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( context-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation EXECUTE recall
        FROM VALUE #( ( %tky = VALUE #( OperationUUID = context-operation_uuid ) %param = input ) )
        FAILED DATA(action_failed)
        REPORTED DATA(action_reported).
      IF action_failed-operationallocation IS NOT INITIAL.
        "Forward the instance action's own message (WORKER_AUTH_FAILED,
        "WORK_CONTEXT_NOT_ALLOWED, ...). Collapsing everything to
        "BUSINESS_VALIDATION_FAILED told the app this was a business
        "rejection, so a mistyped worker password was filed as FAILED
        "instead of reopening the password prompt.
        forward_action_failure(
          EXPORTING cid = cid
                    operation_uuid = context-operation_uuid
                    action_reported = action_reported
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation BY \_Transactions
          FIELDS ( TransactionUUID SyncItemUUID )
          WITH VALUE #( ( %key-OperationUUID = context-operation_uuid ) )
          RESULT DATA(receipt_rows).
      DATA(receipt_count) = 0.
      DATA txn_uuid TYPE ztb_pp_alloc_txn-transaction_uuid.
      LOOP AT receipt_rows ASSIGNING FIELD-SYMBOL(<receipt>)
        WHERE SyncItemUUID = input-SyncItemUUID.
        receipt_count = receipt_count + 1.
        txn_uuid = <receipt>-TransactionUUID.
        IF receipt_count > 1.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF receipt_count <> 1.
        report_failure( EXPORTING cid = cid
                          text = COND string(
                            WHEN receipt_count = 0 THEN 'SYNC_RECEIPT_NOT_FOUND'
                            ELSE 'SYNC_RECEIPT_DUPLICATE' )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID TransactionUUID = txn_uuid
        ProductionOrder = context-production_order Operation = context-operation_no
        MaCongDoan = context-ma_congdoan Message = 'Đã ghi nhận thu hồi' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD submitConfirm.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( auth-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(context) = ensure_operation( production_order = input-ProductionOrder
                                        operation_no = input-Operation ).
      IF context-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( context-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation EXECUTE confirm
        FROM VALUE #( ( %tky = VALUE #( OperationUUID = context-operation_uuid ) %param = input ) )
        FAILED DATA(action_failed)
        REPORTED DATA(action_reported).
      IF action_failed-operationallocation IS NOT INITIAL.
        forward_action_failure(
          EXPORTING cid = cid
                    operation_uuid = context-operation_uuid
                    action_reported = action_reported
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation BY \_Transactions
          FIELDS ( TransactionUUID SyncItemUUID )
          WITH VALUE #( ( %key-OperationUUID = context-operation_uuid ) )
          RESULT DATA(receipt_rows).
      DATA(receipt_count) = 0.
      DATA txn_uuid TYPE ztb_pp_alloc_txn-transaction_uuid.
      LOOP AT receipt_rows ASSIGNING FIELD-SYMBOL(<receipt>)
        WHERE SyncItemUUID = input-SyncItemUUID.
        receipt_count = receipt_count + 1.
        txn_uuid = <receipt>-TransactionUUID.
        IF receipt_count > 1.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF receipt_count <> 1.
        report_failure( EXPORTING cid = cid
                          text = COND string(
                            WHEN receipt_count = 0 THEN 'SYNC_RECEIPT_NOT_FOUND'
                            ELSE 'SYNC_RECEIPT_DUPLICATE' )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID TransactionUUID = txn_uuid
        ProductionOrder = context-production_order Operation = context-operation_no
        MaCongDoan = context-ma_congdoan Message = 'Đã ghi nhận sản lượng' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD submitReverse.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( auth-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      DATA(context) = ensure_operation( production_order = input-ProductionOrder
                                        operation_no = input-Operation ).
      IF context-is_valid = abap_false.
        report_failure( EXPORTING cid = cid text = CONV string( context-error_code )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      MODIFY ENTITIES OF zr_pp_opalloc IN LOCAL MODE ENTITY OperationAllocation EXECUTE reverse
        FROM VALUE #( ( %tky = VALUE #( OperationUUID = context-operation_uuid ) %param = input ) )
        FAILED DATA(action_failed)
        REPORTED DATA(action_reported).
      IF action_failed-operationallocation IS NOT INITIAL.
        "Forward the instance action's own message (WORKER_AUTH_FAILED,
        "WORK_CONTEXT_NOT_ALLOWED, ...). Collapsing everything to
        "BUSINESS_VALIDATION_FAILED told the app this was a business
        "rejection, so a mistyped worker password was filed as FAILED
        "instead of reopening the password prompt.
        forward_action_failure(
          EXPORTING cid = cid
                    operation_uuid = context-operation_uuid
                    action_reported = action_reported
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
        ENTITY OperationAllocation BY \_Transactions
          FIELDS ( TransactionUUID SyncItemUUID )
          WITH VALUE #( ( %key-OperationUUID = context-operation_uuid ) )
          RESULT DATA(receipt_rows).
      DATA(receipt_count) = 0.
      DATA txn_uuid TYPE ztb_pp_alloc_txn-transaction_uuid.
      LOOP AT receipt_rows ASSIGNING FIELD-SYMBOL(<receipt>)
        WHERE SyncItemUUID = input-SyncItemUUID.
        receipt_count = receipt_count + 1.
        txn_uuid = <receipt>-TransactionUUID.
        IF receipt_count > 1.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF receipt_count <> 1.
        report_failure( EXPORTING cid = cid
                          text = COND string(
                            WHEN receipt_count = 0 THEN 'SYNC_RECEIPT_NOT_FOUND'
                            ELSE 'SYNC_RECEIPT_DUPLICATE' )
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID TransactionUUID = txn_uuid
        ProductionOrder = context-production_order Operation = context-operation_no
        MaCongDoan = context-ma_congdoan Message = 'Đã đảo giao dịch xác nhận' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD getSyncStatus.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      DATA(input) = <key>-%param.
      DATA(cid) = <key>-%cid.
      TRY.
          DATA(auth) = zcl_mob_token_validator=>validate_token(
            token = CONV string( input-AccessToken ) device_id = input-DeviceID ).
        CATCH cx_abap_message_digest zcx_mob_config.
          report_failure( EXPORTING cid = cid text = 'AUTH_FAILED'
                          CHANGING failed = failed reported = reported ).
          CONTINUE.
      ENDTRY.
      IF auth-is_valid = abap_false OR input-SyncItemUUID IS INITIAL.
        report_failure( EXPORTING cid = cid
          text = COND string( WHEN auth-is_valid = abap_false
                              THEN CONV string( auth-error_code ) ELSE 'SYNC_ITEM_REQUIRED' )
          CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.

      SELECT FROM ztb_pp_alloc_txn AS txn
        INNER JOIN ztb_pp_op_alloc AS op ON op~operation_uuid = txn~operation_uuid
        FIELDS txn~transaction_uuid, txn~transaction_type, txn~worker_id,
               txn~quantity, txn~uom, txn~execution_date,
               op~production_order, op~operation_no
        WHERE txn~sync_item_uuid = @input-SyncItemUUID
          AND txn~actor_user_uuid = @auth-user_uuid
          AND txn~transaction_status = @zcl_pp_txn_type=>posted
        INTO TABLE @DATA(receipts) UP TO 2 ROWS.
      IF lines( receipts ) > 1.
        report_failure( EXPORTING cid = cid text = 'SYNC_RECEIPT_DUPLICATE'
                        CHANGING failed = failed reported = reported ).
        CONTINUE.
      ENDIF.
      IF receipts IS INITIAL.
        result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
          Status = 'NOT_FOUND' SyncItemUUID = input-SyncItemUUID
          Message = 'SAP chưa chứng minh request này đã được commit; không được coi là FAILED' ) ) ).
        CONTINUE.
      ENDIF.
      DATA(receipt) = receipts[ 1 ].
      result = VALUE #( BASE result ( %cid = cid %param = VALUE #(
        Status = 'SUCCESS' SyncItemUUID = input-SyncItemUUID
        TransactionUUID = receipt-transaction_uuid TransactionType = receipt-transaction_type
        ProductionOrder = receipt-production_order Operation = receipt-operation_no
        WorkerID = receipt-worker_id Quantity = receipt-quantity
        UnitOfMeasure = receipt-uom ExecutionDate = receipt-execution_date
        Message = 'Request đã được commit vào ledger CASLA' ) ) ).
    ENDLOOP.
  ENDMETHOD.

  METHOD report_instance_failure.
    APPEND VALUE #(
      %tky = VALUE #( OperationUUID = operation_uuid ) )
      TO failed-operationallocation.
    APPEND VALUE #(
      %tky = VALUE #( OperationUUID = operation_uuid )
      %msg = new_message_with_text(
        severity = if_abap_behv_message=>severity-error text = text ) )
      TO reported-operationallocation.
  ENDMETHOD.

  METHOD forward_action_failure.
    DATA(message_forwarded) = abap_false.

    "Map instance errors to the current static action request.
    "Do not copy the inner %tky into the outer response.
    LOOP AT action_reported-operationallocation ASSIGNING FIELD-SYMBOL(<message>).
      IF <message>-%tky-OperationUUID IS NOT INITIAL
         AND <message>-%tky-OperationUUID <> operation_uuid.
        CONTINUE.
      ENDIF.
      IF <message>-%msg IS NOT BOUND.
        CONTINUE.
      ENDIF.
      IF <message>-%msg->m_severity <> if_abap_behv_message=>severity-error.
        CONTINUE.
      ENDIF.
      APPEND VALUE #( %cid = cid %msg = <message>-%msg )
        TO reported-operationallocation.
      message_forwarded = abap_true.
    ENDLOOP.

    IF message_forwarded = abap_true.
      APPEND VALUE #( %cid = cid ) TO failed-operationallocation.
    ELSE.
      report_failure(
        EXPORTING cid = cid text = 'BUSINESS_VALIDATION_FAILED'
        CHANGING failed = failed reported = reported ).
    ENDIF.
  ENDMETHOD.

  METHOD report_failure.
    APPEND VALUE #( %cid = cid ) TO failed-operationallocation.
    APPEND VALUE #( %cid = cid
      %msg = new_message_with_text(
        severity = if_abap_behv_message=>severity-error text = text ) )
      TO reported-operationallocation.
  ENDMETHOD.

  METHOD getWorkHistory.
    IF keys IS INITIAL.
      RETURN.
    ENDIF.
    IF lines( keys ) > 1.
      LOOP AT keys ASSIGNING FIELD-SYMBOL(<history_key>).
        report_failure( EXPORTING cid = CONV string( <history_key>-%cid )
                          text = 'Mỗi yêu cầu chỉ được tra cứu một lần'
                        CHANGING failed = failed reported = reported ).
      ENDLOOP.
      RETURN.
    ENDIF.
    DATA(input) = VALUE #( keys[ 1 ]-%param OPTIONAL ).
    DATA(cid) = CONV string( keys[ 1 ]-%cid ).
    TRY.
        DATA(history) = zcl_pp_work_history=>read(
          access_token = CONV string( input-AccessToken ) device_id = input-DeviceID
          range_code = input-RangeCode date_from = input-DateFrom date_to = input-DateTo
          worker_id = input-WorkerID
          include_entries = xsdbool( input-SummaryOnly = abap_false ) ).
      CATCH cx_abap_message_digest zcx_mob_config INTO DATA(error).
        report_failure( EXPORTING cid = cid text = error->get_text( )
                        CHANGING failed = failed reported = reported ).
        RETURN.
    ENDTRY.
    IF history-is_valid = abap_false.
      report_failure( EXPORTING cid = cid text = |Không tra cứu được: { history-error_code }|
                      CHANGING failed = failed reported = reported ).
      RETURN.
    ENDIF.
    result = VALUE #( ( %cid = cid %param = VALUE #(
      ScopeCode = history-scope_code DateFrom = history-date_from DateTo = history-date_to
      WorkerCount = history-worker_count EntryCount = history-entry_count
      IsTruncated = history-is_truncated
      _Workers = VALUE #( FOR summary IN history-workers
        ( WorkerID = summary-worker_id WorkerName = summary-worker_name
          AssignedQuantity = summary-assigned CompletedQuantity = summary-completed
          RemainingQuantity = summary-remaining UnitOfMeasure = summary-uom
          TransactionCount = summary-txn_count ) )
      _Entries = VALUE #( FOR entry IN history-entries
        ( TransactionUUID = entry-transaction_uuid ExecutionDate = entry-execution_date
          WorkerID = entry-worker_id WorkerName = entry-worker_name
          ProductionOrder = entry-production_order Operation = entry-operation_no
          Plant = entry-plant WorkCenter = entry-work_center
          TransactionType = entry-transaction_type Quantity = entry-quantity
          UnitOfMeasure = entry-uom TransactionStatus = entry-transaction_status ) ) ) ) ).
  ENDMETHOD.
ENDCLASS.
