/* =============================================================================
   040_parts.sql - REFERENCE plane. FK -> suppliers, so 030 must run first.

   Source of truth: data/generators/build.py :: gen_parts (300 rows).
   `material` is BOTH nullable (NULL_RATE 0.03) and dirty (DIRTY_RATE 0.06):
   values may arrive UPPER, lower, or with leading/trailing/doubled whitespace.
   That damage is deliberate demo material - do NOT add a normalising constraint,
   a TRIM default, or a CHECK on this column.

   `lead_time_days` carries the supply-chain outliers (LEAD_TIME_OUTLIER_RATE
   0.07 multiplies by 4-9x, so values past 200 days are expected, not corrupt).
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'parts' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.parts
    (
        [part_id]        NVARCHAR(16)   NOT NULL,
        [part_number]    NVARCHAR(32)   NOT NULL,
        [name]           NVARCHAR(96)   NOT NULL,
        [category]       NVARCHAR(32)   NOT NULL,
        [supplier_id]    NVARCHAR(16)   NOT NULL,
        [unit_cost_usd]  DECIMAL(18, 2) NOT NULL,
        [lead_time_days] INT            NOT NULL,
        [qty_on_hand]    INT            NOT NULL,
        [min_stock]      INT            NOT NULL,
        [criticality]    INT            NOT NULL,
        [material]       NVARCHAR(64)       NULL,
        CONSTRAINT PK_parts PRIMARY KEY CLUSTERED ([part_id]),
        CONSTRAINT FK_parts_suppliers FOREIGN KEY ([supplier_id]) REFERENCES dbo.suppliers ([supplier_id]),
        CONSTRAINT CK_parts_criticality CHECK ([criticality] BETWEEN 1 AND 3),
        CONSTRAINT CK_parts_category CHECK ([category] IN (
            N'Propulsion', N'Structures', N'Avionics', N'GNC',
            N'Pressurization', N'Recovery', N'Ground Support')),
        CONSTRAINT CK_parts_lead_time_days CHECK ([lead_time_days] >= 3)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'040_parts.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'040_parts.sql', 1, 20260822);
GO
