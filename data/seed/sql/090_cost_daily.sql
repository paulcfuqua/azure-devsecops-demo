/* =============================================================================
   090_cost_daily.sql - ANALYTICAL MIRROR, and the one table with a live writer
   outside this seed.

   Master plan L6: "Cost Management daily export -> storage -> Function
   (consumption) -> lakehouse `cost_daily`". The LAKEHOUSE copy is therefore the
   system of record and the one the Function appends to. This Azure SQL table is
   the seeded mirror the L7 app views read; the seed backfills it with the
   deterministic history (2024-01-01 .. 2026-06-21, 5 cost centres x 903 days =
   4,515 rows) so the demo has a cost series on day one, before Cost Management
   has produced anything.

   Source of truth: data/generators/build.py :: gen_cost_daily.

   `date` is a T-SQL type name but not a reserved keyword, so
   apps/mcp-tools' unbracketed `SELECT date, cost_center FROM cost_daily`
   binds fine. It is bracketed in the DDL for clarity only.

   UQ_cost_daily_date_cost_center is the anti-duplicate tripwire: exactly one row
   per (day, cost centre). A double-load fails here rather than inflating spend.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'cost_daily' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.cost_daily
    (
        [cost_id]     NVARCHAR(16)   NOT NULL,
        [date]        DATE           NOT NULL,
        [cost_center] NVARCHAR(64)   NOT NULL,
        [amount_usd]  DECIMAL(18, 2) NOT NULL,
        [budget_usd]  DECIMAL(18, 2) NOT NULL,
        [currency]    NVARCHAR(8)    NOT NULL,
        CONSTRAINT PK_cost_daily PRIMARY KEY CLUSTERED ([cost_id]),
        CONSTRAINT UQ_cost_daily_date_cost_center UNIQUE ([date], [cost_center]),
        CONSTRAINT CK_cost_daily_amount_usd CHECK ([amount_usd] >= 0.0),
        CONSTRAINT CK_cost_daily_budget_usd CHECK ([budget_usd] >= 0.0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'090_cost_daily.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'090_cost_daily.sql', 1, 20260822);
GO
