# ABAP RAP Mobile Production Sync

Source bundle for the ABAP RAP backend described in
[`ABAP_RAP_MOBILE_SYNC_PLAN.md`](../ABAP_RAP_MOBILE_SYNC_PLAN.md).

## Target

- SAP S/4HANA Cloud Public Edition
- ABAP for Cloud Development
- Managed RAP, non-draft
- OData V4 service binding

## Import order in ADT

1. Create package `ZPP_MOBILE_SYNC` (or map the sources to your package).
2. Activate database tables in `src/tables`.
3. Activate abstract entities in `src/abstract`.
4. Activate interface CDS entities in `src/cds/interface`.
5. Activate projection CDS entities in `src/cds/projection`.
6. Create and activate behavior pools, then activate BDEF sources.
7. Activate the service definition and create an OData V4 service binding in ADT.

These files contain the repository source text. ADT metadata/XML files are not
generated because this workspace is not connected to an ABAP system.

## Current milestone

- Persistence tables
- Worker validation reference view
- RAP action parameter entities
- Domain interface/projection CDS and behavior definitions

The bgPF worker, SAP production confirmation adapter, APJ recovery job, and
authorization implementation require target-tenant released-object checks and
are intentionally implemented after the base BO activates successfully.

