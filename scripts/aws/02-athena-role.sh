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
