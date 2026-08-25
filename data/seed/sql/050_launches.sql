/* =============================================================================
   050_launches.sql - OPERATIONAL plane. The launch-ops app (L7) does CRUD here;
   Azure SQL is the system of record for this table. FK -> vehicles, pads, so
   010 and 020 must run first.

   Source of truth: data/generators/build.py :: gen_launches (exactly 1,200 rows
   at seed 20260822 - the master plan pins this count at +/- 0).

   `customer` is a DIRTY column (DIRTY_RATE 0.06): casing and whitespace damage
   is intentional. No TRIM, no normalising constraint.
   `weather_delay_min` and `insurance_value_musd` are the two NULL_RATE columns.
   Everything else the generator always populates, so it is NOT NULL here - that
   is the schema contract, even though apps/launch-ops types the fields
   defensively as `| null` on the TypeScript side.

   `actual_date` carries the Saturday launch-window bias that the L8 golden
   questions depend on. Indexed in 110_indexes.sql.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'launches' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.launches
    (
        [launch_id]            NVARCHAR(16)   NOT NULL,
        [mission_name]         NVARCHAR(32)   NOT NULL,
        [vehicle_id]           NVARCHAR(16)   NOT NULL,
        [pad_id]               NVARCHAR(16)   NOT NULL,
        [customer]             NVARCHAR(128)  NOT NULL,
        [orbit]                NVARCHAR(16)   NOT NULL,
        [planned_date]         DATE           NOT NULL,
        [actual_date]          DATE           NOT NULL,
        [outcome]              NVARCHAR(32)   NOT NULL,
        [payload_mass_kg]      FLOAT          NOT NULL,
        [weather_delay_min]    INT                NULL,
        [scrub_count]          INT            NOT NULL,
        [booster_recovery]     NVARCHAR(32)   NOT NULL,
        [insurance_value_musd] DECIMAL(18, 2)     NULL,
        CONSTRAINT PK_launches PRIMARY KEY CLUSTERED ([launch_id]),
        CONSTRAINT FK_launches_vehicles FOREIGN KEY ([vehicle_id]) REFERENCES dbo.vehicles ([vehicle_id]),
        CONSTRAINT FK_launches_pads FOREIGN KEY ([pad_id]) REFERENCES dbo.pads ([pad_id]),
        CONSTRAINT CK_launches_outcome CHECK ([outcome] IN (N'success', N'partial_failure', N'failure')),
        CONSTRAINT CK_launches_orbit CHECK ([orbit] IN (N'LEO', N'SSO', N'GTO', N'MEO', N'HEO', N'ISS', N'TLI')),
        CONSTRAINT CK_launches_booster_recovery CHECK ([booster_recovery] IN (N'droneship', N'RTLS', N'expended')),
        CONSTRAINT CK_launches_scrub_count CHECK ([scrub_count] BETWEEN 0 AND 3),
        CONSTRAINT CK_launches_dates CHECK ([planned_date] <= [actual_date])
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'050_launches.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'050_launches.sql', 1, 20260822);
GO
