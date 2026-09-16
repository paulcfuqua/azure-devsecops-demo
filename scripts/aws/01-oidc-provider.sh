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
