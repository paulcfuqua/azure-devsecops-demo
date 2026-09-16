#!/usr/bin/env bash
# Read back what was created, and compare it against what was asked for.
#
# No `set -e` (fix round 1, I4): a run against a live AWS account is an
# expensive, rate-limited observation, and the original draft's `set -e` meant
# the first failing check truncated the report before anything after it ran --
# so a sponsor debugging an AccessDenied got exactly one fact per twenty-minute
# attempt. This script runs every check, prints PASS or FAIL for each, and
# exits non-zero at the end if any failed.
set -uo pipefail

# Windows path fix follow-up, 2026-09-16: fill in any variable NOT already
# set in this shell from the anchor file 01-oidc-provider.sh and
# 02-athena-role.sh write, so a sponsor who did not hand-paste their `export`
# lines does not die here on an unset-variable error. A variable already
# exported in this shell wins over the file -- this only fills gaps, it never
# overrides. Resolved to this script's own directory, not the caller's cwd.
# Silently skipped if the file does not exist.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANCHOR_ENV="${SCRIPT_DIR}/.aws-anchor.env"
if [ -f "${ANCHOR_ENV}" ]; then
  echo "found ${ANCHOR_ENV} (written by 01-oidc-provider.sh / 02-athena-role.sh) -- filling in any variable not already set in this shell" >&2
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

: "${MLS_AWS_PROVIDER_ARN_V1:?set MLS_AWS_PROVIDER_ARN_V1 (printed by 01-oidc-provider.sh)}"
: "${MLS_AWS_PROVIDER_ARN_V2:?set MLS_AWS_PROVIDER_ARN_V2 (printed by 01-oidc-provider.sh)}"
: "${MLS_AWS_AUDIENCE:?set MLS_AWS_AUDIENCE (the v1 aud -- identifierUris[0] of the aws-athena app)}"
: "${MLS_AWS_APP_ID:?set MLS_AWS_APP_ID (the v2 aud -- the aws-athena application/client id GUID)}"
: "${MLS_AWS_PRINCIPAL_ID:?set MLS_AWS_PRINCIPAL_ID (the managed identity principal id -- the sub claim)}"
: "${MLS_AWS_ROLE_NAME:?set MLS_AWS_ROLE_NAME (printed by 02-athena-role.sh)}"
: "${MLS_AWS_REGION:?set MLS_AWS_REGION (e.g. us-east-1)}"
: "${MLS_GLUE_DATABASE:?set MLS_GLUE_DATABASE (the Glue Data Catalog database name)}"
: "${MLS_ATHENA_WORKGROUP:?set MLS_ATHENA_WORKGROUP (e.g. primary)}"
: "${MLS_ATHENA_OUTPUT:?set MLS_ATHENA_OUTPUT (e.g. s3://<bucket>/athena-results/) -- the value Task 6 must pass explicitly if the workgroup enforces none}"

FAILURES=()

# Records a PASS/FAIL line without ever stopping the script (I4's whole point).
check() {
  local label="$1" actual="$2" expected="$3"
  if [ "${actual}" = "${expected}" ]; then
    echo "PASS  ${label}: ${actual}"
  else
    echo "FAIL  ${label}: got '${actual}', expected '${expected}'"
    FAILURES+=("${label}")
  fi
}

echo "=== v1 provider (sts.windows.net) ==="
if V1_JSON=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V1}" \
    --query "{url:Url,audiences:ClientIDList}" --output json 2>&1); then
  echo "${V1_JSON}"
  V1_AUD_FOUND=$(printf '%s' "${V1_JSON}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(sys.argv[1] in d.get('audiences', []))
" "${MLS_AWS_AUDIENCE}")
  # Strip a trailing \r everywhere a comparison value crosses python (fix
  # round 1, verified by testing on this platform): a text-mode stdout can
  # translate the final \n to \r\n, and command substitution strips only the
  # \n -- an invisible difference that makes an exact-match check FAIL on
  # values that are actually identical.
  V1_AUD_FOUND="${V1_AUD_FOUND//$'\r'/}"
  check "v1 provider ClientIDList contains MLS_AWS_AUDIENCE" "${V1_AUD_FOUND}" "True"
else
  echo "FAIL  v1 provider readable: ${V1_JSON}"
  FAILURES+=("v1 provider readable")
fi

echo "=== v2 provider (login.microsoftonline.com) ==="
if V2_JSON=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${MLS_AWS_PROVIDER_ARN_V2}" \
    --query "{url:Url,audiences:ClientIDList}" --output json 2>&1); then
  echo "${V2_JSON}"
  V2_AUD_FOUND=$(printf '%s' "${V2_JSON}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(sys.argv[1] in d.get('audiences', []))
" "${MLS_AWS_APP_ID}")
  V2_AUD_FOUND="${V2_AUD_FOUND//$'\r'/}"
  check "v2 provider ClientIDList contains MLS_AWS_APP_ID" "${V2_AUD_FOUND}" "True"
else
  echo "FAIL  v2 provider readable: ${V2_JSON}"
  FAILURES+=("v2 provider readable")
fi

echo "=== role trust policy ==="
if TRUST_JSON=$(aws iam get-role --role-name "${MLS_AWS_ROLE_NAME}" \
    --query "Role.AssumeRolePolicyDocument" --output json 2>&1); then
  echo "${TRUST_JSON}"
  # Pull every aud/sub condition value out of every statement and compare the
  # SET against what was asked for, rather than assuming statement order or
  # count -- the policy now has two statements (fix round 1, C1).
  #
  # ONE VALUE PER CAPTURE, and no mapfile. mapfile is a bash 4 builtin and
  # macOS still ships bash 3.2, where it is simply not found -- and under this
  # script's `set -u` that does not stop at the missing builtin: the array
  # stays unset and the next line aborts the whole run on an unbound variable,
  # so a sponsor on a Mac would lose every check after this point. That is
  # exactly the stop-at-the-first-fact behaviour I4 removed from this script.
  # Splitting one two-line capture in bash was the other option and is worse:
  # command substitution eats trailing newlines, so an empty second line
  # collapses and the sub check silently reads the AUD line instead.
  FOUND_AUDS=$(printf '%s' "${TRUST_JSON}" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
values = []
for stmt in doc.get('Statement', []):
    cond = stmt.get('Condition', {}).get('StringEquals', {})
    for k, v in cond.items():
        if k.endswith(':aud'):
            values.append(v)
print(','.join(sorted(values)))
")
  FOUND_AUDS="${FOUND_AUDS//$'\r'/}"
  FOUND_SUBS=$(printf '%s' "${TRUST_JSON}" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
values = []
for stmt in doc.get('Statement', []):
    cond = stmt.get('Condition', {}).get('StringEquals', {})
    for k, v in cond.items():
        if k.endswith(':sub'):
            values.append(v)
print(','.join(sorted(values)))
")
  FOUND_SUBS="${FOUND_SUBS//$'\r'/}"
  EXPECTED_AUDS=$(python3 -c "
import sys
print(','.join(sorted([sys.argv[1], sys.argv[2]])))
" "${MLS_AWS_AUDIENCE}" "${MLS_AWS_APP_ID}")
  EXPECTED_AUDS="${EXPECTED_AUDS//$'\r'/}"
  EXPECTED_SUBS=$(python3 -c "
import sys
print(','.join(sorted([sys.argv[1], sys.argv[1]])))
" "${MLS_AWS_PRINCIPAL_ID}")
  EXPECTED_SUBS="${EXPECTED_SUBS//$'\r'/}"
  check "trust policy aud set (v1 audience + v2 app id)" "${FOUND_AUDS}" "${EXPECTED_AUDS}"
  check "trust policy sub set (both statements name the same principal)" "${FOUND_SUBS}" "${EXPECTED_SUBS}"
else
  echo "FAIL  role trust policy readable: ${TRUST_JSON}"
  FAILURES+=("role trust policy readable")
fi

echo "=== attached inline policy ==="
if POLICY_JSON=$(aws iam get-role-policy --role-name "${MLS_AWS_ROLE_NAME}" \
    --policy-name "${MLS_AWS_ROLE_NAME}-permissions" --query PolicyDocument --output json 2>&1); then
  echo "${POLICY_JSON}"
else
  echo "FAIL  inline policy readable: ${POLICY_JSON}"
  FAILURES+=("inline policy readable")
fi

echo "=== workgroup reachable, output location, and capped ==="
# The bytes-scanned cutoff is the spend control (spec section 6). Athena bills
# per terabyte scanned, so an unbounded workgroup is in principle an uncapped
# bill reachable by an agent writing its own SQL.
#
# MEASURED, IT IS NOT A RISK HERE: the sponsor reports USD 0.20 of Athena
# spend across a month on this dataset. The check stays because the reasoning
# is right and the dataset could grow, but it PRINTS and does not block -- a
# warning that demands action on a twenty-cent bill is how real warnings get
# ignored.
if WG_JSON=$(aws athena get-work-group --work-group "${MLS_ATHENA_WORKGROUP}" \
    --query "WorkGroup.{name:Name,state:State,bytesScannedCutoff:Configuration.BytesScannedCutoffPerQuery,outputLocation:Configuration.ResultConfiguration.OutputLocation}" \
    --output json 2>&1); then
  echo "${WG_JSON}"

  CUTOFF=$(printf '%s' "${WG_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytesScannedCutoff') or '')")
  CUTOFF="${CUTOFF//$'\r'/}"
  if [ -z "${CUTOFF}" ]; then
    echo "WARNING: no per-query bytes-scanned cutoff on ${MLS_ATHENA_WORKGROUP}." >&2
    echo "An agent writes its own SQL; set one before pointing it at this workgroup:" >&2
    echo "  aws athena update-work-group --work-group ${MLS_ATHENA_WORKGROUP} \\" >&2
    echo "    --configuration-updates BytesScannedCutoffPerQuery=1073741824" >&2
  fi

  # I2: Task 6 must pass ResultConfiguration.OutputLocation explicitly on
  # every StartQueryExecution call if the workgroup enforces no default --
  # this is reported, never assumed, since a workgroup can be reconfigured.
  OUTPUT_LOCATION=$(printf '%s' "${WG_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('outputLocation') or '')")
  OUTPUT_LOCATION="${OUTPUT_LOCATION//$'\r'/}"
  if [ -z "${OUTPUT_LOCATION}" ]; then
    echo "NOTE: ${MLS_ATHENA_WORKGROUP} enforces no default output location."
    echo "      Task 6's caller MUST pass MLS_ATHENA_OUTPUT (below) as"
    echo "      ResultConfiguration.OutputLocation on every query."
  else
    echo "workgroup default output location: ${OUTPUT_LOCATION}"
  fi
else
  echo "FAIL  workgroup readable: ${WG_JSON}"
  FAILURES+=("workgroup readable")
fi

echo ""
echo "=== send back: these six lines, verbatim ==="
if ROLE_ARN_OUT=$(aws iam get-role --role-name "${MLS_AWS_ROLE_NAME}" --query Role.Arn --output text 2>/dev/null); then
  ROLE_ARN_OUT="${ROLE_ARN_OUT//$'\r'/}"
  echo "export MLS_AWS_ROLE_ARN=${ROLE_ARN_OUT}"
else
  echo "export MLS_AWS_ROLE_ARN=UNKNOWN  # role was not readable above -- see FAIL lines"
fi
echo "export MLS_AWS_AUDIENCE=${MLS_AWS_AUDIENCE}"
echo "export MLS_AWS_REGION=${MLS_AWS_REGION}"
echo "export MLS_GLUE_DATABASE=${MLS_GLUE_DATABASE}"
echo "export MLS_ATHENA_WORKGROUP=${MLS_ATHENA_WORKGROUP}"
echo "export MLS_ATHENA_OUTPUT=${MLS_ATHENA_OUTPUT}"

echo ""
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "=== ${#FAILURES[@]} check(s) FAILED ==="
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "=== all checks PASSED ==="
