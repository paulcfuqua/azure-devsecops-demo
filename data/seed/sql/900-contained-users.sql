/* =============================================================================
   900-contained-users.sql — grants the data-api workload identity a contained
   database user on the operational database (F13, Task 12:
   compliance/findings/2026-08-26-prepublication-review.md#f13).

   Target: Azure SQL serverless (L6, mls-ops-demo-sql / mls-ops-demo-db), Entra-
   only authentication (platform/main.bicep's sqlServer module sets
   azureADOnlyAuthentication: true — there is no SQL login to fall back on).
   `data-api` reads this database in cloud mode with no grant anywhere
   expressing that access before this file; without it, as soon as G0 item C9
   sets fabricSqlEndpoint (apps/main.bicep's dataApiMode resolves to 'cloud'),
   every query 403s — the exact "dated failure" F13 describes.

   Principal name is NOT parameterised: like every other file in this
   directory, this script is static text, not a template. 'mls-data-api-demo-
   id' is naming.bicep's userAssignedIdentityName('mls', 'data-api', 'demo') —
   the company prefix and env this whole repo defaults to
   (naming.bicep:20,24). If either default ever changes for a real deployment,
   this literal needs to change with it; nothing here derives it automatically
   because nothing in this directory derives anything automatically.

   NOT BATCH-FATAL, DELIBERATELY (F20, filed alongside this finding rather
   than folded into it — compliance/findings/2026-08-26-prepublication-
   review.md#f20): data/seed/sql/sql-seed.psm1's Install-SeedSchema applies
   every *.sql file in this directory unconditionally, with no error
   tolerance, as ONE step of the L6 workflow (layer-06-platform.yml) — which
   runs BEFORE L7 creates the data-api identity this script names. On that
   first pass CREATE USER ... FROM EXTERNAL PROVIDER cannot resolve the
   principal in Entra ID yet and would THROW (error 33131 or similar), and
   because Install-SeedSchema has no per-statement recovery, an uncaught
   throw here would abort DDL application before any of the ten operational
   tables load — turning "one grant is pending" into "L6's entire SQL seed
   failed". The TRY/CATCH below turns that into a loud, non-terminating
   warning (RAISERROR severity 10 — below the batch-aborting threshold)
   instead: the first pass logs "pending L7" and the schema seed completes
   normally. Nothing currently RE-RUNS `seed.ps1 -Target sql` after L7 (F20
   is exactly that gap) — running it again once the identity exists is what
   actually completes this grant; until then, the statement below is written
   and idempotent, not yet applied.

   Idempotent: guarded by sys.database_principals so a successful re-run
   after L7 is a no-op, matching every other file in this directory.
   Batches are separated by a line containing only GO (data/seed/seed.ps1
   splits on that itself — Split-SqlBatch), same as every sibling file.
   ============================================================================= */

BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'mls-data-api-demo-id')
    BEGIN
        CREATE USER [mls-data-api-demo-id] FROM EXTERNAL PROVIDER;
    END
END TRY
BEGIN CATCH
    RAISERROR (
        'Could not create contained user ''mls-data-api-demo-id'' (%s). Expected before L7 provisions the identity in Microsoft Entra ID — re-run data/seed/seed.ps1 -Target sql after L7 completes to finish this grant (see F20).',
        10, 1, ERROR_MESSAGE()) WITH NOWAIT;
END CATCH;
GO

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'mls-data-api-demo-id')
       AND NOT EXISTS (
           SELECT 1
           FROM sys.database_role_members AS rm
           JOIN sys.database_principals AS r ON r.[principal_id] = rm.[role_principal_id]
           JOIN sys.database_principals AS m ON m.[principal_id] = rm.[member_principal_id]
           WHERE r.[name] = N'db_datareader' AND m.[name] = N'mls-data-api-demo-id'
       )
    BEGIN
        ALTER ROLE db_datareader ADD MEMBER [mls-data-api-demo-id];
    END
END TRY
BEGIN CATCH
    RAISERROR (
        'Could not add ''mls-data-api-demo-id'' to db_datareader (%s). Expected before the user above exists — re-run data/seed/seed.ps1 -Target sql after L7 completes (see F20).',
        10, 1, ERROR_MESSAGE()) WITH NOWAIT;
END CATCH;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'900-contained-users.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'900-contained-users.sql', 1, 20260822);
GO
