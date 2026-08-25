/* =============================================================================
   000_schema_version.sql - applied FIRST. Every other script in this directory
   stamps itself here, so `SELECT * FROM dbo.schema_version ORDER BY applied_utc`
   is the audit trail for what the operational database actually has.

   Target: Azure SQL serverless (L6, `mls-ops-demo-sql`). Idempotent: safe to
   re-run on every kill/rebuild cycle.

   Batches are separated by a line containing only GO. data/seed/seed.ps1 splits
   on that itself (Split-SqlBatch) so the files do not depend on sqlcmd.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'schema_version' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.schema_version
    (
        [script_name]     NVARCHAR(128) NOT NULL,
        [schema_version]  INT           NOT NULL,
        [generator_seed]  INT           NOT NULL,
        [applied_utc]     DATETIME2(3)  NOT NULL CONSTRAINT DF_schema_version_applied_utc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_schema_version PRIMARY KEY CLUSTERED ([script_name])
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'000_schema_version.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'000_schema_version.sql', 1, 20260822);
GO
