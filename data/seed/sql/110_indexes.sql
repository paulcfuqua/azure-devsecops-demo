/* =============================================================================
   110_indexes.sql - applied LAST, after every table exists.

   Nonclustered indexes only. Each primary key above is already the clustered
   index, and each UNIQUE constraint already materialises its own index, so
   nothing here duplicates one:
     * telemetry_summary.launch_id      -> UQ_telemetry_summary_launch_id
     * cost_daily.(date, cost_center)   -> UQ_cost_daily_date_cost_center

   What is indexed and why - every entry answers a query the demo actually runs:
     * launches.actual_date        weekday-bias question (L8 golden question #1),
                                   launch-schedule view (apps/launch-ops).
     * launches.(vehicle_id|pad_id) fleet/pad utilisation joins; also the FK scan
                                   a delete on the parent would otherwise force.
     * scrubs.launch_id            scrub-per-launch join (FK support).
     * scrubs.(scrub_date,category) monthly scrub trend + cause breakdown.
     * parts.supplier_id           supplier lead-time rollups (FK support).
     * work_orders.*_id            three FK columns; unindexed FKs turn any
                                   parent delete into a table scan.
     * work_orders.status          open/in-progress work queues.
     * cost_daily.cost_center      cost-by-centre series (apps/mcp-tools
                                   LocalCostSeriesBackend filters on it).
     * findings_history.(opened_date, severity, status) security posture trend.

   Sized for a demo dataset (largest table 4,515 rows) - the point is that the
   query plans are honest, not that anything here is a performance necessity.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_launches_actual_date' AND [object_id] = OBJECT_ID(N'dbo.launches'))
    CREATE NONCLUSTERED INDEX IX_launches_actual_date ON dbo.launches ([actual_date]) INCLUDE ([outcome], [vehicle_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_launches_vehicle_id' AND [object_id] = OBJECT_ID(N'dbo.launches'))
    CREATE NONCLUSTERED INDEX IX_launches_vehicle_id ON dbo.launches ([vehicle_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_launches_pad_id' AND [object_id] = OBJECT_ID(N'dbo.launches'))
    CREATE NONCLUSTERED INDEX IX_launches_pad_id ON dbo.launches ([pad_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_scrubs_launch_id' AND [object_id] = OBJECT_ID(N'dbo.scrubs'))
    CREATE NONCLUSTERED INDEX IX_scrubs_launch_id ON dbo.scrubs ([launch_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_scrubs_scrub_date_category' AND [object_id] = OBJECT_ID(N'dbo.scrubs'))
    CREATE NONCLUSTERED INDEX IX_scrubs_scrub_date_category ON dbo.scrubs ([scrub_date], [category]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_parts_supplier_id' AND [object_id] = OBJECT_ID(N'dbo.parts'))
    CREATE NONCLUSTERED INDEX IX_parts_supplier_id ON dbo.parts ([supplier_id]) INCLUDE ([lead_time_days], [category]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_work_orders_part_id' AND [object_id] = OBJECT_ID(N'dbo.work_orders'))
    CREATE NONCLUSTERED INDEX IX_work_orders_part_id ON dbo.work_orders ([part_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_work_orders_vehicle_id' AND [object_id] = OBJECT_ID(N'dbo.work_orders'))
    CREATE NONCLUSTERED INDEX IX_work_orders_vehicle_id ON dbo.work_orders ([vehicle_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_work_orders_launch_id' AND [object_id] = OBJECT_ID(N'dbo.work_orders'))
    CREATE NONCLUSTERED INDEX IX_work_orders_launch_id ON dbo.work_orders ([launch_id]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_work_orders_status' AND [object_id] = OBJECT_ID(N'dbo.work_orders'))
    CREATE NONCLUSTERED INDEX IX_work_orders_status ON dbo.work_orders ([status]) INCLUDE ([priority], [opened_date]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_cost_daily_cost_center' AND [object_id] = OBJECT_ID(N'dbo.cost_daily'))
    CREATE NONCLUSTERED INDEX IX_cost_daily_cost_center ON dbo.cost_daily ([cost_center]) INCLUDE ([amount_usd], [budget_usd]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_findings_history_opened_date' AND [object_id] = OBJECT_ID(N'dbo.findings_history'))
    CREATE NONCLUSTERED INDEX IX_findings_history_opened_date ON dbo.findings_history ([opened_date]) INCLUDE ([severity], [status]);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE [name] = N'IX_findings_history_severity_status' AND [object_id] = OBJECT_ID(N'dbo.findings_history'))
    CREATE NONCLUSTERED INDEX IX_findings_history_severity_status ON dbo.findings_history ([severity], [status]);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'110_indexes.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'110_indexes.sql', 1, 20260822);
GO
