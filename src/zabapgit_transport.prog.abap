*&---------------------------------------------------------------------*
*&  Include           ZABAPGIT_TRANSPORT
*&---------------------------------------------------------------------*
CLASS lcl_transport DEFINITION FINAL.

  PUBLIC SECTION.
    CLASS-METHODS:
      zip RAISING lcx_exception,
      to_tadir IMPORTING it_transport_headers TYPE trwbo_request_headers
               RETURNING VALUE(rt_tadir)      TYPE scts_tadir
               RAISING   lcx_exception.

  PRIVATE SECTION.
    CLASS-METHODS:
      read_requests
        IMPORTING it_trkorr          TYPE trwbo_request_headers
        RETURNING VALUE(rt_requests) TYPE trwbo_requests
        RAISING   lcx_exception,
      find_top_package
        IMPORTING it_tadir          TYPE scts_tadir
        RETURNING VALUE(rv_package) TYPE devclass,
      resolve
        IMPORTING it_requests     TYPE trwbo_requests
        RETURNING VALUE(rt_tadir) TYPE scts_tadir
        RAISING   lcx_exception.

ENDCLASS.

CLASS lcl_transport IMPLEMENTATION.

  METHOD zip.
    DATA: lt_requests TYPE trwbo_requests,
          lt_tadir    TYPE scts_tadir,
          lv_package  TYPE devclass,
          ls_data     TYPE lcl_persistence_repo=>ty_repo,
          lo_repo     TYPE REF TO lcl_repo_offline,
          lt_trkorr   TYPE trwbo_request_headers.


    lt_trkorr = lcl_popups=>popup_to_select_transports( ).
    IF lines( lt_trkorr ) = 0.
      RETURN.
    ENDIF.

    lt_requests = read_requests( lt_trkorr ).
    lt_tadir = resolve( lt_requests ).
    IF lines( lt_tadir ) = 0.
      lcx_exception=>raise( 'empty transport' ).
    ENDIF.

    lv_package = find_top_package( lt_tadir ).
    IF lv_package IS INITIAL.
      lcx_exception=>raise( 'error finding super package' ).
    ENDIF.

    ls_data-key         = 'TZIP'.
    ls_data-package     = lv_package.
    ls_data-dot_abapgit = lcl_dot_abapgit=>build_default( )->get_data( ).

    CREATE OBJECT lo_repo
      EXPORTING
        is_data = ls_data.

    lcl_zip=>export( io_repo   = lo_repo
                     it_filter = lt_tadir ).
  ENDMETHOD.

  METHOD to_tadir.
    DATA: lt_requests TYPE trwbo_requests,
          lt_tadir    TYPE scts_tadir,
          lv_package  TYPE devclass,
          lt_trkorr   TYPE trwbo_request_headers.


    IF lines( it_transport_headers ) = 0.
      RETURN.
    ENDIF.

    lt_requests = read_requests( it_transport_headers ).
    rt_tadir = resolve( lt_requests ).
  ENDMETHOD.

  METHOD find_top_package.
* assumption: all objects in transport share a common super package

    DATA: lt_obj   TYPE lif_sap_package=>ty_devclass_tt,
          lt_super TYPE lif_sap_package=>ty_devclass_tt,
          lv_super LIKE LINE OF lt_super,
          lv_index TYPE i.

    FIELD-SYMBOLS: <ls_tadir> LIKE LINE OF it_tadir.


    READ TABLE it_tadir INDEX 1 ASSIGNING <ls_tadir>.
    ASSERT sy-subrc = 0.
    lt_super = lcl_sap_package=>get( <ls_tadir>-devclass )->list_superpackages( ).

    LOOP AT it_tadir ASSIGNING <ls_tadir>.
      lt_obj = lcl_sap_package=>get( <ls_tadir>-devclass )->list_superpackages( ).

* filter out possibilities from lt_super
      LOOP AT lt_super INTO lv_super.
        lv_index = sy-tabix.
        READ TABLE lt_obj FROM lv_super TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          DELETE lt_super INDEX lv_index.
        ENDIF.
      ENDLOOP.
    ENDLOOP.

    SORT lt_super.
    READ TABLE lt_super INDEX 1 INTO rv_package.
  ENDMETHOD.

  METHOD read_requests.
    DATA lt_requests LIKE rt_requests.
    FIELD-SYMBOLS <fs_trkorr> LIKE LINE OF it_trkorr.

    LOOP AT it_trkorr ASSIGNING <fs_trkorr>.
      CALL FUNCTION 'TR_READ_REQUEST_WITH_TASKS'
        EXPORTING
          iv_trkorr     = <fs_trkorr>-trkorr
        IMPORTING
          et_requests   = lt_requests
        EXCEPTIONS
          invalid_input = 1
          OTHERS        = 2.
      IF sy-subrc <> 0.
        lcx_exception=>raise( 'error from TR_READ_REQUEST_WITH_TASKS' ).
      ENDIF.

      APPEND LINES OF lt_requests TO rt_requests.
    ENDLOOP.
  ENDMETHOD.

  METHOD resolve.
    DATA: lv_object     TYPE tadir-object,
          lv_obj_name   TYPE tadir-obj_name,
          lv_trobj_name TYPE trobj_name,
          ls_tadir      TYPE tadir.

    FIELD-SYMBOLS: <ls_request> LIKE LINE OF it_requests,
                   <ls_object>  LIKE LINE OF <ls_request>-objects.


    LOOP AT it_requests ASSIGNING <ls_request>.
      LOOP AT <ls_request>-objects ASSIGNING <ls_object>.
        IF <ls_object>-pgmid = 'LIMU'.
          CALL FUNCTION 'GET_R3TR_OBJECT_FROM_LIMU_OBJ'
            EXPORTING
              p_limu_objtype = <ls_object>-object
              p_limu_objname = <ls_object>-obj_name
            IMPORTING
              p_r3tr_objtype = lv_object
              p_r3tr_objname = lv_trobj_name
            EXCEPTIONS
              no_mapping     = 1
              OTHERS         = 2.
          IF sy-subrc <> 0.
            lcx_exception=>raise( 'error from GET_R3TR_OBJECT_FROM_LIMU_OBJ' ).
          ENDIF.
          lv_obj_name = lv_trobj_name.
        ELSE.
          lv_object   = <ls_object>-object.
          lv_obj_name = <ls_object>-obj_name.
        ENDIF.

        ls_tadir = lcl_tadir=>read_single(
          iv_object   = lv_object
          iv_obj_name = lv_obj_name ).

        APPEND ls_tadir TO rt_tadir.
      ENDLOOP.
    ENDLOOP.

    SORT rt_tadir BY object ASCENDING obj_name ASCENDING.
    DELETE ADJACENT DUPLICATES FROM rt_tadir COMPARING object obj_name.
    DELETE rt_tadir WHERE table_line IS INITIAL.
  ENDMETHOD.
ENDCLASS.

CLASS lcl_transport_to_branch DEFINITION.
  PUBLIC SECTION.
    METHODS:
      create
        IMPORTING io_repository          TYPE REF TO lcl_repo_online
                  is_transport_to_branch TYPE ty_transport_to_branch
                  it_transport_objects   TYPE scts_tadir
        RAISING   lcx_exception.
  PRIVATE SECTION.

    METHODS create_new_branch
      IMPORTING
        io_repository  TYPE REF TO lcl_repo_online
        iv_branch_name TYPE string
      RAISING
        lcx_exception.
    METHODS generate_commit_message
      IMPORTING
        is_transport_to_branch TYPE ty_transport_to_branch
      RETURNING
        VALUE(rs_comment)      TYPE ty_comment.
    METHODS stage_transport_objects
      IMPORTING
        it_transport_objects TYPE scts_tadir
        io_stage             TYPE REF TO lcl_stage
        is_stage_objects     TYPE ty_stage_files
        it_object_statuses   TYPE ty_results_tt
      RAISING
        lcx_exception.
ENDCLASS.

CLASS lcl_transport_to_branch IMPLEMENTATION.

  METHOD create.
    DATA:
      ls_transport_object TYPE LINE OF scts_tadir,
      lt_items            TYPE ty_files_item_tt,
      ls_local_file       TYPE LINE OF ty_files_item_tt,
      ls_remote_file      TYPE LINE OF ty_files_tt,
      ls_item             TYPE string,
      lv_branch_name      TYPE string,
      ls_comment          TYPE ty_comment,
      lo_stage            TYPE REF TO lcl_stage,
      ls_stage_objects    TYPE ty_stage_files,
      lt_object_statuses  TYPE ty_results_tt,
      ls_object_status    TYPE LINE OF ty_results_tt.

    lv_branch_name = lcl_git_branch_list=>complete_heads_branch_name(
        lcl_git_branch_list=>normalize_branch_name( is_transport_to_branch-branch_name ) ).

    create_new_branch(
      io_repository  = io_repository
      iv_branch_name = lv_branch_name ).

    CREATE OBJECT lo_stage
      EXPORTING
        iv_branch_name = lv_branch_name
        iv_branch_sha1 = io_repository->get_sha1_remote( ).

    ls_stage_objects = lcl_stage_logic=>get( io_repository ).

    lt_object_statuses = io_repository->status( ).

    stage_transport_objects(
       it_transport_objects = it_transport_objects
       io_stage             = lo_stage
       is_stage_objects     = ls_stage_objects
       it_object_statuses   = lt_object_statuses ).

    ls_comment = generate_commit_message( is_transport_to_branch ).

    io_repository->push( is_comment = ls_comment
                         io_stage   = lo_stage ).
  ENDMETHOD.

  METHOD create_new_branch.
    ASSERT iv_branch_name CP 'refs/heads/+*'.
    TRY.
        lcl_git_porcelain=>create_branch(
          io_repo = io_repository
          iv_name = iv_branch_name
          iv_from = io_repository->get_sha1_local( ) ).

        io_repository->set_branch_name( iv_branch_name ).
      CATCH lcx_exception.
        lcx_exception=>raise( 'Error when creating new branch').
    ENDTRY.
  ENDMETHOD.

  METHOD generate_commit_message.
    rs_comment-committer-name  = sy-uname.
    rs_comment-committer-email = |{ rs_comment-committer-name }@localhost|.
    rs_comment-comment         = is_transport_to_branch-commit_text.
  ENDMETHOD.


  METHOD stage_transport_objects.

    DATA ls_transport_object TYPE tadir.
    DATA ls_local_file TYPE ty_file_item.
    DATA ls_object_status TYPE ty_result.

    LOOP AT it_transport_objects INTO ls_transport_object.
      READ TABLE it_object_statuses INTO ls_object_status
        WITH KEY obj_name = ls_transport_object-obj_name
                 obj_type = ls_transport_object-object.
      IF sy-subrc <> 0.
        lcx_exception=>raise( |Object { ls_transport_object-obj_name } not found in the local repository files | ).
      ENDIF.

      CASE ls_object_status-lstate.
        WHEN gc_state-added OR gc_state-modified.
          ASSERT ls_transport_object-delflag = abap_false.

          READ TABLE is_stage_objects-local
                INTO ls_local_file
            WITH KEY item-obj_name = ls_transport_object-obj_name
                     item-obj_type = ls_transport_object-object.
          IF sy-subrc <> 0.
            lcx_exception=>raise( |Object { ls_transport_object-obj_name } not found in the local repository files | ).
          ENDIF.

          io_stage->add(
            iv_path     = ls_local_file-file-path
            iv_filename = ls_local_file-file-filename
            iv_data     = ls_local_file-file-data ).
        WHEN gc_state-deleted.
          ASSERT ls_transport_object-delflag = abap_true.
          io_stage->rm(
            iv_path     = ls_object_status-path
            iv_filename = ls_object_status-filename ).
        WHEN OTHERS.
          ASSERT 0 = 1. "Unexpected state
      ENDCASE.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.

CLASS lcl_transport_objects DEFINITION.
  "Under test at ltcl_transport_objects
  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        it_transport_objects TYPE scts_tadir.
    METHODS to_stage
      IMPORTING
        io_stage           TYPE REF TO lcl_stage
        is_stage_objects   TYPE ty_stage_files
        it_object_statuses TYPE ty_results_tt
      RAISING
        lcx_exception.
  PRIVATE SECTION.
    DATA mt_transport_objects TYPE scts_tadir.
ENDCLASS.

CLASS lcl_transport_objects IMPLEMENTATION.
  METHOD constructor.
    mt_transport_objects = it_transport_objects.
  ENDMETHOD.

  METHOD to_stage.
    DATA ls_transport_object TYPE tadir.
    DATA ls_local_file TYPE ty_file_item.
    DATA ls_object_status TYPE ty_result.

    LOOP AT mt_transport_objects INTO ls_transport_object.
      READ TABLE it_object_statuses INTO ls_object_status
        WITH KEY obj_name = ls_transport_object-obj_name
                 obj_type = ls_transport_object-object.
      IF sy-subrc <> 0.
        lcx_exception=>raise( |Object { ls_transport_object-obj_name } not found in the local repository files| ).
      ENDIF.

      CASE ls_object_status-lstate.
        WHEN gc_state-added OR gc_state-modified.
*          ASSERT ls_transport_object-delflag = abap_false.

          READ TABLE is_stage_objects-local
                INTO ls_local_file
            WITH KEY item-obj_name = ls_transport_object-obj_name
                     item-obj_type = ls_transport_object-object.
          IF sy-subrc <> 0.
            lcx_exception=>raise( |Object { ls_transport_object-obj_name } not found in the local repository files | ).
          ENDIF.

          io_stage->add(
            iv_path     = ls_local_file-file-path
            iv_filename = ls_local_file-file-filename
            iv_data     = ls_local_file-file-data ).
*        WHEN gc_state-deleted.
*          ASSERT ls_transport_object-delflag = abap_true.
*          io_stage->rm(
*            iv_path     = ls_object_status-path
*            iv_filename = ls_object_status-filename ).
*        WHEN OTHERS.
*          ASSERT 0 = 1. "Unexpected state
      ENDCASE.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.

CLASS ltcl_transport_objects DEFINITION FOR TESTING.
  PRIVATE SECTION.
    METHODS:
      add_new_to_local_files FOR TESTING RAISING cx_static_check,
      modified_to_new_local_files FOR TESTING RAISING cx_static_check,
      transport_not_in_repository FOR TESTING RAISING cx_static_check,
      object_not_in_local_files   FOR TESTING RAISING cx_static_check,
      setup,
      given_the_transport_object
        IMPORTING iv_obj_name TYPE string
                  iv_obj_type TYPE string,
      given_the_object_status
        IMPORTING
          iv_obj_name TYPE string
          iv_obj_type TYPE string
          iv_lstate   TYPE char1,
      given_the_local_file
        IMPORTING iv_obj_name          TYPE string
                  iv_obj_type          TYPE string
                  iv_filename          TYPE string
                  iv_path              TYPE string
                  iv_data              TYPE string
        RETURNING VALUE(rs_local_file) TYPE ty_file_item,
      when_staging
        RAISING lcx_exception,
      then_file_should_be_added
        IMPORTING
          is_local_file TYPE ty_file_item,
      then_it_should_raise_exception
        IMPORTING
          with_text TYPE string.

    DATA: mo_transport_objects TYPE REF TO lcl_transport_objects,
          mt_transport_objects TYPE scts_tadir,
          mt_object_statuses   TYPE ty_results_tt,
          ms_stage_objects     TYPE ty_stage_files,
          mo_stage             TYPE REF TO lcl_stage.
ENDCLASS.

CLASS ltcl_transport_objects IMPLEMENTATION.
  METHOD setup.
    CREATE OBJECT mo_stage
      EXPORTING
        iv_branch_name = 'A_branch_name'
        iv_branch_sha1 = 'Branch_SH1'.
  ENDMETHOD.
  METHOD add_new_to_local_files.
    DATA ls_local_file TYPE ty_file_item.

    given_the_transport_object(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS' ).

    given_the_object_status(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS'
      iv_lstate     = gc_state-added ).

    ls_local_file = given_the_local_file(
      iv_obj_name = 'CL_FOO'
      iv_obj_type = 'CLAS'
      iv_filename = 'CL_FOO.abap'
      iv_path     = '/path'
      iv_data     = 'data' ).

    when_staging( ).

    then_file_should_be_added( ls_local_file ).
  ENDMETHOD.
  METHOD modified_to_new_local_files.
    DATA ls_local_file TYPE ty_file_item.

    given_the_transport_object(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS' ).

    given_the_object_status(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS'
      iv_lstate     = gc_state-modified ).

    ls_local_file = given_the_local_file(
      iv_obj_name = 'CL_FOO'
      iv_obj_type = 'CLAS'
      iv_filename = 'CL_FOO.abap'
      iv_path     = '/path'
      iv_data     = 'data' ).

    when_staging( ).

    then_file_should_be_added( ls_local_file ).
  ENDMETHOD.
  METHOD transport_not_in_repository.
    given_the_transport_object(
      iv_obj_name   = 'CL_A_CLASS_NOT_IN_REPO'
      iv_obj_type   = 'CLAS' ).

    given_the_object_status(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS'
      iv_lstate     = gc_state-added ).

    then_it_should_raise_exception(
      with_text = 'Object CL_A_CLASS_NOT_IN_REPO not found in the local repository files' ).
  ENDMETHOD.

  METHOD object_not_in_local_files.
    DATA ls_local_file TYPE ty_file_item.

    given_the_transport_object(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS' ).

    given_the_object_status(
      iv_obj_name   = 'CL_FOO'
      iv_obj_type   = 'CLAS'
      iv_lstate     = gc_state-added ).

    given_the_local_file(
      iv_obj_name = 'CL_ANOTHER_LOCAL_FILE'
      iv_obj_type = 'CLAS'
      iv_filename = 'CL_FOO.abap'
      iv_path     = '/path'
      iv_data     = 'data' ).

    then_it_should_raise_exception(
      with_text = 'Object CL_A_CLASS_NOT_IN_REPO not found in the local repository files' ).
  ENDMETHOD.

  METHOD given_the_transport_object.
    DATA ls_transport_object TYPE tadir.
    ls_transport_object-obj_name = iv_obj_name.
    ls_transport_object-object   = iv_obj_type.
    APPEND ls_transport_object TO mt_transport_objects.
  ENDMETHOD.


  METHOD given_the_object_status.
    DATA ls_object_status TYPE ty_result.
    ls_object_status-obj_name = iv_obj_name.
    ls_object_status-obj_type = iv_obj_type.
    ls_object_status-lstate   = iv_lstate.
    APPEND ls_object_status  TO mt_object_statuses.
  ENDMETHOD.


  METHOD given_the_local_file.
    rs_local_file-item-obj_name = iv_obj_name.
    rs_local_file-item-obj_type = iv_obj_type.
    rs_local_file-file-filename = iv_filename.
    rs_local_file-file-path     = iv_path.
    rs_local_file-file-data     = iv_data.
    APPEND rs_local_file TO ms_stage_objects-local.
  ENDMETHOD.


  METHOD when_staging.
    CREATE OBJECT mo_transport_objects
      EXPORTING
        it_transport_objects = mt_transport_objects.
    mo_transport_objects->to_stage(
      io_stage           = mo_stage
      is_stage_objects   = ms_stage_objects
      it_object_statuses = mt_object_statuses ).
  ENDMETHOD.

  METHOD then_file_should_be_added.
    DATA: lt_staged_objects TYPE lcl_stage=>ty_stage_tt.
    lt_staged_objects = mo_stage->get_all( ).

    READ TABLE lt_staged_objects TRANSPORTING NO FIELDS
    WITH KEY file-filename = is_local_file-file-filename
            file-path      = is_local_file-file-path
            file-data      = is_local_file-file-data
            method         = lcl_stage=>c_method-add.
    IF sy-subrc <> 0.
      cl_abap_unit_assert=>fail( |Object { is_local_file-file-filename } not added to stage| ).
    ENDIF.
  ENDMETHOD.

  METHOD then_it_should_raise_exception.
    DATA: lo_exception TYPE REF TO lcx_exception.
    TRY.
        when_staging( ).
        cl_abap_unit_assert=>fail( 'Should have raised exception').
      CATCH lcx_exception INTO lo_exception.
        cl_abap_unit_assert=>assert_equals(
          act = lo_exception->mv_text
          exp = with_text ).
    ENDTRY.
  ENDMETHOD.
ENDCLASS.
