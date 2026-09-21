/* =============================================================================
   130_defect_reports.sql - OPERATIONAL. The row-sensitivity table: some rows
   are third-party proprietary and some are not.

   Rows with `classification = 'THIRD_PARTY_PROPRIETARY'` are filtered from the
   standard role by a row-level security policy applied at L4
   (infra/fabric/protect-tables.ps1). Nothing in THIS file enforces that.

   The contrast with hr_roster is deliberate and is demo material: RLS HIDES
   (rows vanish with no error and no hint that anything was removed), while the
   column-level denial on hr_roster REFUSES (a visible permission error naming
   the column). Which control you choose depends on whether the EXISTENCE of the
   data is itself sensitive.

   Source of truth: data/generators/build.py :: gen_defect_reports (900 rows,
   reported 2024-01-02 .. 2026-06-01, ~17% restricted).

   `CK_defect_reports_3ppi_has_supplier` encodes the invariant the generator
   test also asserts: third-party proprietary information with no third party
   would be incoherent. It is contract in both places on purpose - a generator
   change that broke it would fail the load rather than quietly produce a
   restricted row belonging to nobody.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'defect_reports' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.defect_reports
    (
        [defect_id]      NVARCHAR(16)  NOT NULL,
        [vehicle_id]     NVARCHAR(16)  NOT NULL,
        [supplier_id]    NVARCHAR(16)      NULL,
        [reported_date]  DATE          NOT NULL,
        [severity]       NVARCHAR(16)  NOT NULL,
        [subsystem]      NVARCHAR(48)  NOT NULL,
        [status]         NVARCHAR(24)  NOT NULL,
        [summary]        NVARCHAR(160) NOT NULL,
        [root_cause]     NVARCHAR(64)  NOT NULL,
        [classification] NVARCHAR(32)  NOT NULL,
        CONSTRAINT PK_defect_reports PRIMARY KEY CLUSTERED ([defect_id]),
        CONSTRAINT FK_defect_reports_vehicles FOREIGN KEY ([vehicle_id]) REFERENCES dbo.vehicles ([vehicle_id]),
        CONSTRAINT FK_defect_reports_suppliers FOREIGN KEY ([supplier_id]) REFERENCES dbo.suppliers ([supplier_id]),
        CONSTRAINT CK_defect_reports_severity CHECK ([severity] IN (N'Critical', N'Major', N'Minor')),
        CONSTRAINT CK_defect_reports_status CHECK ([status] IN (N'Closed', N'In Analysis', N'Open')),
        CONSTRAINT CK_defect_reports_classification CHECK ([classification] IN (N'INTERNAL', N'THIRD_PARTY_PROPRIETARY')),
        CONSTRAINT CK_defect_reports_3ppi_has_supplier CHECK ([classification] <> N'THIRD_PARTY_PROPRIETARY' OR [supplier_id] IS NOT NULL)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'130_defect_reports.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'130_defect_reports.sql', 1, 20260822);
GO
