/* =============================================================================
   080_work_orders.sql - OPERATIONAL plane. FK -> parts, vehicles and launches,
   so 010, 040 and 050 must all run first.

   Source of truth: data/generators/build.py :: gen_work_orders (800 rows).

   `launch_id` is NULLABLE by design - roughly 40% of work orders are fleet
   maintenance not tied to a flight. `closed_date` and `disposition` are null
   while the order is open or in progress; the CHECK below states that pairing
   rather than leaving it as folklore.

   `technician` is a DIRTY column (DIRTY_RATE 0.06). No TRIM, no normalisation.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'work_orders' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.work_orders
    (
        [work_order_id] NVARCHAR(16) NOT NULL,
        [part_id]       NVARCHAR(16) NOT NULL,
        [vehicle_id]    NVARCHAR(16) NOT NULL,
        [launch_id]     NVARCHAR(16)     NULL,
        [opened_date]   DATE         NOT NULL,
        [closed_date]   DATE             NULL,
        [status]        NVARCHAR(16) NOT NULL,
        [disposition]   NVARCHAR(16)     NULL,
        [priority]      NVARCHAR(4)  NOT NULL,
        [labor_hours]   FLOAT        NOT NULL,
        [technician]    NVARCHAR(96) NOT NULL,
        CONSTRAINT PK_work_orders PRIMARY KEY CLUSTERED ([work_order_id]),
        CONSTRAINT FK_work_orders_parts FOREIGN KEY ([part_id]) REFERENCES dbo.parts ([part_id]),
        CONSTRAINT FK_work_orders_vehicles FOREIGN KEY ([vehicle_id]) REFERENCES dbo.vehicles ([vehicle_id]),
        CONSTRAINT FK_work_orders_launches FOREIGN KEY ([launch_id]) REFERENCES dbo.launches ([launch_id]),
        CONSTRAINT CK_work_orders_status CHECK ([status] IN (N'open', N'in_progress', N'closed')),
        CONSTRAINT CK_work_orders_priority CHECK ([priority] IN (N'P1', N'P2', N'P3', N'P4')),
        CONSTRAINT CK_work_orders_disposition CHECK (
            [disposition] IS NULL OR [disposition] IN (N'repair', N'replace', N'use-as-is', N'scrap')),
        CONSTRAINT CK_work_orders_closure CHECK (
            ([status] = N'closed' AND [closed_date] IS NOT NULL AND [disposition] IS NOT NULL)
            OR ([status] <> N'closed' AND [closed_date] IS NULL AND [disposition] IS NULL)),
        CONSTRAINT CK_work_orders_dates CHECK ([closed_date] IS NULL OR [closed_date] >= [opened_date]),
        CONSTRAINT CK_work_orders_labor_hours CHECK ([labor_hours] > 0.0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'080_work_orders.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'080_work_orders.sql', 1, 20260822);
GO
