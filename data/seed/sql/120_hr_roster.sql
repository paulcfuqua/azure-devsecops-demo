/* =============================================================================
   120_hr_roster.sql - REFERENCE. The column-sensitivity table: a single row
   mixes ordinary business data with restricted attributes.

   `start_date`, `department`, `job_family` and `tenure_years` are ordinary.
   `salary_usd`, `bonus_target_pct` and `performance_band` are RESTRICTED and
   are denied to the standard role by column-level security applied at L4
   (infra/fabric/protect-tables.ps1). Nothing in THIS file enforces that: a
   DDL grant is not a security policy, and the enforcement lives with the
   protection script so a rebuild reproduces it in one place.

   The mix within one row is the point. If the sensitive columns lived in a
   separate table the demo would be a join rather than a denial, and
   column-level security would have nothing to discriminate within.

   Source of truth: data/generators/build.py :: gen_hr_roster (240 rows,
   start dates 2015-01-05 .. 2026-05-29).

   All people here are FICTIONAL - names are composed from fixed pools in
   generators/config.py, never sampled from any real roster (CLAUDE.md hard
   rule 4: no real person's PII).

   `manager_id` is a self-reference and is deliberately NOT a foreign key: the
   first 24 rows are managers and carry NULL, so a self-FK would be satisfiable
   but would add a load-order constraint on a single-file insert for no
   integrity gain. The generator asserts every manager_id resolves.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'hr_roster' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.hr_roster
    (
        [employee_id]      NVARCHAR(16)  NOT NULL,
        [display_name]     NVARCHAR(96)  NOT NULL,
        [department]       NVARCHAR(48)  NOT NULL,
        [job_family]       NVARCHAR(32)  NOT NULL,
        [location]         NVARCHAR(32)  NOT NULL,
        [start_date]       DATE          NOT NULL,
        [tenure_years]     DECIMAL(5, 1) NOT NULL,
        [manager_id]       NVARCHAR(16)      NULL,
        [employment_type]  NVARCHAR(24)  NOT NULL,
        [salary_usd]       INT           NOT NULL,
        [bonus_target_pct] INT           NOT NULL,
        [performance_band] NVARCHAR(24)  NOT NULL,
        CONSTRAINT PK_hr_roster PRIMARY KEY CLUSTERED ([employee_id]),
        CONSTRAINT CK_hr_roster_employment_type CHECK ([employment_type] IN (N'Full-time', N'Contract', N'Intern')),
        CONSTRAINT CK_hr_roster_performance_band CHECK ([performance_band] IN (N'Exceeds', N'Meets', N'Developing')),
        CONSTRAINT CK_hr_roster_salary CHECK ([salary_usd] > 0),
        CONSTRAINT CK_hr_roster_bonus CHECK ([bonus_target_pct] BETWEEN 0 AND 100),
        CONSTRAINT CK_hr_roster_tenure CHECK ([tenure_years] >= 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'120_hr_roster.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'120_hr_roster.sql', 1, 20260822);
GO
