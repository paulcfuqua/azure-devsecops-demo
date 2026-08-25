/* =============================================================================
   030_suppliers.sql - REFERENCE plane (seeded once, read-mostly, FK target).

   Source of truth: data/generators/build.py :: gen_suppliers (24 rows).
   Every supplier is fictional (CLAUDE.md hard rule 4).
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'suppliers' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.suppliers
    (
        [supplier_id]        NVARCHAR(16) NOT NULL,
        [name]               NVARCHAR(96) NOT NULL,
        [country]            NVARCHAR(64) NOT NULL,
        [certification]      NVARCHAR(48) NOT NULL,
        [avg_lead_time_days] INT          NOT NULL,
        [on_time_pct]        FLOAT        NOT NULL,
        [quality_rating]     FLOAT        NOT NULL,
        [active]             BIT          NOT NULL,
        CONSTRAINT PK_suppliers PRIMARY KEY CLUSTERED ([supplier_id]),
        CONSTRAINT CK_suppliers_on_time_pct CHECK ([on_time_pct] BETWEEN 0.0 AND 100.0),
        CONSTRAINT CK_suppliers_avg_lead_time_days CHECK ([avg_lead_time_days] > 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'030_suppliers.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'030_suppliers.sql', 1, 20260822);
GO
