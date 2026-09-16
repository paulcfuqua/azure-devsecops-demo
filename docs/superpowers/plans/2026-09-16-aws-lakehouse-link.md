# Cross-cloud lakehouse link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent answers questions about real launch-provider data in an AWS Athena lakehouse, over a live link, with no data copied into Azure and no stored AWS credentials.

**Architecture:** A third implementation of the existing `LakehouseSqlBackend` interface, reached through a second MCP tool that advertises the Trino dialect. The container gets an Entra token for a dedicated audience, exchanges it for short-lived AWS credentials via `AssumeRoleWithWebIdentity`, and queries Athena. The AWS trust anchor is created by the sponsor from scripts authored here.

**Tech Stack:** TypeScript (Node 22, ESM), `@aws-sdk/client-athena`, `@aws-sdk/credential-providers`, vitest, Bicep (AVM), Pester 5 (PowerShell 7), bash.

**Spec:** [`docs/superpowers/specs/2026-09-16-aws-lakehouse-link-design.md`](../specs/2026-09-16-aws-lakehouse-link-design.md)

## Global Constraints

- **Hard deadline:** the estate shuts down ~**2026-09-27**. Evidence capture must precede it; only the outbrief's prose may follow.
- **Sponsor round-trip:** AWS writes are performed by the sponsor running scripts authored here. **Task 3 is the hand-off point** — everything after it is Azure-side and must not block on it.
- **No new long-lived secret.** The repo holds six CI secrets and three Key Vault secrets, each with a written reason. This design adds none, and a test enforces it.
- **A constant naming something in another system is resolved against that system**, never written from memory. This includes the Entra issuer, the audience, the managed identity object id, and **Trino's `day_of_week` numbering**.
- **File content is written with a file tool, never a shell heredoc.** Verify bytes, not rendering.
- **CI targets `ubuntu-latest` (bash). Local orchestration targets PowerShell 7.** Never assume Windows PowerShell 5.1.
- **Naming:** `mls-<app|role>-<env>-<type>` from `infra/bicep/naming.bicep`. Never hardcode `mls`; use `MLS_COMPANY_PREFIX` / `MLS_ENV_SEGMENT`.
- **PSScriptAnalyzer at Error+Warning must report 0** across `scripts`, `infra`, `verification`, `.github`.
- **No `Set-StrictMode -Off` in any `*.Tests.ps1`**, and no test that supplies the answer it is checking.
- **Response shapes are a contract.** A cloud adapter returns byte-identical shapes to its local counterpart; `tests/shape-parity.test.ts` enforces it.

---

### Task 1: The AWS-facing Entra audience

The token's `aud` claim is what the AWS OIDC provider validates. Entra will only mint a token for a resource that exists, so an app registration with an Application ID URI must exist before anything else works.

**Files:**
- Modify: `infra/entra/manifest.json`
- Test: `verification/tests/failure-classes.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: an app registration whose `identifierUris[0]` is `api://${prefix}-aws-athena-${env}`. Task 3 needs this exact string as the AWS provider's client ID; Task 6 needs it as the token scope.

- [ ] **Step 1: Write the failing test**

Add to `verification/tests/failure-classes.Tests.ps1`:

```powershell
Describe 'AWS audience is tokenised, not hardcoded' {
    It 'declares the AWS athena audience with prefix and env tokens' {
        $manifest = Get-Content "$PSScriptRoot/../../infra/entra/manifest.json" -Raw | ConvertFrom-Json
        $app = $manifest.applications | Where-Object { $_.key -eq 'aws-athena' }
        $app | Should -Not -BeNullOrEmpty -Because 'Task 1 declares the AWS-facing audience'
        $app.identifierUris[0] | Should -BeExactly 'api://${prefix}-aws-athena-${env}'
    }
    It 'never hardcodes the mls prefix in the AWS audience' {
        $raw = Get-Content "$PSScriptRoot/../../infra/entra/manifest.json" -Raw
        $raw | Should -Not -Match 'api://mls-aws-athena'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/failure-classes.Tests.ps1 -Output Detailed"`
Expected: FAIL — "Task 1 declares the AWS-facing audience"

- [ ] **Step 3: Read the manifest's existing shape before editing**

Run: `sed -n '1,60p' infra/entra/manifest.json`

Match the existing entries' key names exactly. Do not invent a schema — the manifest has readers in `infra/entra/` and `verification/layer-03-audit.ps1`.

- [ ] **Step 4: Add the application entry**

Add to the `applications` array, following the shape the file already uses:

```json
{
  "key": "aws-athena",
  "displayName": "${prefix}-aws-athena-${env}",
  "identifierUris": ["api://${prefix}-aws-athena-${env}"],
  "signInAudience": "AzureADMyOrg",
  "notes": "Audience only. Holds no credential and no API permissions: it exists so Entra will mint a token whose aud claim the AWS IAM OIDC provider validates. See docs/superpowers/specs/2026-09-16-aws-lakehouse-link-design.md section 2.1."
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -c "Invoke-Pester verification/tests/failure-classes.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 6: Deploy L3 and read back the resolved URI**

Run: `gh workflow run layer-03-entra.yml && sleep 60 && gh run list --workflow=layer-03-entra.yml --limit 1`

Then resolve the real value — **do not write it down from the template**:

```bash
az ad app list --filter "startswith(displayName,'mls-aws-athena')" \
  --query "[].{appId:appId,uri:identifierUris[0]}" -o tsv
```

Record both values. Task 3 needs them.

- [ ] **Step 7: Commit**

```bash
git add infra/entra/manifest.json verification/tests/failure-classes.Tests.ps1
git commit -m "feat(L3): an Entra audience for the AWS trust policy to validate"
```

---

### Task 2: A durable identity outside the teardown blast radius

**Files:**
- Create: `infra/bicep/modules/aws-identity.bicep`
- Modify: `infra/bicep/main.bicep`
- Test: `verification/tests/failure-classes.Tests.ps1`

**Interfaces:**
- Consumes: `naming.bicep`'s prefix/env parameters.
- Produces: a user-assigned managed identity named `<prefix>-aws-<env>-id` in resource group `<prefix>-rg-identity`, and its **principal id**, which Task 3 uses as the trust policy's `sub`.

- [ ] **Step 1: Write the failing test**

The lesson is BLOCKER-E's: a resource whose survival matters must not sit in a group the teardown deletes by name. Add to `verification/tests/failure-classes.Tests.ps1`:

```powershell
Describe 'AWS trust identity survives teardown' {
    It 'lives in a resource group that teardown does not delete' {
        $naming = Get-Content "$PSScriptRoot/../../infra/bicep/naming.bicep" -Raw
        # Derive the four deleted groups from naming.bicep rather than restating them,
        # so a rebrand cannot move the identity back inside the blast radius.
        $deleted = [regex]::Matches($naming, "rg-(platform|apps|data|ops)") |
            ForEach-Object { $_.Value } | Sort-Object -Unique
        $module = Get-Content "$PSScriptRoot/../../infra/bicep/modules/aws-identity.bicep" -Raw
        foreach ($g in $deleted) {
            $module | Should -Not -Match "rg-identity'?\s*==\s*'?$g"
            $module | Should -Not -Match "'\S*$g'"
        }
        $module | Should -Match 'rg-identity'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/failure-classes.Tests.ps1 -Output Detailed"`
Expected: FAIL — the module file does not exist

- [ ] **Step 3: Create the module**

`infra/bicep/modules/aws-identity.bicep`:

```bicep
// The identity the AWS IAM role trusts, by principal id.
//
// IT LIVES OUTSIDE THE FOUR RESOURCE GROUPS TEARDOWN DELETES, deliberately.
// A managed identity's principal id is destroyed and reissued on every teardown
// -- the 2026-09-03 rebuild moved data-api's from 3dadafd7 to ba91c8ea. An AWS
// trust policy pinned to one would work perfectly, survive nothing, and fail on
// the next rebuild with an AccessDenied that looks like an AWS problem.
//
// Same move, same reason, as the Fabric capacity's rg-fabric default (BLOCKER-E).
targetScope = 'subscription'

param prefix string
param envSegment string
param location string

var identityRg = '${prefix}-rg-identity'

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'aws-identity'
  scope: resourceGroup(identityRg)
  params: {
    name: '${prefix}-aws-${envSegment}-id'
    location: location
  }
}

output principalId string = identity.outputs.principalId
output clientId string = identity.outputs.clientId
output resourceGroupName string = identityRg
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -c "Invoke-Pester verification/tests/failure-classes.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Wire it into main.bicep and assign it to the MCP container app**

Read `infra/bicep/main.bicep` first and follow its existing module-invocation pattern. The MCP container app must list this identity in its `userAssignedIdentities`, because the token in Task 6 is requested from it specifically, not from whatever identity happens to be default.

- [ ] **Step 6: Deploy and resolve the principal id**

```bash
az group create -n mls-rg-identity -l centralus \
  --tags env=demo app=platform costCenter=demo owner=sponsor \
         dataClassification=internal managedBy=iac
gh workflow run layer-06-platform.yml
```

Then read the real value back:

```bash
az identity show -g mls-rg-identity -n mls-aws-demo-id \
  --query "{principalId:principalId,clientId:clientId}" -o tsv
```

Record the principal id. **Task 3's trust policy needs it and it must be read, not predicted.**

- [ ] **Step 7: Commit**

```bash
git add infra/bicep/modules/aws-identity.bicep infra/bicep/main.bicep verification/tests/failure-classes.Tests.ps1
git commit -m "infra(L6): the AWS trust identity, outside the teardown blast radius"
```

---

### Task 3: AWS scripts — THE SPONSOR HAND-OFF

**This is the critical-path hand-off. Complete it, hand it over, and continue to Task 4 immediately. Do not wait for the sponsor to run it.**

**Files:**
- Create: `scripts/aws/01-oidc-provider.sh`
- Create: `scripts/aws/02-athena-role.sh`
- Create: `scripts/aws/03-verify.sh`
- Create: `scripts/aws/teardown.sh`
- Create: `scripts/aws/README.md`

**Interfaces:**
- Consumes: the audience URI from Task 1, the principal id from Task 2.
- Produces: an IAM role ARN, exported as `MLS_AWS_ROLE_ARN` for Task 6.

- [ ] **Step 1: Resolve the Entra issuer from the live tenant**

**Do not write this from memory.** Resolve it:

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)
curl -s "https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration" \
  | python -c "import json,sys; print(json.load(sys.stdin)['issuer'])"
```

The printed value is the issuer. Use exactly it.

- [ ] **Step 2: Write `scripts/aws/01-oidc-provider.sh`**

```bash
#!/usr/bin/env bash
# Create the IAM OIDC identity provider that trusts this Entra tenant.
#
# SPONSOR-RUN. Agents author this file; the sponsor executes it. AWS writes are
# outside the 2026-08-29 amendment, which covers Azure, Entra, Fabric and GitHub.
#
# The issuer is RESOLVED from the tenant's discovery document, never typed: a
# trust policy that is one character wrong fails as AccessDenied with no
# indication of which field was rejected.
set -euo pipefail

: "${MLS_TENANT_ID:?set MLS_TENANT_ID (az account show --query tenantId -o tsv)}"
: "${MLS_AWS_AUDIENCE:?set MLS_AWS_AUDIENCE (the api:// URI from Task 1)}"

ISSUER=$(curl -sf "https://login.microsoftonline.com/${MLS_TENANT_ID}/v2.0/.well-known/openid-configuration" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['issuer'])")
ISSUER_HOST="${ISSUER#https://}"

echo "resolved issuer: ${ISSUER}"
echo "audience:        ${MLS_AWS_AUDIENCE}"

EXISTING=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${ISSUER_HOST%%/*}')].Arn" --output text)

if [ -n "${EXISTING}" ]; then
  echo "provider exists: ${EXISTING}"
  aws iam add-client-id-to-open-id-connect-provider \
    --open-id-connect-provider-arn "${EXISTING}" \
    --client-id "${MLS_AWS_AUDIENCE}" 2>/dev/null || echo "audience already registered"
  PROVIDER_ARN="${EXISTING}"
else
  PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
    --url "${ISSUER}" \
    --client-id-list "${MLS_AWS_AUDIENCE}" \
    --query OpenIDConnectProviderArn --output text)
  echo "created: ${PROVIDER_ARN}"
fi

# READ IT BACK. A create that returned an ARN is not evidence the audience landed.
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" \
  --query "{url:Url,audiences:ClientIDList}" --output json

echo "export MLS_AWS_PROVIDER_ARN=${PROVIDER_ARN}"
```

- [ ] **Step 3: Write `scripts/aws/02-athena-role.sh`**

```bash
#!/usr/bin/env bash
# Create the read-only Athena role the Azure container assumes.
#
# The trust policy conditions on BOTH aud and sub. aud alone would let any
# workload in the tenant holding a token for this audience assume the role.
set -euo pipefail

: "${MLS_TENANT_ID:?}"; : "${MLS_AWS_AUDIENCE:?}"
: "${MLS_AWS_PRINCIPAL_ID:?set to the managed identity principal id from Task 2}"
: "${MLS_AWS_PROVIDER_ARN:?from 01-oidc-provider.sh}"
: "${MLS_GLUE_DATABASE:?}"; : "${MLS_ATHENA_WORKGROUP:?}"
: "${MLS_DATA_BUCKET:?}"; : "${MLS_RESULTS_BUCKET:?}"

ISSUER_HOST=$(aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN}" \
  --query Url --output text)

cat > /tmp/mls-trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${MLS_AWS_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${ISSUER_HOST}:aud": "${MLS_AWS_AUDIENCE}",
        "${ISSUER_HOST}:sub": "${MLS_AWS_PRINCIPAL_ID}"
      }
    }
  }]
}
JSON

cat > /tmp/mls-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["athena:StartQueryExecution","athena:GetQueryExecution",
                 "athena:GetQueryResults","athena:StopQueryExecution",
                 "athena:GetWorkGroup"],
      "Resource": "arn:aws:athena:*:*:workgroup/${MLS_ATHENA_WORKGROUP}" },
    { "Effect": "Allow",
      "Action": ["glue:GetDatabase","glue:GetDatabases","glue:GetTable",
                 "glue:GetTables","glue:GetPartition","glue:GetPartitions"],
      "Resource": ["arn:aws:glue:*:*:catalog",
                   "arn:aws:glue:*:*:database/${MLS_GLUE_DATABASE}",
                   "arn:aws:glue:*:*:table/${MLS_GLUE_DATABASE}/*"] },
    { "Effect": "Allow",
      "Action": ["s3:GetObject","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${MLS_DATA_BUCKET}",
                   "arn:aws:s3:::${MLS_DATA_BUCKET}/*"] },
    { "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${MLS_RESULTS_BUCKET}",
                   "arn:aws:s3:::${MLS_RESULTS_BUCKET}/*"] }
  ]
}
JSON

ROLE_ARN=$(aws iam create-role --role-name mls-athena-reader \
  --assume-role-policy-document file:///tmp/mls-trust.json \
  --description "Read-only Athena access for the Azure-hosted MLS agent" \
  --query Role.Arn --output text 2>/dev/null \
  || aws iam get-role --role-name mls-athena-reader --query Role.Arn --output text)

aws iam put-role-policy --role-name mls-athena-reader \
  --policy-name mls-athena-read --policy-document file:///tmp/mls-policy.json

rm -f /tmp/mls-trust.json /tmp/mls-policy.json
echo "export MLS_AWS_ROLE_ARN=${ROLE_ARN}"
```

- [ ] **Step 4: Write `scripts/aws/03-verify.sh`**

```bash
#!/usr/bin/env bash
# Read back what was created. A create that exited zero is not evidence.
set -euo pipefail
: "${MLS_AWS_PROVIDER_ARN:?}"

echo "--- provider ---"
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN}" \
  --query "{url:Url,audiences:ClientIDList}" --output json

echo "--- role trust policy ---"
aws iam get-role --role-name mls-athena-reader \
  --query "Role.AssumeRolePolicyDocument" --output json

echo "--- attached inline policy ---"
aws iam get-role-policy --role-name mls-athena-reader \
  --policy-name mls-athena-read --query PolicyDocument --output json

echo "--- workgroup reachable, and capped ---"
# The bytes-scanned cutoff is the spend control (spec section 6). Athena bills per
# terabyte scanned, so an unbounded workgroup is in principle an uncapped bill
# reachable by an agent writing its own SQL.
#
# MEASURED, IT IS NOT A RISK HERE: the sponsor reports USD 0.20 of Athena spend
# across a month on this dataset. The check stays because the reasoning is right
# and the dataset could grow, but it PRINTS and does not block -- a warning that
# demands action on a twenty-cent bill is how real warnings get ignored.
aws athena get-work-group --work-group "${MLS_ATHENA_WORKGROUP:?}" \
  --query "WorkGroup.{name:Name,state:State,bytesScannedCutoff:Configuration.BytesScannedCutoffPerQuery}" \
  --output json

CUTOFF=$(aws athena get-work-group --work-group "${MLS_ATHENA_WORKGROUP}" \
  --query "WorkGroup.Configuration.BytesScannedCutoffPerQuery" --output text)
if [ "${CUTOFF}" = "None" ] || [ -z "${CUTOFF}" ]; then
  echo "WARNING: no per-query bytes-scanned cutoff on ${MLS_ATHENA_WORKGROUP}." >&2
  echo "An agent writes its own SQL; set one before pointing it at this workgroup:" >&2
  echo "  aws athena update-work-group --work-group ${MLS_ATHENA_WORKGROUP} \\" >&2
  echo "    --configuration-updates BytesScannedCutoffPerQuery=1073741824" >&2
fi
```

- [ ] **Step 5: Write `scripts/aws/teardown.sh`**

```bash
#!/usr/bin/env bash
# Remove the AWS trust anchor. G3-equivalent: this cannot be recreated by the
# Azure deploy path, so it refuses to run unattended, matching the three
# tenant-level teardowns under infra/.
set -euo pipefail

if [ "${CI:-}" = "true" ] && [ "${1:-}" != "-AllowAutomation" ]; then
  echo "refusing to run unattended in CI without -AllowAutomation" >&2
  exit 1
fi

: "${MLS_AWS_PROVIDER_ARN:?}"
aws iam delete-role-policy --role-name mls-athena-reader --policy-name mls-athena-read || true
aws iam delete-role --role-name mls-athena-reader || true
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN}" || true
echo "removed"
```

- [ ] **Step 6: Write `scripts/aws/README.md`** — the sponsor's runbook

It must state, in order: the five environment variables to set and where each value comes from; that scripts run `01` → `02` → `03`; that `03`'s output is the evidence; and that the two `export` lines printed by `01` and `02` are the values to send back. Name the expected failure explicitly: **an `AccessDenied` on first assume is normally the `sub` or `aud` condition, and `03-verify.sh` prints both so they can be compared against the Azure-side values without guessing.**

- [ ] **Step 7: Lint and verify the bytes**

```bash
shellcheck scripts/aws/*.sh
python -c "
import glob
for p in glob.glob('scripts/aws/*.sh'):
    d=open(p,encoding='utf-8').read()
    bad=[hex(ord(c)) for c in d if ord(c)<32 and c not in '\n\t']
    print(p, 'control chars:', bad or 'none')"
```

Expected: shellcheck clean, no control characters. **A backslash you cannot see is the whole failure mode.**

- [ ] **Step 8: Commit and hand off**

```bash
chmod +x scripts/aws/*.sh
git add scripts/aws/
git commit -m "feat(aws): sponsor-run scripts for the OIDC trust anchor and Athena role"
```

Then tell the sponsor the scripts are ready, give them the audience URI and principal id from Tasks 1 and 2, and **move straight to Task 4.**

---

### Task 4: The Trino dialect and its read-only gate

Pure local work. **No AWS access needed — this is what overlaps the sponsor round-trip.**

**Files:**
- Modify: `apps/mcp-tools/src/tools/sql-dialect.ts`
- Test: `apps/mcp-tools/tests/sql-dialect.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `SqlDialect` includes `"trino"`; `DIALECTS.trino` is a `DialectProfile`; `FORBIDDEN_BY_DIALECT.trino` is a `string[]`.

- [ ] **Step 1: Write the failing tests**

The gate is `assertReadOnlySingleStatement(sql, dialect)`, which **throws `SqlRejected`** — it does not return a result object. Assert on the throw.

```typescript
import { describe, it, expect } from "vitest";
import {
  DIALECTS, SqlRejected, assertReadOnlySingleStatement, scrubSql,
} from "../src/tools/sql-dialect.js";

describe("trino dialect", () => {
  it("advertises Trino idioms, not SQLite or T-SQL ones", () => {
    const idioms = DIALECTS.trino.idioms;
    expect(idioms).toContain("day_of_week");
    expect(idioms).not.toContain("strftime");
    expect(idioms).not.toContain("DATEPART");
  });

  // UNLOAD writes query results to S3. It is the one write path in Athena that
  // does not look like a write, and the common forbidden list does not cover it.
  it("refuses UNLOAD", () => {
    expect(() => assertReadOnlySingleStatement(
      "UNLOAD (SELECT * FROM launches) TO 's3://x/' WITH (format='PARQUET')", "trino",
    )).toThrow(SqlRejected);
  });

  it.each(["call", "prepare", "deallocate", "set", "reset", "use"])(
    "refuses %s", (verb) => {
      expect(() => assertReadOnlySingleStatement(`${verb} something`, "trino"))
        .toThrow(SqlRejected);
    });

  it("allows an ordinary SELECT", () => {
    expect(assertReadOnlySingleStatement(
      "SELECT provider, COUNT(*) AS n FROM launches GROUP BY provider", "trino",
    )).toContain("SELECT");
  });

  // Trino block comments DO NOT NEST -- the first */ closes, as in SQLite.
  // Tracking depth unconditionally is the bug sql-dialect.ts documents at length,
  // and a third dialect is exactly when someone reintroduces it.
  it("treats block comments as non-nesting, like SQLite", () => {
    const crafted = "SELECT 1 /* a /* b */ ; DROP TABLE launches";
    expect(scrubSql(crafted, "trino").terminated).toBe(true);
    expect(() => assertReadOnlySingleStatement(crafted, "trino")).toThrow(SqlRejected);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test --workspace apps/mcp-tools -- sql-dialect`
Expected: FAIL — `DIALECTS.trino` is undefined

- [ ] **Step 3: Extend the dialect union and profile**

In `apps/mcp-tools/src/tools/sql-dialect.ts`, change the union and add the profile:

```typescript
export type SqlDialect = "sqlite" | "tsql" | "trino";
```

```typescript
  trino: {
    id: "trino",
    displayName: "Trino dialect, AWS Athena over the Glue catalog",
    idioms:
      "This is Trino (Athena engine v3), not T-SQL or SQLite: strftime, DATEPART, " +
      "FORMAT and SELECT TOP do not exist here. For day of week use " +
      "day_of_week(actual_date), which is ISO-numbered 1=Monday .. 7=Sunday — note " +
      "this differs from the Fabric tool's 1=Sunday .. 7=Saturday, so do not carry a " +
      "weekday number from one tool to the other. day_of_week is confirmed against the " +
      "live endpoint by a session probe at first query. To bucket by month use " +
      "date_format(CAST(actual_date AS timestamp), '%Y-%m'). Use LIMIT n to take the " +
      "top n rows, and || or concat(a, b) to join strings.",
    example: "SELECT COUNT(*) AS n FROM launches WHERE outcome = 'success'",
  },
```

- [ ] **Step 4: Add the forbidden verbs**

```typescript
  // Trino/Athena: UNLOAD is the write path that hides inside a SELECT-shaped
  // statement -- it streams results to S3. CALL invokes connector procedures;
  // PREPARE/DEALLOCATE and SET/RESET are session state the agent must not touch.
  trino: [
    "unload", "call", "prepare", "deallocate",
    "set", "reset", "use",
  ],
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test --workspace apps/mcp-tools -- sql-dialect`
Expected: PASS, all cases

- [ ] **Step 6: Run the full workspace suite for regressions**

Run: `npm test --workspace apps/mcp-tools`
Expected: PASS. `SqlDialect` is a `Record` key in two places — `DIALECTS` and `FORBIDDEN_BY_DIALECT` — so TypeScript will have flagged any reader that now needs a third arm. **If it did not, that reader is typed loosely and is a finding worth recording.**

Note what else fires here: `src/tools/index.ts` carries a **load-time guard** that iterates `Object.keys(DIALECTS)` and asserts the definitions and `ALLOWED_TOOL_NAMES` agree *in every dialect*. Adding `trino` brings it into that loop immediately. It should still pass at this task — the lakehouse tool keeps its name and only its description changes — and if it does not, stop: that guard is the repository's existing defence against exactly the drift Task 7 is about to risk.

- [ ] **Step 7: Commit**

```bash
git add apps/mcp-tools/src/tools/sql-dialect.ts apps/mcp-tools/tests/sql-dialect.test.ts
git commit -m "feat(mcp): the Trino dialect, and UNLOAD is a write path"
```

---

### Task 5: The Athena backend, against a mocked engine

Still no AWS access needed. The executor seam is injected, exactly as `FabricLakehouseSqlBackend` takes a `TdsExecutor`.

**Files:**
- Create: `apps/mcp-tools/src/tools/cloud/athena-sql.ts`
- Test: `apps/mcp-tools/tests/athena-sql.test.ts`
- Modify: `apps/mcp-tools/package.json`

**Interfaces:**
- Consumes: `LakehouseSqlBackend`, `LakehouseQueryResult`, `MAX_RESULT_ROWS`, `AdapterError` from `../errors.js`.
- Produces, exactly these signatures — later tasks import them by name:

```typescript
export interface AthenaRawResult { columns: string[]; rows: unknown[][]; }
export interface AthenaExecutor { run(sql: string, maxRows: number): Promise<AthenaRawResult>; }
export interface AthenaLakehouseOptions {
  roleArn: string; audience: string; region: string;
  database: string; workgroup: string; outputLocation: string;
  tokens: TokenProvider;
  executor?: AthenaExecutor;   // injected by tests; default builds an AthenaClient
  pollTimeoutMs?: number;      // default 60_000
}
export class AthenaLakehouseSqlBackend implements LakehouseSqlBackend {
  readonly dialect: SqlDialect;            // always "trino"
  constructor(options: AthenaLakehouseOptions);
  query(sql: string): Promise<LakehouseQueryResult>;
}
```

- [ ] **Step 1: Add the dependencies**

```bash
npm install --workspace apps/mcp-tools @aws-sdk/client-athena @aws-sdk/credential-providers
```

**Then verify the root lockfile moved with it** — this repo's Dependabot PRs fail precisely because a workspace member's manifest can change while the root lockfile does not:

```bash
git status --short package-lock.json apps/mcp-tools/package.json apps/mcp-tools/package-lock.json
npm ci --dry-run >/dev/null && echo "root lockfile in sync"
```

`apps/mcp-tools` carries **two** lockfiles — its own, used by its Dockerfile, and the root workspace one. Both must move. If only one did, run `npm install` in the app directory too.

- [ ] **Step 2: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { AthenaLakehouseSqlBackend, type AthenaExecutor } from "../src/tools/cloud/athena-sql.js";

const fakeTokens = { getToken: async () => "fake.jwt.token" } as never;

function backendWith(executor: AthenaExecutor) {
  return new AthenaLakehouseSqlBackend({
    executor, roleArn: "arn:aws:iam::1:role/r", audience: "api://a", region: "us-east-1",
    database: "launch", workgroup: "wg", outputLocation: "s3://r/", tokens: fakeTokens,
  });
}

describe("AthenaLakehouseSqlBackend", () => {
  it("declares the trino dialect", () => {
    expect(backendWith({ run: async () => ({ columns: [], rows: [] }) }).dialect).toBe("trino");
  });

  it("returns the shared result shape", async () => {
    const b = backendWith({
      run: async () => ({ columns: ["provider", "n"], rows: [["SpaceX", 42]] }),
    });
    const r = await b.query("SELECT provider, COUNT(*) AS n FROM launches GROUP BY provider");
    expect(r).toEqual({ columns: ["provider", "n"], rows: [["SpaceX", 42]], rowCount: 1, truncated: false });
  });

  // The adapter asks for MAX_RESULT_ROWS + 1 so it can tell "exactly 500" from
  // "more than 500" -- the same trick the TDS adapter uses.
  it("marks truncation when the engine returns one more than the cap", async () => {
    const rows = Array.from({ length: 501 }, (_, i) => [i]);
    const r = await backendWith({ run: async () => ({ columns: ["i"], rows }) })
      .query("SELECT i FROM t");
    expect(r.rowCount).toBe(500);
    expect(r.truncated).toBe(true);
    expect(r.rows).toHaveLength(500);
  });

  it("refuses a write statement before reaching the engine", async () => {
    let called = false;
    const b = backendWith({ run: async () => { called = true; return { columns: [], rows: [] }; } });
    await expect(b.query("UNLOAD (SELECT 1) TO 's3://x/'")).rejects.toThrow();
    expect(called).toBe(false);
  });

  it("surfaces an engine failure as an upstream AdapterError, not a crash", async () => {
    const b = backendWith({ run: async () => { throw new Error("SYNTAX_ERROR line 1:8"); } });
    await expect(b.query("SELECT bogus FROM t")).rejects.toMatchObject({ kind: "upstream" });
  });

  it("times out rather than polling forever", async () => {
    const b = new AthenaLakehouseSqlBackend({
      executor: { run: () => new Promise(() => {}) },
      roleArn: "arn:aws:iam::1:role/r", audience: "api://a", region: "us-east-1",
      database: "launch", workgroup: "wg", outputLocation: "s3://r/", tokens: fakeTokens,
      pollTimeoutMs: 20,
    });
    await expect(b.query("SELECT 1")).rejects.toMatchObject({ kind: "timeout" });
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test --workspace apps/mcp-tools -- athena-sql`
Expected: FAIL — module not found

- [ ] **Step 4: Implement the backend**

Write `apps/mcp-tools/src/tools/cloud/athena-sql.ts`. Read `fabric-sql.ts` first and mirror its structure: an injectable executor, a `query()` that gates on `assertReadOnlySingleStatement(sql, "trino")` before touching the engine, `AdapterError` for every failure path, and the `MAX_RESULT_ROWS + 1` truncation probe. The default executor builds an `AthenaClient` whose credentials come from `fromWebToken({ roleArn, webIdentityToken: await tokens.getToken(audience + "/.default") })`.

The Athena cycle is `StartQueryExecution` → poll `GetQueryExecution` until `Status.State` leaves `QUEUED`/`RUNNING` → `GetQueryResults`. **`GetQueryResults`' first row is the column header, not data**, so request `MaxResults: MAX_RESULT_ROWS + 2` and drop row zero. Column names come from `ResultSet.ResultSetMetadata.ColumnInfo[].Name`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test --workspace apps/mcp-tools -- athena-sql`
Expected: PASS, all six

- [ ] **Step 6: Extend shape parity to the third backend**

Add the Athena backend to `apps/mcp-tools/tests/shape-parity.test.ts` using the file's existing shared shape function. Do not write a second shape assertion — the file's whole point is that one function judges every backend.

Run: `npm test --workspace apps/mcp-tools -- shape-parity`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/mcp-tools/src/tools/cloud/athena-sql.ts apps/mcp-tools/tests/ apps/mcp-tools/package.json package-lock.json apps/mcp-tools/package-lock.json
git commit -m "feat(mcp): Athena lakehouse backend behind an injectable executor"
```

---

### Task 6: Configuration and the token exchange

**Files:**
- Modify: `apps/mcp-tools/src/config.ts`
- Modify: `apps/mcp-tools/src/tools/cloud/index.ts`
- Modify: `apps/mcp-tools/src/tools/backends.ts`
- Test: `apps/mcp-tools/tests/config.test.ts`

**Interfaces:**
- Consumes: `AthenaLakehouseOptions` from Task 5.
- Produces: `McpToolsConfig.aws?: { roleArn, audience, region, database, workgroup, outputLocation }` — present only when all six env vars are set.
- Produces: `Backends.awsLakehouseSql?: LakehouseSqlBackend` — **added by pre-flight ruling.** The `Backends` interface at `backends.ts:264` is the only route a backend has into `ToolRegistry`, and the plan's first draft named no task that widened it. Add the optional field and populate it from the cloud factory when `config.aws` is present; `createLocalBackends()` leaves it undefined.

- [ ] **Step 1: Write the failing test**

The lesson is F125's: **an absent GitHub variable is the empty string, not an error**, so a config that treats `""` as configured produces a backend that fails at first query instead of at startup.

```typescript
import { describe, it, expect } from "vitest";
import { loadConfig } from "../src/config.js";

const full = {
  MLS_AWS_ROLE_ARN: "arn:aws:iam::1:role/r", MLS_AWS_AUDIENCE: "api://a",
  MLS_AWS_REGION: "us-east-1", MLS_GLUE_DATABASE: "launch",
  MLS_ATHENA_WORKGROUP: "wg", MLS_ATHENA_OUTPUT: "s3://r/",
};

describe("aws config", () => {
  it("is present when all six are set", () => {
    expect(loadConfig(full as never).aws?.roleArn).toBe("arn:aws:iam::1:role/r");
  });

  it("is absent when none are set", () => {
    expect(loadConfig({} as never).aws).toBeUndefined();
  });

  it.each(Object.keys(full))("treats an EMPTY %s as unconfigured, not as configured", (k) => {
    expect(() => loadConfig({ ...full, [k]: "" } as never)).toThrow(/MLS_AWS|MLS_GLUE|MLS_ATHENA/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test --workspace apps/mcp-tools -- config`
Expected: FAIL — `.aws` is undefined

- [ ] **Step 3: Implement in `loadConfig`**

Follow the file's existing pattern. Partial configuration must **throw with the missing names listed**, never silently disable the tool: a tool that quietly vanishes is indistinguishable from one that was never built, which is how the control tower shipped without `MLS_DIRECTLINE_TOKEN_URL` for an hour after it was set (F124).

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test --workspace apps/mcp-tools -- config`
Expected: PASS

- [ ] **Step 5: Set the six environment variables**

```bash
for kv in MLS_AWS_ROLE_ARN=... MLS_AWS_AUDIENCE=... MLS_AWS_REGION=... \
          MLS_GLUE_DATABASE=... MLS_ATHENA_WORKGROUP=... MLS_ATHENA_OUTPUT=...; do
  gh variable set "${kv%%=*}" --env demo --body "${kv#*=}"
done
gh variable list --env demo | grep -E 'MLS_AWS|MLS_GLUE|MLS_ATHENA'
```

**Then confirm the job that builds the container can actually see them.** F124 is exactly this: a variable reached the two jobs that did not need it and missed the one that did. Read the workflow and check which job consumes them, rather than assuming an environment-scoped variable is visible everywhere.

- [ ] **Step 6: Commit**

```bash
git add apps/mcp-tools/src/config.ts apps/mcp-tools/src/tools/cloud/index.ts apps/mcp-tools/tests/config.test.ts
git commit -m "feat(mcp): AWS config, where empty is unconfigured and partial is fatal"
```

---

### Task 7: Register the tool — and fix what registering it breaks

**Files:**
- Modify: `apps/mcp-tools/src/tools/index.ts`
- Modify: `verification/layer-08-audit.ps1`
- Test: `apps/mcp-tools/tests/tools-registry.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 4–6.
- Produces: a registered tool named `query_aws_lakehouse_sql`.

- [ ] **Step 1: Find every reader of the tool list BEFORE widening it**

This is F145's shape and it is the reason this task exists as its own gate. V8.1's expected component set was built from one of three files that declare components; widening it to fix one criterion silently changed the meaning of V8.3, which filtered the same list. **One broken criterion traded for another, with nothing about V8.3 edited to show for it.**

```bash
grep -rn 'query_lakehouse_sql\|ALLOWED_TOOL_NAMES' \
  --include='*.ts' --include='*.ps1' --include='*.json' --include='*.md' \
  apps verification .github docs | grep -v node_modules
```

The allowlist is `ALLOWED_TOOL_NAMES` in `apps/mcp-tools/src/tools/index.ts` — a `const` tuple of six names, with `AllowedToolName` derived from it and `isAllowedTool()` guarding on it. Write down every hit. Decide for each whether it *counts* tools, *names* them, or *filters* them — the third kind is the dangerous one.

- [ ] **Step 2: Write the failing test**

The real API is `buildToolDefinitions(dialect, costSource)` returning `Tool[]`, not a registry object. The AWS tool is additive and gated on configuration, so it takes a third parameter.

```typescript
import { describe, it, expect } from "vitest";
import { ALLOWED_TOOL_NAMES, buildToolDefinitions, isAllowedTool } from "../src/tools/index.js";

describe("AWS lakehouse tool registration", () => {
  it("is on the allowlist", () => {
    expect(ALLOWED_TOOL_NAMES).toContain("query_aws_lakehouse_sql");
    expect(isAllowedTool("query_aws_lakehouse_sql")).toBe(true);
  });

  it("appears only when AWS is configured", () => {
    const withAws = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true })
      .map((t) => t.name);
    const without = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: false })
      .map((t) => t.name);
    expect(withAws).toContain("query_aws_lakehouse_sql");
    expect(without).not.toContain("query_aws_lakehouse_sql");
    expect(without).toContain("query_lakehouse_sql");
  });

  // The two tools must not describe the same dialect. If they do, one is
  // advertising idioms that are wrong for the engine it will hit -- the exact
  // latent break sql-dialect.ts was written to prevent.
  it("describes Trino for AWS and T-SQL for Fabric", () => {
    const tools = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true });
    const fabric = tools.find((t) => t.name === "query_lakehouse_sql")!.description!;
    const aws = tools.find((t) => t.name === "query_aws_lakehouse_sql")!.description!;
    expect(aws).toContain("day_of_week");
    expect(fabric).toContain("DATEPART");
    expect(aws).not.toContain("DATEPART");
  });

  // tools/list order is agent-facing surface, as the costSeriesTool splice
  // comment in index.ts says. Pin the new tool's position deliberately.
  it("places the AWS tool immediately after the Fabric one", () => {
    const names = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true })
      .map((t) => t.name);
    expect(names[1]).toBe("query_aws_lakehouse_sql");
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test --workspace apps/mcp-tools -- tools-registry`
Expected: FAIL — `"query_aws_lakehouse_sql"` is not in `ALLOWED_TOOL_NAMES`

- [ ] **Step 4: Register the tool**

Three edits in `apps/mcp-tools/src/tools/index.ts`:

1. Add `"query_aws_lakehouse_sql"` to `ALLOWED_TOOL_NAMES`. `AllowedToolName` and `isAllowedTool` derive from it and need no change.
2. Add an `awsLakehouseSqlTool(profile: DialectProfile)` builder beside the existing `lakehouseSqlTool`, generating its description from `DIALECTS.trino` exactly as the Fabric tool generates from its profile. The description names the dataset as **real launch-provider data**, so the agent distinguishes the two sources by subject and not only by name.
3. Extend `buildToolDefinitions` with a third parameter `opts: { aws?: boolean } = {}`, splicing the AWS tool in at index 1.

**The load-time guard at the bottom of the file will now check the new name in every dialect.** If it throws at import, the allowlist and the definitions disagree — which is the guard doing its job, not an obstacle to work around.

**Added by pre-flight ruling — without this the tool never reaches production.** `buildToolDefinitions` is called in exactly one live place: the `ToolRegistry` constructor at `index.ts:428`. Two further edits are required, and a test for each:

4. `ToolRegistry`'s constructor passes `{ aws: this.backends.awsLakehouseSql !== undefined }` as the third argument, so the live `tools/list` includes the AWS tool exactly when an AWS backend was built.
5. `ToolRegistry`'s execute path routes `query_aws_lakehouse_sql` to `backends.awsLakehouseSql`, and throws a clear error if that name arrives with no backend behind it.

Without both, the tool passes every test in this task and is **invisible to every agent** — the tool definitions the tests build are not the definitions the server serves. That is F125's class precisely: correct from every angle a reviewer checks, and never once executed. Add a test asserting `new ToolRegistry(backendsWithAws).definitions` contains the tool and `new ToolRegistry(createLocalBackends()).definitions` does not.

Note `apps/mcp-tools/tests/allowlist.test.ts` holds an `EXPECTED_NAMES` list — a second reader of the tool set, and one Step 1's grep must surface.

- [ ] **Step 5: Update V8.3's expectation**

V8.3 asserts the agent declares exactly the expected tool set. Move the expectation to include the new tool, and **add an assertion that fails if a tool is registered without the expectation moving with it** — the defect class, not just this instance.

- [ ] **Step 6: Run everything**

Run: `npm test --workspace apps/mcp-tools && pwsh -c "Invoke-Pester verification/tests -Output Detailed"`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/mcp-tools/src/tools/index.ts apps/mcp-tools/tests/tools-registry.test.ts verification/layer-08-audit.ps1
git commit -m "feat(L8): register query_aws_lakehouse_sql, and move the list V8.3 reads"
```

---

### Task 8: The two criteria, and the claim that no key exists

**Files:**
- Modify: `verification/layer-08-audit.ps1`
- Modify: `verification/tests/failure-classes.Tests.ps1`
- Test: `verification/tests/layer-08-audit.Tests.ps1`

**Interfaces:**
- Consumes: the deployed tool from Task 7.
- Produces: criteria `V8.6` and `V8.7` in the L8 report.

- [ ] **Step 1: Write the failing tests**

`Invoke-V86`, `Invoke-V87` and `Get-CriterionTimeout` below are **placeholders for whatever seam `layer-08-audit.ps1` actually exposes**. Read the file and the existing `verification/tests/layer-*-audit.Tests.ps1` first, and use the seam the other criteria are tested through. Do not add a wrapper to make these names work — a helper that re-wraps the value it is checking is a mirror, not a test.

```powershell
Describe 'V8.6 / V8.7' {
    It 'V8.6 fails when the query returns zero rows' {
        $r = Invoke-V86 -QueryResult @{ rowCount = 0; observable = $true }
        $r.Status | Should -Be 'FAIL'
    }
    It 'V8.6 passes only on a positive row count' {
        (Invoke-V86 -QueryResult @{ rowCount = 1200; observable = $true }).Status | Should -Be 'PASS'
    }
    # F105: Athena against a Glue database the role cannot read can answer
    # emptily rather than 403. Absence is unprovable where denial looks like
    # emptiness, so the criterion must report UNOBSERVABLE and never PASS.
    It 'V8.7 reports UNOBSERVABLE when it could not read the catalog' {
        $r = Invoke-V87 -CatalogProbe @{ observable = $false; reason = 'AccessDenied on glue:GetTables' }
        $r.Status | Should -Be 'UNOBSERVABLE'
    }
    It 'V8.7 never reports the link as absent when it could not look' {
        (Invoke-V87 -CatalogProbe @{ observable = $false }).Status | Should -Not -Be 'FAIL'
    }
    It 'V8.7 never reports the link as present when it could not look' {
        (Invoke-V87 -CatalogProbe @{ observable = $false }).Status | Should -Not -Be 'PASS'
    }
    It 'declares its own wait window rather than inheriting one' {
        (Get-CriterionTimeout -Id 'V8.6') | Should -BeLessThan 120
    }
}

Describe 'no AWS key material anywhere' {
    It 'finds no AWS access key id in the repository' {
        $hits = Select-String -Path "$PSScriptRoot/../../**/*" -Pattern 'AKIA[0-9A-Z]{16}' `
            -Exclude '*.Tests.ps1' -ErrorAction SilentlyContinue
        $hits | Should -BeNullOrEmpty
    }
    It 'names no AWS secret in the CI rotation list' {
        $gitleaks = Get-Content "$PSScriptRoot/../../.github/workflows/gitleaks.yml" -Raw
        $gitleaks | Should -Not -Match 'AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -c "Invoke-Pester verification/tests/layer-08-audit.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Invoke-V86` is not defined

- [ ] **Step 3: Implement the criteria**

In `verification/layer-08-audit.ps1`, following the file's existing criterion structure:

**V8.6** submits a known-answer query against the AWS lakehouse through the deployed tool and asserts a row count greater than zero. It writes the observation to the report as one line — `authenticated Athena query -> N rows, M ms` — because an artifact that cannot distinguish success from silence is not evidence (F162), and the line that fixed that found the real bug on its first run.

**V8.7** probes `glue:GetTables` first. If the probe cannot confirm read access, the criterion reports `UNOBSERVABLE` with the reason, and reports neither PASS nor FAIL. Only once observability is established does it interpret an empty result as genuinely empty.

Both declare an explicit timeout and state what they are waiting on — Athena's queue, not Azure propagation.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -c "Invoke-Pester verification/tests/ -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Lint**

Run: `pwsh -c "Invoke-ScriptAnalyzer -Path verification -Recurse -Severity Error,Warning"`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add verification/
git commit -m "verify(L8): V8.6 asserts rows, V8.7 refuses to call a denial an empty dataset"
```

---

### Task 9: Deploy, probe the dialect against the real engine, capture

**Files:**
- Modify: `apps/mcp-tools/src/tools/cloud/athena-sql.ts` (session probe)
- Create: `verification/reports/` entry (generated)

- [ ] **Step 1: Deploy**

```bash
gh workflow run layer-07-apps.yml
gh run watch "$(gh run list --workflow=layer-07-apps.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

- [ ] **Step 2: Verify the container can see the values it needs**

```bash
az containerapp show -g mls-rg-apps -n mls-mcp-demo-ca \
  --query "properties.template.containers[0].env[?starts_with(name,'MLS_AWS') || starts_with(name,'MLS_ATHENA') || starts_with(name,'MLS_GLUE')]" -o table
az containerapp show -g mls-rg-apps -n mls-mcp-demo-ca \
  --query "identity.userAssignedIdentities" -o json
```

A Key Vault reference resolved to nothing once because the site named no identity to resolve it with, and `appsettings list` printed the reference back perfectly either way (F122). **Ask whether the thing that reads the value can see it, not whether the value is spelled right.**

- [ ] **Step 3: Confirm Trino's weekday numbering against the live engine**

`DIALECTS.trino` promises the agent that `day_of_week` is 1=Monday..7=Sunday. That is a constant naming something in another system, so prove it rather than trusting the docs — the same reason `fabric-sql.ts` carries `SESSION_PROBE_SQL` for `DATEFIRST`:

```sql
SELECT day_of_week(DATE '2026-08-22') AS seed_date_weekday
```

2026-08-22 is a **Saturday**, so ISO numbering must return **6**. If it returns anything else, the tool description is lying to the agent and Task 4's idiom paragraph is wrong. Add this as a first-query probe that fails loudly, mirroring the Fabric adapter.

- [ ] **Step 4: Run the L8 audit**

```bash
gh workflow run layer-08-copilot-studio.yml
```

Expected: V8.6 PASS with a row count, V8.7 PASS or a stated UNOBSERVABLE.

- [ ] **Step 5: Ask the agent a real question and capture it**

Through the Ask tab, ask something only the AWS dataset can answer. Capture the answer, the tool call, and the SQL. **This screenshot is outbrief evidence and cannot be retaken after 2026-09-27.**

- [ ] **Step 6: Commit the report**

```bash
git add verification/reports/
git commit -m "verify(L8): first AWS lakehouse verdict on the live estate"
```

---

## Notes for whoever executes this

**Tasks 4, 5 and 6 need no AWS access.** If the sponsor round-trip stalls, keep going — only Tasks 8 and 9 truly block on the trust anchor existing.

**Expect `AccessDenied` on the first assume.** It is almost always the `sub` or `aud` condition, and `scripts/aws/03-verify.sh` prints both sides so they can be compared rather than guessed. Budget two attempts; the spec's risk table says so for a reason.

**Do not hand-patch a value onto a running app to make a demo work.** An Easy Auth audience was hand-applied to three apps, the scan started working, and `validation` appeared zero times in the template — the next teardown would have erased it silently (F159). If a value is missing, fix the template.
