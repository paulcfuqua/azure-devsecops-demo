/* =============================================================================
   900-contained-users.sql — the workload contained-user grant USED to live here,
   and could never survive a rebuild. It now lives in Set-SeedWorkloadUser
   (data/seed/sql/sql-seed.psm1), called by data/seed/seed.ps1 with the identity's
   clientId. This file keeps its schema_version row and this explanation.

   WHAT WAS HERE, AND WHY IT HAD TO GO (F172).

   The statement was:

       CREATE USER [mls-data-api-demo-id] FROM EXTERNAL PROVIDER;

   FROM EXTERNAL PROVIDER makes the SQL engine resolve the principal in Microsoft
   Graph. An application cannot impersonate another application, so when CI runs it
   as a service principal the engine falls back to THE SQL SERVER'S OWN managed
   identity, which must therefore hold directory read — the Entra "Directory
   Readers" role (F112). That assignment was a G0 step, documented as "One
   assignment, once per tenant".

   IT IS NOT ONCE PER TENANT. L6 creates the server in mls-rg-data; teardown deletes
   that resource group; the server's SYSTEM-ASSIGNED identity dies with it and comes
   back under the same NAME with a NEW principal id, and Entra removes the dangling
   role assignment along with the deleted service principal. So the grant silently
   stops existing the first time the estate is rebuilt — which is the one thing this
   demo exists to do.

   Read on 2026-09-03, after the re-baseline rebuild: the directory audit log records
   `mls-ops-demo-sql` added to Directory Readers at 2026-09-01T12:23:23Z for a service
   principal that no longer exists; the current server identity holds zero directory
   role assignments; the Directory Readers role has zero members. Four layers later
   data-api answered `Login failed for user '<token-identified principal>'` on every
   SQL-backed route and L7's V7.6 went red.

   TWO THINGS THIS FILE COULD NOT DO, WHICH IS WHY THE GRANT IS NOT A .sql FILE.

   1. The replacement supplies the SID explicitly — for an application, that SID is
      its APPLICATION (CLIENT) ID — so nothing asks Graph, no server identity is
      involved, and no tenant-level privilege is needed anywhere. That value is
      discovered from Azure at deploy time and cannot be written into static text.
      Everything in this directory is static text by design (see README.md); a
      templated .sql file would be a worse answer than a parameter.

   2. This file's TRY/CATCH turned a real failure into a severity-10 warning, because
      it had to: Install-SeedSchema applies every file here unconditionally, including
      during L6, which runs BEFORE L7 creates the identity. A grant that must be
      allowed to fail cannot also be the thing that reports whether it worked.
      Set-SeedWorkloadUser is called only when a caller supplies an identity, so it is
      allowed to throw — and it reads the user and its SID back out of
      sys.database_principals before saying anything (F112: verify, do not announce).

   Nothing here creates a principal any more, so there is no ordering constraint and
   no guard to get wrong. The schema_version row is retained so an existing database's
   history is unbroken; the version is bumped to 2 to record that this file changed
   meaning rather than merely being edited.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'900-contained-users.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'900-contained-users.sql', 2, 20260822);
GO
