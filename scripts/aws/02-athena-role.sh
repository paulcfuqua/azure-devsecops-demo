#!/usr/bin/env bash
# Create the read-only Athena role the Azure container assumes.
#
# TWO trust statements, not one (fix round 1, C1/Fix B): the token in use
# carries the v1 issuer with aud = the api:// audience URI, because
# infra/entra/manifest.json declares "requestedAccessTokenVersion": 1. If that
# declaration is ever changed to 2 the token carries the v2 issuer with aud =
# the app id GUID instead. Each statement is fully self-contained -- its own
# Federated principal, its own aud/sub pair -- so neither weakens the other
# and the trust policy survives that change with no edit here. See
# 01-oidc-provider.sh for why both providers exist.
#
# Each statement still checks BOTH aud and sub. aud alone would let any
# workload in the tenant holding a token for that audience assume the role.
set -euo pipefail

# Windows path fix follow-up, 2026-09-16: fill in any variable NOT already
# set in this shell from the anchor file 01-oidc-provider.sh writes, so a
# sponsor who did not hand-paste 01's four `export` lines does not die here
# on an unset-variable error. A variable already exported in this shell wins
# over the file -- this only fills gaps, it never overrides. Resolved to this
# script's own directory, not the caller's cwd. Silently skipped if the file
# does not exist (e.g. providers were pre-existing and exported by hand).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANCHOR_ENV="${SCRIPT_DIR}/.aws-anchor.env"
if [ -f "${ANCHOR_ENV}" ]; then
  echo "found ${ANCHOR_ENV} (written by 01-oidc-provider.sh) -- filling in any variable not already set in this shell" >&2
  while IFS='=' read -r _anchor_key _anchor_value; do
    _anchor_key="${_anchor_key#export }"
    _anchor_key="${_anchor_key%$'\r'}"
    _anchor_value="${_anchor_value%$'\r'}"
    [ -z "${_anchor_key}" ] && continue
    if [ -z "${!_anchor_key+x}" ] || [ -z "${!_anchor_key}" ]; then
      export "${_anchor_key}=${_anchor_value}"
    fi
  done < "${ANCHOR_ENV}"
  unset _anchor_key _anchor_value
fi

: "${MLS_AWS_AUDIENCE:?set MLS_AWS_AUDIENCE (the v1 aud -- identifierUris[0] of the aws-athena app)}"
: "${MLS_AWS_APP_ID:?set MLS_AWS_APP_ID (the v2 aud -- the aws-athena application/client id GUID)}"
: "${MLS_AWS_PRINCIPAL_ID:?set MLS_AWS_PRINCIPAL_ID (the managed identity principal id -- the sub claim, from Task 2)}"
: "${MLS_AWS_PROVIDER_ARN_V1:?set MLS_AWS_PROVIDER_ARN_V1 (printed by 01-oidc-provider.sh)}"
: "${MLS_AWS_PROVIDER_ARN_V2:?set MLS_AWS_PROVIDER_ARN_V2 (printed by 01-oidc-provider.sh)}"
: "${MLS_AWS_ROLE_NAME:?set MLS_AWS_ROLE_NAME (e.g. launch-intel-athena-reader -- pick a name matching the launch-intel-* pattern BOOTSTRAP.md already scopes your IAM identity to manage, via the IamManageProjectRoles statement)}"
: "${MLS_AWS_ACCOUNT_ID:?set MLS_AWS_ACCOUNT_ID (the AWS account holding the lakehouse)}"
: "${MLS_AWS_REGION:?set MLS_AWS_REGION (e.g. us-east-1)}"
: "${MLS_GLUE_DATABASE:?set MLS_GLUE_DATABASE (the Glue Data Catalog database name)}"
: "${MLS_GLUE_TABLES:?set MLS_GLUE_TABLES (comma-separated table names, e.g. launches,agencies,schedule_events)}"
: "${MLS_ATHENA_WORKGROUP:?set MLS_ATHENA_WORKGROUP (e.g. primary)}"
: "${MLS_LAKEHOUSE_BUCKET:?set MLS_LAKEHOUSE_BUCKET (the single S3 bucket holding both data and Athena results, at different prefixes)}"
: "${MLS_DATA_PREFIXES:?set MLS_DATA_PREFIXES (comma-separated read-only prefixes, e.g. launches,agencies,schedule_events)}"
: "${MLS_RESULTS_PREFIX:?set MLS_RESULTS_PREFIX (the one prefix this role may write, e.g. athena-results/)}"

# Deriving each issuer host from AWS's OWN read-back of the provider's Url --
# never reconstructed from a tenant id -- is deliberate: it is the exact value
# AWS stores and matches against a token's iss claim, scheme stripped.
# Guessing that transformation here would silently drift from whatever AWS's
# storage format actually is (this is the one design choice fix round 1's
# review kept unchanged, for that reason).
V1_ISSUER_HOST=$(aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V1}" --query Url --output text)
V2_ISSUER_HOST=$(aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V2}" --query Url --output text)
# Strip a trailing \r (fix round 1, verified by testing): on platforms where
# python or the aws CLI emit CRLF, bash's command substitution strips only
# the final \n, leaving a \r glued to the value -- invisible in an echoed
# line, but fatal to the exact-string trust-policy condition keys below and
# to 03-verify.sh's comparisons downstream.
V1_ISSUER_HOST="${V1_ISSUER_HOST//$'\r'/}"
V2_ISSUER_HOST="${V2_ISSUER_HOST//$'\r'/}"

TRUST_FILE=$(mktemp)
POLICY_FILE=$(mktemp)
GET_ROLE_ERR=$(mktemp)
trap 'rm -f "${TRUST_FILE}" "${POLICY_FILE}" "${GET_ROLE_ERR}"' EXIT

# TRUST_FILE and POLICY_FILE are written to and validated (python3 json.load)
# below, but handed to `aws` BY CONTENT ("$(cat "${FILE}")"), never by a
# file:// reference (Windows path fix, 2026-09-16). A sponsor running MSYS2
# bash on Windows with the native aws.exe hits this exactly: mktemp returns a
# POSIX path like /tmp/tmp.XXXXXXXXXX that only the MSYS shell can resolve,
# aws.exe sees a path that does not exist, and MSYS's argv translation does
# not rescue a file:// URL. verification/tests/failure-classes.Tests.ps1
# ("scripts/aws never hands a native CLI an mktemp path via file://") makes
# this a repo-wide check, not just a fix at these three call sites.

cat > "${TRUST_FILE}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TrustV1TokenTheDeclaredVersion",
      "Effect": "Allow",
      "Principal": { "Federated": "${MLS_AWS_PROVIDER_ARN_V1}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${V1_ISSUER_HOST}:aud": "${MLS_AWS_AUDIENCE}",
          "${V1_ISSUER_HOST}:sub": "${MLS_AWS_PRINCIPAL_ID}"
        }
      }
    },
    {
      "Sid": "TrustV2TokenIfTokenVersionIsEverChangedToTwo",
      "Effect": "Allow",
      "Principal": { "Federated": "${MLS_AWS_PROVIDER_ARN_V2}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${V2_ISSUER_HOST}:aud": "${MLS_AWS_APP_ID}",
          "${V2_ISSUER_HOST}:sub": "${MLS_AWS_PRINCIPAL_ID}"
        }
      }
    }
  ]
}
JSON

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${TRUST_FILE}"

# Every array below is built by python's json module from the raw comma lists,
# never by hand-splicing strings into the heredoc -- the IAM JSON this
# replaces was written from memory in the original brief and undercounted
# what a real query needs (fix round 1, C3). Values reach python as argv, not
# interpolated into the script text, so a prefix or table name containing a
# quote can't corrupt the document.
GLUE_RESOURCES_JSON=$(python3 -c "
import json, sys
region, account, db, tables_csv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
tables = [t.strip() for t in tables_csv.split(',') if t.strip()]
resources = [
    f'arn:aws:glue:{region}:{account}:catalog',
    f'arn:aws:glue:{region}:{account}:database/{db}',
] + [f'arn:aws:glue:{region}:{account}:table/{db}/{t}' for t in tables]
print(json.dumps(resources))
" "${MLS_AWS_REGION}" "${MLS_AWS_ACCOUNT_ID}" "${MLS_GLUE_DATABASE}" "${MLS_GLUE_TABLES}")
GLUE_RESOURCES_JSON="${GLUE_RESOURCES_JSON//$'\r'/}"

# The bucket holds BOTH the data and the Athena results at different prefixes
# (the sponsor's actual layout -- the original brief assumed two buckets and
# scoped S3 write at bucket level, which here would let this role overwrite
# the source data). ListBucket is scoped by s3:prefix rather than granted
# bucket-wide, and GetObject/PutObject are scoped to prefix-specific object
# ARNs, so the results prefix stays the only place this role may write.
#
# s3:ListBucketMultipartUploads carries NO s3:prefix condition, deliberately
# and after checking: s3:prefix is a condition key S3 supplies for ListBucket
# (alongside s3:delimiter and s3:max-keys), not for ListBucketMultipartUploads.
# Conditioning on a key the request never carries does not narrow an Allow, it
# VOIDS it -- the condition can never be satisfied, so the statement grants
# nothing while reading in a diff as a tighter version of itself. It is left
# unconditioned at bucket scope, which is a metadata read of in-progress
# uploads: it exposes no object content and writes nothing, so the "results
# prefix is the only writable place" property is untouched.
LIST_PREFIXES_JSON=$(python3 -c "
import json, sys
prefixes = [p.strip().rstrip('/') + '/*' for p in sys.argv[1].split(',') if p.strip()]
prefixes.append(sys.argv[2].rstrip('/') + '/*')
print(json.dumps(prefixes))
" "${MLS_DATA_PREFIXES}" "${MLS_RESULTS_PREFIX}")
LIST_PREFIXES_JSON="${LIST_PREFIXES_JSON//$'\r'/}"

DATA_OBJECT_ARNS_JSON=$(python3 -c "
import json, sys
bucket_arn, prefixes_csv = sys.argv[1], sys.argv[2]
prefixes = [p.strip().rstrip('/') for p in prefixes_csv.split(',') if p.strip()]
print(json.dumps([f'{bucket_arn}/{p}/*' for p in prefixes]))
" "arn:aws:s3:::${MLS_LAKEHOUSE_BUCKET}" "${MLS_DATA_PREFIXES}")
DATA_OBJECT_ARNS_JSON="${DATA_OBJECT_ARNS_JSON//$'\r'/}"

BUCKET_ARN="arn:aws:s3:::${MLS_LAKEHOUSE_BUCKET}"
RESULTS_PREFIX_TRIMMED="${MLS_RESULTS_PREFIX%/}"

cat > "${POLICY_FILE}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AthenaRunAndPollOneWorkgroup",
      "Effect": "Allow",
      "Action": ["athena:StartQueryExecution","athena:GetQueryExecution",
                 "athena:GetQueryResults","athena:StopQueryExecution",
                 "athena:GetWorkGroup"],
      "Resource": "arn:aws:athena:${MLS_AWS_REGION}:${MLS_AWS_ACCOUNT_ID}:workgroup/${MLS_ATHENA_WORKGROUP}" },
    { "Sid": "AthenaReadTheDefaultDataCatalog",
      "Effect": "Allow",
      "Action": "athena:GetDataCatalog",
      "Resource": "arn:aws:athena:${MLS_AWS_REGION}:${MLS_AWS_ACCOUNT_ID}:datacatalog/AwsDataCatalog" },
    { "Sid": "GlueReadOneDatabase",
      "Effect": "Allow",
      "Action": ["glue:GetDatabase","glue:GetDatabases","glue:GetTable",
                 "glue:GetTables","glue:GetPartition","glue:GetPartitions",
                 "glue:BatchGetPartition"],
      "Resource": ${GLUE_RESOURCES_JSON} },
    { "Sid": "S3BucketMetadata",
      "Effect": "Allow",
      "Action": "s3:GetBucketLocation",
      "Resource": "${BUCKET_ARN}" },
    { "Sid": "S3ListOnlyTheDataAndResultsPrefixes",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ${LIST_PREFIXES_JSON} } } },
    { "Sid": "S3ListInProgressMultipartUploads",
      "Effect": "Allow",
      "Action": "s3:ListBucketMultipartUploads",
      "Resource": "${BUCKET_ARN}" },
    { "Sid": "S3ReadDataPrefixesOnly",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": ${DATA_OBJECT_ARNS_JSON} },
    { "Sid": "S3ReadWriteResultsPrefixOnly",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:ListMultipartUploadParts","s3:AbortMultipartUpload"],
      "Resource": "${BUCKET_ARN}/${RESULTS_PREFIX_TRIMMED}/*" }
  ]
}
JSON

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${POLICY_FILE}"

# Existence check is its own step, never a create-and-catch-the-error (fix
# round 1, C2): create-role fails on an existing role and get-role's
# NoSuchEntity looked, on retry, like confirmation the role never existed --
# when what actually failed was the trust-policy update the sponsor needed.
# A non-NoSuchEntity error here (AccessDenied, throttling) is surfaced
# directly rather than being reinterpreted as "role is absent".
if ROLE_ARN=$(aws iam get-role --role-name "${MLS_AWS_ROLE_NAME}" --query Role.Arn --output text 2>"${GET_ROLE_ERR}"); then
  ROLE_ARN="${ROLE_ARN//$'\r'/}"
  echo "role exists: updating trust policy in place"
  aws iam update-assume-role-policy --role-name "${MLS_AWS_ROLE_NAME}" \
    --policy-document "$(cat "${TRUST_FILE}")"
else
  if ! grep -q 'NoSuchEntity' "${GET_ROLE_ERR}"; then
    cat "${GET_ROLE_ERR}" >&2
    exit 1
  fi
  echo "role does not exist: creating"
  ROLE_ARN=$(aws iam create-role --role-name "${MLS_AWS_ROLE_NAME}" \
    --assume-role-policy-document "$(cat "${TRUST_FILE}")" \
    --description "Read-only Athena access for the Azure-hosted MLS agent" \
    --query Role.Arn --output text)
  ROLE_ARN="${ROLE_ARN//$'\r'/}"
fi

aws iam put-role-policy --role-name "${MLS_AWS_ROLE_NAME}" \
  --policy-name "${MLS_AWS_ROLE_NAME}-permissions" --policy-document "$(cat "${POLICY_FILE}")"

{
  echo "export MLS_AWS_ROLE_ARN=${ROLE_ARN}"
  echo "export MLS_AWS_ROLE_NAME=${MLS_AWS_ROLE_NAME}"
} | tee -a "${ANCHOR_ENV}"
echo "(the two lines above were also appended to ${ANCHOR_ENV} -- 03-verify.sh sources it automatically, so pasting them yourself is optional, not required)" >&2
