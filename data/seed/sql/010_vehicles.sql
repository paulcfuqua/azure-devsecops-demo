/* =============================================================================
   010_vehicles.sql - REFERENCE plane (seeded once, read-mostly, FK target).

   Source of truth: data/generators/build.py :: gen_vehicles (static, 12 rows).
   `gto_capacity_kg` and `last_flight_year` are STRUCTURALLY nullable - small
   vehicles have no GTO capacity and an active vehicle has no last flight year.
   Neither comes from the NULL_RATE messiness knob.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'vehicles' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.vehicles
    (
        [vehicle_id]        NVARCHAR(16) NOT NULL,
        [name]              NVARCHAR(64) NOT NULL,
        [vehicle_class]     NVARCHAR(16) NOT NULL,
        [fleet_group]       NVARCHAR(64) NOT NULL,
        [stages]            INT          NOT NULL,
        [reusable]          BIT          NOT NULL,
        [leo_capacity_kg]   INT          NOT NULL,
        [gto_capacity_kg]   INT              NULL,
        [height_m]          FLOAT        NOT NULL,
        [first_flight_year] INT          NOT NULL,
        [last_flight_year]  INT              NULL,
        [status]            NVARCHAR(16) NOT NULL,
        CONSTRAINT PK_vehicles PRIMARY KEY CLUSTERED ([vehicle_id]),
        CONSTRAINT CK_vehicles_vehicle_class CHECK ([vehicle_class] IN (N'small', N'medium', N'heavy')),
        CONSTRAINT CK_vehicles_status CHECK ([status] IN (N'active', N'retired'))
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'010_vehicles.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'010_vehicles.sql', 1, 20260822);
GO
