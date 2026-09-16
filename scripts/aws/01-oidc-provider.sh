#!/usr/bin/env bash
# Create the IAM OIDC identity providers that trust this Entra tenant -- for
# BOTH possible token issuers.
#
# SPONSOR-RUN. Agents author this file; the sponsor executes it. AWS writes are
# outside the 2026-08-29 amendment, which covers Azure, Entra, Fabric and GitHub.
#
# TWO providers, not one (fix round 1, C1). infra/entra/manifest.json now
# DECLARES "requestedAccessTokenVersion": 1 for the aws-athena app, which is
# what Entra's null default already meant -- so the token Azure presents
# carries iss = https://sts.windows.net/<tenant>/, the v1 issuer, not the v2.0
# issuer this script originally assumed alone. Before that fix the whole trust
# chain rested on an undeclared default nobody had chosen, and a provider
# registered for only one issuer fails every AssumeRoleWithWebIdentity call
# the day reality disagrees with the guess, as an opaque AccessDenied naming
# no field. The v1 provider is the one in use; the v2 provider costs one extra
# API round trip and means a later declared change to version 2 needs no AWS
# edit at all. infra/entra/manifest.json owns declaring that value and
# verification/tests/failure-classes.Tests.ps1 asserts the two agree -- this
# script only consumes it.
#
# The v2 issuer is RESOLVED from the tenant's discovery document, never typed:
# a trust policy that is one character wrong fails as AccessDenied with no
# indication of which field was rejected. The v1 issuer has no discovery
# document of its own to resolve -- https://sts.windows.net/<tenant-id>/ is
# Entra's fixed, documented v1 issuer shape, built from the same resolved
# tenant id.
set -euo pipefail

: "${MLS_TENANT_ID:?set MLS_TENANT_ID (az account show --query tenantId -o tsv)}"
: "${MLS_AWS_AUDIENCE:?set MLS_AWS_AUDIENCE (identifierUris[0] of the aws-athena app -- api://<tenant-id>/mls-aws-athena-demo). This is the aud claim carried by a v1 token.}"
: "${MLS_AWS_APP_ID:?set MLS_AWS_APP_ID (the aws-athena application/client id GUID). This is the aud claim carried by a v2 token, needed only if requestedAccessTokenVersion is ever changed to 2.}"

V2_ISSUER=$(curl -sf "https://login.microsoftonline.com/${MLS_TENANT_ID}/v2.0/.well-known/openid-configuration" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['issuer'])")
# Strip a trailing \r everywhere a value crosses python or the aws CLI (fix
# round 1, verified by testing on this exact platform): on some platforms
# python's stdout is opened in text mode and translates the final \n to
# \r\n, and bash's command substitution strips only the \n, leaving a
# carriage return silently glued to the end of the captured value. That is
# invisible in an echoed line but breaks an exact string comparison outright
# -- which is precisely what 02 and 03 do with values captured this way.
V2_ISSUER="${V2_ISSUER//$'\r'/}"
V1_ISSUER="https://sts.windows.net/${MLS_TENANT_ID}/"

echo "resolved v2 issuer: ${V2_ISSUER}"
echo "known v1 issuer:    ${V1_ISSUER}"
echo "audience (v1 aud):  ${MLS_AWS_AUDIENCE}"
echo "app id (v2 aud):    ${MLS_AWS_APP_ID}"

# Finds an existing provider by its ACTUAL stored Url, read back from AWS --
# never by matching a substring of its ARN. list-open-id-connect-providers
# returns only ARNs; matching on e.g. the hostname before the first slash
# would bind to a DIFFERENT tenant's provider for the same identity host, or
# to an unrelated federation entirely (fix round 1, I3).
find_provider_by_url() {
  local want="$1" arn url raw_arns
  local -a arns=()
  raw_arns=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text)
  raw_arns="${raw_arns//$'\r'/}"
  read -r -a arns <<< "${raw_arns}"
  # An account with no providers at all is the FIRST-RUN case, not an error --
  # and "${arns[@]}" on an empty array is an unbound-variable abort under
  # set -u on bash before 4.4 (including the 3.2 macOS still ships). Count
  # first; ${#arr[@]} is safe on every version.
  if [ "${#arns[@]}" -eq 0 ]; then
    return 1
  fi
  # Compared with the trailing slash normalised off BOTH sides. AWS stores the
  # issuer scheme-stripped, and the v1 issuer legitimately ends in "/" -- if
  # AWS ever normalises that away, an exact compare would miss a provider that
  # exists and the create call would then fail EntityAlreadyExists. Nothing
  # downstream depends on this normalisation: 02 derives its condition keys
  # from AWS's own read-back of Url, never from this string.
  want="${want%/}"
  for arn in "${arns[@]}"; do
    if ! url=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${arn}" --query Url --output text 2>/dev/null); then
      continue
    fi
    url="${url//$'\r'/}"
    if [ "${url%/}" = "${want}" ]; then
      printf '%s\n' "${arn}"
      return 0
    fi
  done
  return 1
}

# Ensures a provider for $1 (full https:// issuer) exists with $2 registered
# as a client id, then VERIFIES it landed by reading ClientIDList back -- a
# create or add-client-id call that exits zero is not evidence the audience is
# there (fix round 1, I3; the same standard 03-verify.sh applies elsewhere).
# Prints "arn|preexisted" on stdout; all diagnostic text goes to stderr so it
# never pollutes that captured value.
ensure_provider() {
  local issuer="$1" client_id="$2" label="$3"
  local want_url="${issuer#https://}"
  local arn preexisted landed

  if arn=$(find_provider_by_url "${want_url}"); then
    preexisted=true
    echo "${label}: provider exists: ${arn}" >&2
    # Idempotent per AWS's own documented behaviour: adding a client id that is
    # already registered succeeds without error. A real failure here (denied,
    # throttled) is NOT swallowed -- it propagates under set -e, rather than
    # being reported as the misleading "already registered" the original draft
    # printed for every non-zero exit regardless of cause.
    aws iam add-client-id-to-open-id-connect-provider \
      --open-id-connect-provider-arn "${arn}" --client-id "${client_id}"
  else
    preexisted=false
    arn=$(aws iam create-open-id-connect-provider \
      --url "${issuer}" --client-id-list "${client_id}" \
      --query OpenIDConnectProviderArn --output text)
    arn="${arn//$'\r'/}"
    echo "${label}: provider created: ${arn}" >&2
  fi

  landed=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${arn}" \
    --query ClientIDList --output json)
  landed="${landed//$'\r'/}"
  case "${landed}" in
    *"\"${client_id}\""*) ;;
    *)
      echo "ERROR: ${label} provider ${arn} does not list ${client_id} in ClientIDList after registration." >&2
      echo "Landed value: ${landed}" >&2
      exit 1
      ;;
  esac
  printf '%s|%s\n' "${arn}" "${preexisted}"
}

V1_RESULT=$(ensure_provider "${V1_ISSUER}" "${MLS_AWS_AUDIENCE}" "v1 (sts.windows.net)")
V1_ARN="${V1_RESULT%%|*}"
V1_PREEXISTED="${V1_RESULT##*|}"

V2_RESULT=$(ensure_provider "${V2_ISSUER}" "${MLS_AWS_APP_ID}" "v2 (login.microsoftonline.com)")
V2_ARN="${V2_RESULT%%|*}"
V2_PREEXISTED="${V2_RESULT##*|}"

echo "--- v1 provider (readback) ---"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${V1_ARN}" \
  --query "{url:Url,audiences:ClientIDList}" --output json

echo "--- v2 provider (readback) ---"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${V2_ARN}" \
  --query "{url:Url,audiences:ClientIDList}" --output json

echo "export MLS_AWS_PROVIDER_ARN_V1=${V1_ARN}"
echo "export MLS_AWS_PROVIDER_ARN_V2=${V2_ARN}"
echo "export MLS_AWS_PROVIDER_V1_PREEXISTED=${V1_PREEXISTED}"
echo "export MLS_AWS_PROVIDER_V2_PREEXISTED=${V2_PREEXISTED}"
