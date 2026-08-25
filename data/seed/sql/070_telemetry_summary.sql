/* =============================================================================
   070_telemetry_summary.sql - ANALYTICAL MIRROR. The lakehouse `mls_operations`
   is the system of record for telemetry; this Azure SQL copy exists only so L7
   app views can join it to `launches` without crossing planes. Nothing in the
   app writes it - it is refreshed by re-seeding.

   Source of truth: data/generators/build.py :: gen_telemetry (exactly one row
   per launch => 1,200 rows). FK -> launches, so 050 must run first.

   UQ_telemetry_summary_launch_id enforces that 1:1 relationship. It is also the
   loader's anti-duplicate tripwire: a second append without a wipe fails loudly
   here instead of silently doubling the row count (L5 failure mode 3).
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'telemetry_summary' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.telemetry_summary
    (
        [telemetry_id]           NVARCHAR(16) NOT NULL,
        [launch_id]              NVARCHAR(16) NOT NULL,
        [max_q_kpa]              FLOAT        NOT NULL,
        [max_accel_g]            FLOAT        NOT NULL,
        [meco_time_s]            FLOAT        NOT NULL,
        [peak_thrust_kn]         FLOAT        NOT NULL,
        [max_altitude_km]        FLOAT        NOT NULL,
        [anomaly_count]          INT          NOT NULL,
        [telemetry_coverage_pct] FLOAT        NOT NULL,
        [data_dropout_s]         FLOAT            NULL,
        CONSTRAINT PK_telemetry_summary PRIMARY KEY CLUSTERED ([telemetry_id]),
        CONSTRAINT UQ_telemetry_summary_launch_id UNIQUE ([launch_id]),
        CONSTRAINT FK_telemetry_summary_launches FOREIGN KEY ([launch_id]) REFERENCES dbo.launches ([launch_id]),
        CONSTRAINT CK_telemetry_summary_anomaly_count CHECK ([anomaly_count] >= 0),
        CONSTRAINT CK_telemetry_summary_coverage CHECK ([telemetry_coverage_pct] BETWEEN 0.0 AND 100.0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'070_telemetry_summary.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'070_telemetry_summary.sql', 1, 20260822);
GO
