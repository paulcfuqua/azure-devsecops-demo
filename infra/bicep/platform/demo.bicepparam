// L6 demo parameters. Identity values come from environment variables exported
// by the layer-06 workflow from the GitHub `demo` environment — never committed
// (CLAUDE.md hard rule 5). Empty defaults keep local builds green; the SQL
// Entra admin params must be non-empty at real deploy time (Entra-only auth).
using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus')

// Owner tag. Neutral fallback so a downstream deployment never inherits the
// original author's GitHub handle on every resource group (policy-enforced tag).
param owner = readEnvironmentVariable('MLS_OWNER', 'mls-demo')

// Entra-only SQL authentication — no SQL passwords exist anywhere.
param sqlAadAdminLogin = readEnvironmentVariable('SQL_AAD_ADMIN_LOGIN', '')
param sqlAadAdminObjectId = readEnvironmentVariable('SQL_AAD_ADMIN_OBJECT_ID', '')

// Pinned spend-profile values (any deviation is an un-gated spend change and a
// V6.1 audit failure — restated here so the manifest is explicit).
param sqlAutoPauseDelayMinutes = 60
param sqlMinCapacity = '0.5'
param sqlMaxCapacity = 2

// Pinned backup posture (F16, Task 18 — CP-9; V6.5 audit failure on drift) —
// restated here so the manifest is explicit, same convention as the spend-profile
// block above.
param sqlBackupRetentionDays = 7
param sqlBackupStorageRedundancy = 'Local'

// Flip to 'recover' via env var when replaying against a soft-deleted vault
// (kill/rebuild loop — see L6 playbook rollback note).
param keyVaultCreateMode = readEnvironmentVariable('KEY_VAULT_CREATE_MODE', 'default')

// F17 (Task 19) action group email receiver — same sponsor address as
// scripts/bootstrap/03-budget.ps1's -Email, read from the environment so it is
// never committed (CLAUDE.md hard rule 5). Empty keeps local builds green.
param alertNotificationEmail = readEnvironmentVariable('MLS_ALERT_EMAIL', '')
