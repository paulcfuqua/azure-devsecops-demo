# Track H — Local Toolchain Report (Phase P)

Date: 2026-08-22 · Host: Windows 11 Home (ARM64) · Installed via winget/PSGallery,
verified from a fresh shell.

| Tool | Version | Notes |
|---|---|---|
| Bicep CLI | 0.46.1 | winget portable (ARM64 build); on user PATH |
| Azure CLI | 2.89.1 | x64 MSI; **not logged in — no cloud calls until G0** |
| PowerShell 7 | 7.6.5 | user-scope install |
| Microsoft.Graph.* (Authentication, Applications, Users, Groups, Identity.SignIns, Identity.DirectoryManagement) | 2.39.0 | CurrentUser scope |
| ExchangeOnlineManagement | 3.10.1 | CurrentUser scope |
| Pester | 6.1.0 | v5-syntax compatible; built-in 3.4.0 still present but shadowed by version resolution |
| PSScriptAnalyzer | 1.25.0 | CurrentUser scope |
| Pre-existing | git 2.48.1, Node 24.16, Python 3.14.3, gh (authenticated), winget | Docker absent by design — container builds happen in CI |

Caveats for agents this session: shells spawned before the installs inherit a stale
PATH — prepend `[Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
[Environment]::GetEnvironmentVariable('Path','User')` (or restart the session) before
calling `az`/`bicep`.
