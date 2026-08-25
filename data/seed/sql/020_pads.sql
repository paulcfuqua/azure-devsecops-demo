/* =============================================================================
   020_pads.sql - REFERENCE plane (seeded once, read-mostly, FK target).

   Source of truth: data/generators/pools.py :: PADS (static, 11 rows).
   Coordinates are FLOAT rather than GEOGRAPHY: the apps read them as plain
   numbers (apps/launch-ops/src/providers/types.ts :: PadRow) and no spatial
   query exists anywhere in the demo.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'pads' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.pads
    (
        [pad_id]          NVARCHAR(16)  NOT NULL,
        [name]            NVARCHAR(32)  NOT NULL,
        [site]            NVARCHAR(128) NOT NULL,
        [country]         NVARCHAR(64)  NOT NULL,
        [latitude]        FLOAT         NOT NULL,
        [longitude]       FLOAT         NOT NULL,
        [first_used_year] INT           NOT NULL,
        [status]          NVARCHAR(16)  NOT NULL,
        CONSTRAINT PK_pads PRIMARY KEY CLUSTERED ([pad_id]),
        CONSTRAINT CK_pads_status CHECK ([status] IN (N'active', N'retired')),
        CONSTRAINT CK_pads_latitude CHECK ([latitude] BETWEEN -90.0 AND 90.0),
        CONSTRAINT CK_pads_longitude CHECK ([longitude] BETWEEN -180.0 AND 180.0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'020_pads.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'020_pads.sql', 1, 20260822);
GO
