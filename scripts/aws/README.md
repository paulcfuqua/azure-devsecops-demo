# AWS trust anchor — sponsor runbook

These scripts create the AWS-side half of the cross-cloud lakehouse link against
your real `launch-intel` lakehouse: an IAM OIDC identity provider that trusts
this Entra tenant, and a role (default name `launch-intel-athena-reader`) that
the Azure-hosted agent assumes to run read-only Athena queries against
`launch_intel_lakehouse`. **No data leaves S3. No AWS credential is stored in
Azure or in this repository** — the Azure side holds only a role ARN and
exchanges its own Entra token for short-lived AWS credentials on every call.

**Agents author these scripts; you run them.** AWS writes are outside the
2026-08-29 amendment that lets agents execute the Azure/Entra/Fabric/GitHub
estate — that amendment says nothing about a second cloud, so this is on you.

Prerequisites on your machine: `aws` CLI configured with credentials
(`launch-intel-agent`), `curl`, `python3`.

**The scripts are committed executable (mode 755).** If your checkout somehow
loses that bit (a zip download, some Windows tooling), run
`chmod +x *.sh` first, or just invoke them as `bash ./01-oidc-provider.sh`
etc. — the run-order commands below use `bash ./...` for exactly that reason,
so the first command never fails on "Permission denied" regardless of how the
files reached your disk.

## 0. Before you start: your own AWS credentials need two things they do not have today

`BOOTSTRAP.md`'s policy for `launch-intel-agent` was written before this link
existed, and two gaps in it will make `01-oidc-provider.sh` and
`03-verify.sh` fail with `AccessDenied` on their very first AWS call —
*before* anything Azure-related is even reached:

1. **OIDC provider management is scoped to Vercel's provider only.**
   `LakehouseManageVercelOidcProvider`'s `Resource` is
   `arn:aws:iam::<account>:oidc-provider/oidc.vercel.com/*`, which does not
   match `oidc-provider/sts.windows.net/*` or
   `oidc-provider/login.microsoftonline.com/*`. Add a parallel statement:

   ```json
   {
     "Sid": "LakehouseListOidcProviders",
     "Effect": "Allow",
     "Action": "iam:ListOpenIDConnectProviders",
     "Resource": "*"
   },
   {
     "Sid": "LakehouseManageEntraOidcProviders",
     "Effect": "Allow",
     "Action": [
       "iam:CreateOpenIDConnectProvider",
       "iam:GetOpenIDConnectProvider",
       "iam:AddClientIDToOpenIDConnectProvider",
       "iam:DeleteOpenIDConnectProvider",
       "iam:TagOpenIDConnectProvider"
     ],
     "Resource": [
       "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/sts.windows.net/*",
       "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/login.microsoftonline.com/*"
     ]
   }
   ```

   (`iam:ListOpenIDConnectProviders` has no resource-level permissions in
   IAM — same reason the account's existing read-only actions are `Resource:
   "*"`.)

2. **`LakehouseRunAthenaQueries` never granted `GetWorkGroup`.**
   That statement lists only `StartQueryExecution`, `GetQueryExecution`,
   `GetQueryResults` and `StopQueryExecution`, and `03-verify.sh` calls
   `aws athena get-work-group` as *you* — so its workgroup section fails
   `AccessDenied`. (The role's own policy, created by `02-athena-role.sh`, is
   separate and already grants it for the Azure side.) `athena:GetDataCatalog`
   is in the statement below too: no script here calls it as you, but it is
   what you would reach for to check the catalog by hand, and it is read-only
   on one named catalog. Add:

   ```json
   {
     "Sid": "LakehouseVerifyAthenaWorkgroup",
     "Effect": "Allow",
     "Action": ["athena:GetWorkGroup", "athena:GetDataCatalog"],
     "Resource": [
       "arn:aws:athena:us-east-1:<ACCOUNT_ID>:workgroup/primary",
       "arn:aws:athena:us-east-1:<ACCOUNT_ID>:datacatalog/AwsDataCatalog"
     ]
   }
   ```

**No new statement is needed for the role itself.** `02-athena-role.sh`
defaults `MLS_AWS_ROLE_NAME` to `launch-intel-athena-reader` specifically so
it falls inside `IamManageProjectRoles`' existing
`arn:aws:iam::<account>:role/launch-intel-*` scope — pick a different name
and you will need to widen that statement too.

## 1. KMS and Lake Formation: checked, neither applies

Read out of your own `infra/terraform/`, not assumed — and re-checked against
`terraform.tfstate`, because a resource absent from the `.tf` files can still
be present in the account:

- **SSE-KMS: no.** There is no `aws_kms_key` and no
  `aws_s3_bucket_server_side_encryption_configuration` resource, and the state
  records the bucket's applied encryption as `sse_algorithm: "AES256"` with an
  empty `kms_master_key_id` — SSE-S3, which needs no IAM grant of its own.
- **Lake Formation: no.** There is no `aws_lakeformation_*` resource of any
  kind, so the Glue catalog is governed by plain IAM and no LF grant is
  needed.

Both answers are "no extra permission required", so `02-athena-role.sh`'s
policy is complete as written. **Please confirm neither was turned on outside
Terraform** — that is the one thing the files cannot tell us. If either is
ever enabled, the role will need `kms:Decrypt`/`kms:GenerateDataKey` on the
key and/or a Lake Formation `SELECT` grant on the three tables; IAM alone
cannot supply either, and both fail as a perfect-looking policy that returns
`AccessDenied`.

## 2. Environment variables

The first four are **Azure-side identifiers, and this file RESOLVES them
rather than pasting them.** Each command below was run against the live
tenant on 2026-09-16 and returns the right answer today; §4's block runs them
for you, so you still copy and paste exactly once.

Two reasons, and the second is the one that bites:

- **They must not be committed.** V1.3 sweeps this repository for GUIDs and
  fails on any that is not on a reviewed allowlist, and the tenant id, an app
  id and a principal id are precisely the estate identifiers it exists to
  keep out — allowlisting one is itself a finding (F62). Pasting these four
  values into this file, which an earlier draft did, turns that criterion red.
- **Two of the three go stale.** An app id is reassigned every time L3
  recreates the registration, so a pasted `MLS_AWS_APP_ID` is wrong after the
  next rebuild while still looking perfectly plausible. Resolving is not
  ceremony here; it is the difference between a runbook that works twice and
  one that works once.

| Variable | How to get it | What it is |
|---|---|---|
| `MLS_TENANT_ID` | `az account show --query tenantId -o tsv` | The Entra tenant id |
| `MLS_AWS_AUDIENCE` | `api://$MLS_TENANT_ID/mls-aws-athena-demo` — `identifierUris[0]` of the `aws-athena` app (Task 1) | The `aud` claim a v1 token carries |
| `MLS_AWS_APP_ID` | `az ad app list --identifier-uri "$MLS_AWS_AUDIENCE" --query "[0].appId" -o tsv` | The `aws-athena` app's application (client) id. The `aud` a v2 token would carry — see §3 |
| `MLS_AWS_PRINCIPAL_ID` | `az identity show -g mls-rg-identity -n mls-aws-demo-id --query principalId -o tsv` | The `sub` claim — the Azure managed identity Task 2 created. It lives in its own resource group, outside the four the standard teardown deletes, so this one value *is* stable across a rebuild |

The rest describe **your real `launch-intel` lakehouse**, verified against
`infra/terraform/lakehouse.tf` in that project:

| Variable | Value | What it is |
|---|---|---|
| `MLS_AWS_ACCOUNT_ID` | `634008058936` | The AWS account holding the lakehouse |
| `MLS_AWS_REGION` | `us-east-1` | |
| `MLS_GLUE_DATABASE` | `launch_intel_lakehouse` | The Glue Data Catalog database |
| `MLS_GLUE_TABLES` | `launches,agencies,schedule_events` | Comma-separated table names |
| `MLS_ATHENA_WORKGROUP` | `primary` | |
| `MLS_LAKEHOUSE_BUCKET` | `launch-intel-lakehouse-634008058936` | **The one bucket** — data and Athena results live here at different prefixes, not in separate buckets |
| `MLS_DATA_PREFIXES` | `launches,agencies,schedule_events` | Comma-separated **read-only** prefixes (matches the table names, but is a separate variable in case that ever changes) |
| `MLS_RESULTS_PREFIX` | `athena-results/` | The **one** prefix this role may write |
| `MLS_AWS_ROLE_NAME` | `launch-intel-athena-reader` | See §0 for why this default, not `mls-athena-reader` |
| `MLS_ATHENA_OUTPUT` | `s3://launch-intel-lakehouse-634008058936/athena-results/` | Full results URI. The `primary` workgroup enforces **no default output location** (confirmed in `LAKEHOUSE_SETUP.md`) — `03-verify.sh` checks this live and reports it, but this value is what Task 6's caller must pass explicitly on every query regardless. |

Two more are **produced by `01-oidc-provider.sh`, not set by you**:
`MLS_AWS_PROVIDER_ARN_V1`, `MLS_AWS_PROVIDER_ARN_V2` (and their
`_PREEXISTED` companions, used only by `teardown.sh` — see §6). `01` writes
the four lines it prints to `./.aws-anchor.env` next to the scripts, and `02`
and `03` source that file automatically for any variable you have not
already exported yourself — so pasting them by hand is convenient, not
required. That file is git-ignored: it holds a tenant id and a principal id
and must never be committed.

## 3. Why two OIDC providers, not one

`infra/entra/manifest.json` now **declares** `"requestedAccessTokenVersion":
1` for the `aws-athena` app, and the deploy path applies it to the live
tenant. Version 1 means the token Azure presents carries issuer
`https://sts.windows.net/<tenant id>/` with `aud` = `MLS_AWS_AUDIENCE` — not
the v2.0 issuer a first draft of this design assumed alone.

It was undeclared until 2026-09-16, and Entra reads an unset value as 1, so
the behaviour is unchanged — but the *guarantee* is not. The whole
cross-cloud trust chain rested on a default nobody had chosen and no rebuild
reproduced, and the failure it would produce is an AWS `AccessDenied` that
names no field.

`01-oidc-provider.sh` registers **both** possible issuers anyway (v1:
`sts.windows.net`, aud = `MLS_AWS_AUDIENCE`; v2:
`login.microsoftonline.com`, aud = `MLS_AWS_APP_ID`), and `02-athena-role.sh`
writes a trust policy with one fully self-contained statement per issuer.
That costs one extra API round trip and means the trust policy keeps working
if the declaration is ever changed to 2 — with no AWS-side change at all.

## 4. Run order: `01` → `02` → `03`

You need an `az` login against the demo tenant for the first block (any role
that can read — these are four reads) and your `launch-intel-agent` AWS
profile for the rest.

```bash
# --- Azure side: resolved, never pasted (see §2) ---
export MLS_TENANT_ID=$(az account show --query tenantId -o tsv)
export MLS_AWS_AUDIENCE="api://${MLS_TENANT_ID}/mls-aws-athena-demo"
export MLS_AWS_APP_ID=$(az ad app list --identifier-uri "$MLS_AWS_AUDIENCE" --query "[0].appId" -o tsv)
export MLS_AWS_PRINCIPAL_ID=$(az identity show -g mls-rg-identity -n mls-aws-demo-id --query principalId -o tsv)

# Check all four before going near AWS: an empty one here becomes an
# AccessDenied with no field name, hours later, on the Azure side.
for v in MLS_TENANT_ID MLS_AWS_AUDIENCE MLS_AWS_APP_ID MLS_AWS_PRINCIPAL_ID; do
  printf '%-24s %s\n' "$v" "${!v:-<EMPTY - STOP>}"
done

# --- AWS side: your own lakehouse ---
export MLS_AWS_ACCOUNT_ID=634008058936
export MLS_AWS_REGION=us-east-1
export MLS_GLUE_DATABASE=launch_intel_lakehouse
export MLS_GLUE_TABLES=launches,agencies,schedule_events
export MLS_ATHENA_WORKGROUP=primary
export MLS_LAKEHOUSE_BUCKET=launch-intel-lakehouse-634008058936
export MLS_DATA_PREFIXES=launches,agencies,schedule_events
export MLS_RESULTS_PREFIX=athena-results/
export MLS_AWS_ROLE_NAME=launch-intel-athena-reader
export MLS_ATHENA_OUTPUT=s3://launch-intel-lakehouse-634008058936/athena-results/

bash ./01-oidc-provider.sh
# prints four lines: export MLS_AWS_PROVIDER_ARN_V1=...
#                    export MLS_AWS_PROVIDER_ARN_V2=...
#                    export MLS_AWS_PROVIDER_V1_PREEXISTED=...
#                    export MLS_AWS_PROVIDER_V2_PREEXISTED=...
# ALSO written to ./.aws-anchor.env, which 02 and 03 source automatically --
# run the four export lines yourself only if you want them in THIS shell too
# (e.g. to hand-inspect a value); it is no longer required before continuing.

bash ./02-athena-role.sh
# prints: export MLS_AWS_ROLE_ARN=arn:aws:iam::...
#         export MLS_AWS_ROLE_NAME=launch-intel-athena-reader
# ALSO appended to ./.aws-anchor.env, which 03 sources automatically.

bash ./03-verify.sh
```

Each script is idempotent: re-running `01` or `02` against an existing
provider/role updates it in place (including the trust policy itself, not
just the inline permissions policy) rather than silently doing nothing, so a
retry after a transient error is safe. A variable already exported in your
shell always wins over `.aws-anchor.env` — the file only fills gaps, it never
overrides what you set yourself.

## 5. `03-verify.sh`'s output is the evidence

`03-verify.sh` doesn't create anything — it reads back everything `01` and
`02` created, and **compares each value against what was asked for**,
printing `PASS` or `FAIL` per check rather than just dumping JSON. It never
stops at the first failure: a run against a live account is an expensive,
rate-limited observation, so it reports everything it saw and only exits
non-zero at the very end if anything failed. Save its full output.

The workgroup section also reports whether `primary` enforces a default
output location (it does not, per §2) — if it ever starts enforcing one,
this is where you'd see that change.

## 6. What to send back

The full output of `03-verify.sh`, plus these **six lines**, exactly as it
prints them at the end:

```
export MLS_AWS_ROLE_ARN=arn:aws:iam::634008058936:role/launch-intel-athena-reader
export MLS_AWS_AUDIENCE=api://<tenant id>/mls-aws-athena-demo
export MLS_AWS_REGION=us-east-1
export MLS_GLUE_DATABASE=launch_intel_lakehouse
export MLS_ATHENA_WORKGROUP=primary
export MLS_ATHENA_OUTPUT=s3://launch-intel-lakehouse-634008058936/athena-results/
```

`03-verify.sh` prints the real tenant id in place of `<tenant id>`; it is
written as a placeholder here for the reason §2 gives.

This is everything Task 6 wires into the Azure container: the role to
assume, the audience to request a token for, and the four AWS-side values
that live as `demo` GitHub environment variables per the design spec.

## 7. Expected failure, named

If the Azure side reports `AccessDenied` on `AssumeRoleWithWebIdentity`, **it
is almost always the `aud` or `sub` condition in the trust policy not
matching the token Azure actually presents** — not a permissions problem,
and not a typo you'll spot by eye. Don't guess: run `03-verify.sh` again and
look at the two `PASS`/`FAIL` lines under "role trust policy" — they compare
the trust policy's actual `aud`/`sub` condition values against
`MLS_AWS_AUDIENCE`/`MLS_AWS_APP_ID`/`MLS_AWS_PRINCIPAL_ID` for you, so you
never have to eyeball a GUID against another GUID. If Azure ever declares
`requestedAccessTokenVersion: 2` for the `aws-athena` app, that failure will
point at the v2 statement instead of the v1 one — the trust policy already
has both, so no script re-run is needed for that change to keep working.

## 8. Teardown

`teardown.sh` removes the role's inline policy, the role, and each OIDC
provider **this setup created** (never one that pre-existed — see below).
This is **G3-equivalent**: once deleted, nothing in the Azure deploy path can
recreate the AWS side.

- Refuses to run unattended in CI (`CI=true` or `GITHUB_ACTIONS=true`)
  without `-AllowAutomation` — the same guard the three tenant-level
  teardowns under `infra/` use.
- Everywhere else, it prompts you to type the role name back before deleting
  anything (skip the prompt non-interactively with `-AllowAutomation`).
- Pass `--dry-run` to see exactly what it would do without being prompted.
- It only deletes a provider if `MLS_AWS_PROVIDER_V1_PREEXISTED` /
  `_V2_PREEXISTED` (printed by `01-oidc-provider.sh`) is the literal string
  `false`. Unset, or anything else, means "skip it" — this account already
  has one other OIDC provider (Vercel's), and a provider this setup did not
  create might be load-bearing for something else entirely.

```bash
export MLS_AWS_ROLE_NAME=launch-intel-athena-reader
export MLS_AWS_PROVIDER_ARN_V1=arn:aws:iam::634008058936:oidc-provider/sts.windows.net/...
export MLS_AWS_PROVIDER_ARN_V2=arn:aws:iam::634008058936:oidc-provider/login.microsoftonline.com/...
export MLS_AWS_PROVIDER_V1_PREEXISTED=false   # from 01's output
export MLS_AWS_PROVIDER_V2_PREEXISTED=false   # from 01's output
bash ./teardown.sh --dry-run   # see what would happen
bash ./teardown.sh             # then actually do it
```
