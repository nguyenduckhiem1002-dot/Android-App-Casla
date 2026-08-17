CLASS lhc_operationallocation DEFINITION
  INHERITING FROM cl_abap_behavior_handler.

  PRIVATE SECTION.
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

    METHODS confirm FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~confirm
      RESULT result.

    METHODS reverse FOR MODIFY
      IMPORTING keys FOR ACTION OperationAllocation~reverse
      RESULT result.
ENDCLASS.

CLASS lhc_operationallocation IMPLEMENTATION.
  METHOD get_global_authorizations.
    result-%create = if_abap_behv=>auth-allowed.
    result-%update = if_abap_behv=>auth-allowed.
    result-%action-initialAssign = if_abap_behv=>auth-allowed.
    result-%action-transfer = if_abap_behv=>auth-allowed.
    result-%action-confirm = if_abap_behv=>auth-allowed.
    result-%action-reverse = if_abap_behv=>auth-allowed.
  ENDMETHOD.

  METHOD validateOperation.
    READ ENTITIES OF zr_pp_opalloc IN LOCAL MODE
      ENTITY OperationAllocation
      FIELDS ( OperationQuantity UnitOfMeasure Plant WorkCenter )
      WITH CORRESPONDING #( keys )
      RESULT DATA(operations).

    LOOP AT operations ASSIGNING FIELD-SYMBOL(<operation>).
      IF <operation>-OperationQuantity <= 0.
        APPEND VALUE #( %tky = <operation>-%tky )
          TO failed-operationallocation.
        APPEND VALUE #(
          %tky = <operation>-%tky
          %element-OperationQuantity = if_abap_behv=>mk-on
          %msg = new_message_with_text(
            severity = if_abap_behv_message=>severity-error
            text = 'Operation quantity must be greater than zero' ) )
          TO reported-operationallocation.
      ENDIF.

      IF <operation>-UnitOfMeasure IS INITIAL
         OR <operation>-Plant IS INITIAL
         OR <operation>-WorkCenter IS INITIAL.
        APPEND VALUE #( %tky = <operation>-%tky )
          TO failed-operationallocation.
        APPEND VALUE #(
          %tky = <operation>-%tky
          %msg = new_message_with_text(
            severity = if_abap_behv_message=>severity-error
            text = 'Plant, work center and unit are mandatory' ) )
          TO reported-operationallocation.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD initialAssign.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      APPEND VALUE #( %tky = <key>-%tky )
        TO failed-operationallocation.
      APPEND VALUE #(
        %tky = <key>-%tky
        %msg = new_message_with_text(
          severity = if_abap_behv_message=>severity-error
          text = 'INITIAL_ASSIGNMENT implementation is not activated yet' ) )
        TO reported-operationallocation.
    ENDLOOP.
  ENDMETHOD.

  METHOD transfer.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      APPEND VALUE #( %tky = <key>-%tky )
        TO failed-operationallocation.
      APPEND VALUE #(
        %tky = <key>-%tky
        %msg = new_message_with_text(
          severity = if_abap_behv_message=>severity-error
          text = 'TRANSFER implementation is not activated yet' ) )
        TO reported-operationallocation.
    ENDLOOP.
  ENDMETHOD.

  METHOD confirm.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      APPEND VALUE #( %tky = <key>-%tky )
        TO failed-operationallocation.
      APPEND VALUE #(
        %tky = <key>-%tky
        %msg = new_message_with_text(
          severity = if_abap_behv_message=>severity-error
          text = 'SAP production confirmation adapter is not configured' ) )
        TO reported-operationallocation.
    ENDLOOP.
  ENDMETHOD.

  METHOD reverse.
    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      APPEND VALUE #( %tky = <key>-%tky )
        TO failed-operationallocation.
      APPEND VALUE #(
        %tky = <key>-%tky
        %msg = new_message_with_text(
          severity = if_abap_behv_message=>severity-error
          text = 'REVERSE implementation is not activated yet' ) )
        TO reported-operationallocation.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.
