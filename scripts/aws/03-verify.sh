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
