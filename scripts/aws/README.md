# AWS trust anchor — sponsor runbook

These scripts create the AWS-side half of the cross-cloud lakehouse link: an IAM
OIDC identity provider that trusts this Entra tenant, and a role
(`mls-athena-reader`) that the Azure-hosted agent assumes to run read-only
Athena queries against your existing Glue/S3 lakehouse. **No data leaves S3.
No AWS credential is stored in Azure or in this repository** — the Azure side
holds only a role ARN and exchanges its own Entra token for short-lived AWS
credentials on every call.

**Agents author these scripts; you run them.** AWS writes are outside the
2026-08-29 amendment that lets agents execute the Azure/Entra/Fabric/GitHub
estate — that amendment says nothing about a second cloud, so this is on you.
Prerequisites on your machine: `aws` CLI configured with credentials that can
create IAM OIDC providers, roles and role policies; `curl`; `python3`.

## 1. Environment variables

Set these before you start. The first three are already resolved against the
live tenant/Azure estate as of 2026-09-16 — paste them as given, don't
re-derive them:

| Variable | Value | Source |
|---|---|---|
| `MLS_TENANT_ID` | `c3571944-a345-43e4-bcb5-fd12ac314f8f` | Entra tenant id (`az account show --query tenantId -o tsv`) |
| `MLS_AWS_AUDIENCE` | `api://c3571944-a345-43e4-bcb5-fd12ac314f8f/mls-aws-athena-demo` | The `aud` claim — an Entra app registration created in Task 1 |
| `MLS_AWS_PRINCIPAL_ID` | `a67dea1b-3151-4ccc-8056-7a479a501c00` | The `sub` claim — the Azure managed identity's principal id, created in Task 2 |

These four only you know — they name resources in your AWS account that
nothing on the Azure side can see, so they stay required environment
variables that fail loudly (via bash's `${VAR:?message}`) rather than
defaulting to something wrong:

| Variable | What it is |
|---|---|
| `MLS_GLUE_DATABASE` | The Glue Data Catalog database name holding the lakehouse tables |
| `MLS_ATHENA_WORKGROUP` | The Athena workgroup to run queries in |
| `MLS_DATA_BUCKET` | The S3 bucket holding the source data (read-only access) |
| `MLS_RESULTS_BUCKET` | The S3 bucket Athena stages query results into (read + write, staging only) |

Two more variables are **produced by these scripts, not set by you** —
`01-oidc-provider.sh` prints `export MLS_AWS_PROVIDER_ARN=...` and
`02-athena-role.sh` prints `export MLS_AWS_ROLE_ARN=...`. Run the printed
`export` line (or copy the value) before moving to the next script.

## 2. Run order: `01` → `02` → `03`

```bash
export MLS_TENANT_ID=c3571944-a345-43e4-bcb5-fd12ac314f8f
export MLS_AWS_AUDIENCE=api://c3571944-a345-43e4-bcb5-fd12ac314f8f/mls-aws-athena-demo
export MLS_AWS_PRINCIPAL_ID=a67dea1b-3151-4ccc-8056-7a479a501c00
export MLS_GLUE_DATABASE=...        # your Glue database
export MLS_ATHENA_WORKGROUP=...     # your Athena workgroup
export MLS_DATA_BUCKET=...          # your data bucket
export MLS_RESULTS_BUCKET=...       # your Athena results bucket

./01-oidc-provider.sh
# prints: export MLS_AWS_PROVIDER_ARN=arn:aws:iam::...
# run that line (or export it yourself) before continuing

./02-athena-role.sh
# prints: export MLS_AWS_ROLE_ARN=arn:aws:iam::...

./03-verify.sh
```

Each script is idempotent: re-running `01` or `02` against an existing
provider/role updates it in place rather than failing on "already exists", so
a retry after a transient error is safe.

## 3. `03-verify.sh`'s output is the evidence

`03-verify.sh` doesn't create anything — it reads back everything `01` and
`02` created: the OIDC provider's URL and registered audiences, the role's
trust policy, its attached inline policy, and the target workgroup's
reachability and bytes-scanned cutoff. **A create that exited zero is not
evidence that the trust is wired correctly; this printout is.** Save its full
output and send it back along with the two `export` lines below — that
combination is what the Azure side needs to finish the link, and what
confirms the AWS side is correct before anyone builds on top of it.

Note the last section, "workgroup reachable, and capped": it **prints a
warning if the workgroup has no per-query bytes-scanned cutoff, but does not
fail**. At the reported ~$0.20/month of Athena spend on this dataset, a hard
stop over an uncapped cutoff would be a false alarm — the check stays because
an agent writing its own SQL is a real reason to eventually set one, not
because it's urgent today.

## 4. What to send back

Two lines, exactly as printed:

```
export MLS_AWS_PROVIDER_ARN=arn:aws:iam::<account>:oidc-provider/login.microsoftonline.com/...
export MLS_AWS_ROLE_ARN=arn:aws:iam::<account>:role/mls-athena-reader
```

Plus the full output of `03-verify.sh`. `MLS_AWS_ROLE_ARN` is what Task 6
wires into the Azure container as the identifier the agent's backend assumes.

## 5. Expected failure, named

If the Azure side later reports `AccessDenied` on its first
`AssumeRoleWithWebIdentity` call, **it is almost always the `aud` or `sub`
condition in the trust policy not matching the token Azure actually
presents** — not a permissions problem, and not a typo you'll spot by eye.
Don't guess: run `03-verify.sh` again, look at the `"--- role trust policy
---"` section, and compare its `StringEquals` values character-for-character
against the audience and principal id the Azure side is actually using. The
condition keys are prefixed with the issuer host
(`login.microsoftonline.com/<tenant-id>/v2.0:aud` and `:sub`) — if those don't
match what Azure sends, the assume fails with no further detail from AWS.

## 6. Teardown

`teardown.sh` deletes the role and the OIDC provider. This is **G3-equivalent**:
once deleted, nothing in the Azure deploy path can recreate the AWS side, so
it refuses to run unattended in CI (`CI=true`) unless you pass
`-AllowAutomation` explicitly — the same guard the three tenant-level
teardowns under `infra/` use. Run it by hand when you actually mean to tear
the link down:

```bash
export MLS_AWS_PROVIDER_ARN=arn:aws:iam::<account>:oidc-provider/login.microsoftonline.com/...
./teardown.sh
```
