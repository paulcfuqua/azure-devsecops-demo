#!/usr/bin/env bash
# Remove the AWS trust anchor: the role's inline policy, the role itself, and
# each OIDC provider THIS SETUP CREATED.
#
# G3-equivalent: deleting the role or a provider cannot be recreated by the
# Azure deploy path. It refuses to run unattended in CI, and everywhere else
# it prompts for a typed confirmation before deleting anything -- the closest
# bash equivalent to the SupportsShouldProcess/ConfirmImpact=High the three
# PowerShell tenant-level teardowns under infra/ use (fix round 1, I5). Pass
# --dry-run to see what would happen without being prompted.
set -uo pipefail

ALLOW_AUTOMATION=false
DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    -AllowAutomation) ALLOW_AUTOMATION=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

if { [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; } && [ "${ALLOW_AUTOMATION}" != "true" ]; then
  echo "refusing to run unattended in CI without -AllowAutomation" >&2
  exit 1
fi

: "${MLS_AWS_ROLE_NAME:?set MLS_AWS_ROLE_NAME (the role name 02-athena-role.sh created)}"
: "${MLS_AWS_PROVIDER_ARN_V1:?set MLS_AWS_PROVIDER_ARN_V1 (printed by 01-oidc-provider.sh)}"
: "${MLS_AWS_PROVIDER_ARN_V2:?set MLS_AWS_PROVIDER_ARN_V2 (printed by 01-oidc-provider.sh)}"

# I6: never delete a provider this setup did not create. Unset, or any value
# other than the literal "false", takes the non-destructive path -- an
# unlabelled provider might be a DIFFERENT federation entirely in the
# sponsor's account (this account already has one, for Vercel), and deleting
# someone else's trust anchor is exactly the tenant-level mistake G3 exists to
# prevent.
V1_PREEXISTED="${MLS_AWS_PROVIDER_V1_PREEXISTED:-unknown}"
V2_PREEXISTED="${MLS_AWS_PROVIDER_V2_PREEXISTED:-unknown}"

echo "About to remove:"
echo "  role:          ${MLS_AWS_ROLE_NAME}"
if [ "${V1_PREEXISTED}" = "false" ]; then
  echo "  v1 provider:   ${MLS_AWS_PROVIDER_ARN_V1} (created by 01-oidc-provider.sh)"
else
  echo "  v1 provider:   ${MLS_AWS_PROVIDER_ARN_V1} -- SKIPPING (preexisted=${V1_PREEXISTED}, not created by this setup)"
fi
if [ "${V2_PREEXISTED}" = "false" ]; then
  echo "  v2 provider:   ${MLS_AWS_PROVIDER_ARN_V2} (created by 01-oidc-provider.sh)"
else
  echo "  v2 provider:   ${MLS_AWS_PROVIDER_ARN_V2} -- SKIPPING (preexisted=${V2_PREEXISTED}, not created by this setup)"
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "--dry-run: nothing deleted."
  exit 0
fi

if [ -t 0 ] && [ "${ALLOW_AUTOMATION}" != "true" ]; then
  read -r -p "Type the role name (${MLS_AWS_ROLE_NAME}) to confirm deletion: " CONFIRM
  if [ "${CONFIRM}" != "${MLS_AWS_ROLE_NAME}" ]; then
    echo "confirmation did not match; nothing deleted" >&2
    exit 1
  fi
fi

FAILURES=()

if aws iam delete-role-policy --role-name "${MLS_AWS_ROLE_NAME}" --policy-name "${MLS_AWS_ROLE_NAME}-permissions"; then
  echo "removed inline policy"
else
  echo "FAIL removing inline policy" >&2
  FAILURES+=("inline policy")
fi

if aws iam delete-role --role-name "${MLS_AWS_ROLE_NAME}"; then
  echo "removed role ${MLS_AWS_ROLE_NAME}"
else
  echo "FAIL removing role ${MLS_AWS_ROLE_NAME}" >&2
  FAILURES+=("role")
fi

if [ "${V1_PREEXISTED}" = "false" ]; then
  if aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V1}"; then
    echo "removed v1 provider"
  else
    echo "FAIL removing v1 provider" >&2
    FAILURES+=("v1 provider")
  fi
fi

if [ "${V2_PREEXISTED}" = "false" ]; then
  if aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V2}"; then
    echo "removed v2 provider"
  else
    echo "FAIL removing v2 provider" >&2
    FAILURES+=("v2 provider")
  fi
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "teardown incomplete: ${#FAILURES[*]} step(s) failed: ${FAILURES[*]}" >&2
  exit 1
fi
echo "removed"
