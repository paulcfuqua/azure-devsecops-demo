/* =============================================================================
   100_findings_history.sql - ANALYTICAL MIRROR. Feeds the control tower's Sec
   tab (L7) and the security-posture questions at L8. Synthetic history only -
   the live findings come from CodeQL / Dependabot / Trivy / ZAP / Defender at
   L9-L10; this table is what makes a trend chart possible on day one.

   Source of truth: data/generators/build.py :: gen_findings (420 rows, opened
   2025-01-01 .. 2026-06-01).

   No CHECK ties `cve_id` to source: the generator only issues CVE ids for
   Dependabot and Trivy findings today, but that is a data-shape choice, not a
   contract, and encoding it here would turn a generator tweak into a load
   failure. `status` and `severity` ARE constrained - apps/mcp-tools publishes
   both enumerations in its tool description, so they are contract.
   ============================================================================= */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = N'findings_history' AND [schema_id] = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE dbo.findings_history
    (
        [finding_id]  NVARCHAR(16)  NOT NULL,
        [source]      NVARCHAR(32)  NOT NULL,
        [severity]    NVARCHAR(16)  NOT NULL,
        [title]       NVARCHAR(160) NOT NULL,
        [component]   NVARCHAR(128) NOT NULL,
        [cve_id]      NVARCHAR(24)      NULL,
        [opened_date] DATE          NOT NULL,
        [closed_date] DATE              NULL,
        [status]      NVARCHAR(24)  NOT NULL,
        [assignee]    NVARCHAR(64)  NOT NULL,
        [sla_days]    INT           NOT NULL,
        CONSTRAINT PK_findings_history PRIMARY KEY CLUSTERED ([finding_id]),
        CONSTRAINT CK_findings_history_severity CHECK ([severity] IN (N'critical', N'high', N'medium', N'low')),
        CONSTRAINT CK_findings_history_status CHECK ([status] IN (N'open', N'resolved', N'risk_accepted')),
        CONSTRAINT CK_findings_history_dates CHECK ([closed_date] IS NULL OR [closed_date] >= [opened_date]),
        CONSTRAINT CK_findings_history_sla_days CHECK ([sla_days] > 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.schema_version WHERE [script_name] = N'100_findings_history.sql')
    INSERT dbo.schema_version ([script_name], [schema_version], [generator_seed])
    VALUES (N'100_findings_history.sql', 1, 20260822);
GO
