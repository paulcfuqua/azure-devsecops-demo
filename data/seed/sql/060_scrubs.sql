/* =============================================================================
   060_scrubs.sql - OPERATIONAL plane. FK -> launches, so 050 must run first.

   Source of truth: data/generators/build.py :: gen_scrubs (475 rows at seed
   20260822 - DERIVED from launches.scrub_count, not an independent count).

   Multi-scrub launches are weather cascades (CASCADE_PROB 0.65): consecutive
   scrub_date values for the same launch_id. There is deliberately NO unique
   constraint on (launch_id, scrub_date) beyond the surrogate PK - a launch can
   legitimately hold on the same calendar day more than once in this model, and
   a constraint here would turn demo realism into a load failure.

   `recycle_hours` is the NULL_RATE column.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'scrubs' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.scrubs
    (
        [scrub_id]            NVARCHAR(16)  NOT NULL,
        [launch_id]           NVARCHAR(16)  NOT NULL,
        [scrub_date]          DATE          NOT NULL,
        [category]            NVARCHAR(32)  NOT NULL,
        [reason]              NVARCHAR(160) NOT NULL,
        [called_at_t_minus_s] INT           NOT NULL,
        [recycle_hours]       FLOAT             NULL,
        CONSTRAINT PK_scrubs PRIMARY KEY CLUSTERED ([scrub_id]),
        CONSTRAINT FK_scrubs_launches FOREIGN KEY ([launch_id]) REFERENCES dbo.launches ([launch_id]),
        CONSTRAINT CK_scrubs_category CHECK ([category] IN (N'weather', N'technical', N'range', N'payload')),
        CONSTRAINT CK_scrubs_called_at_t_minus_s CHECK ([called_at_t_minus_s] > 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'060_scrubs.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'060_scrubs.sql', 1, 20260822);
GO
