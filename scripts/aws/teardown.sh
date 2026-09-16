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
