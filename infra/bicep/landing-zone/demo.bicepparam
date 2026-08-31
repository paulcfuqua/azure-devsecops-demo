// L2 demo parameters. IDs are never committed (CLAUDE.md hard rule 5 / spec F5):
// the subscription ID and region are read from environment variables that the
// layer-02 workflow exports from the GitHub `demo` environment. The empty /
// placeholder defaults keep local `bicep build-params` green with no env set —
// an empty subscription ID compiles but skips the NIST assignment.
using './main.bicep'

// ESTATE IDENTITY. naming.bicep holds the defaults and every name derives from
// these two; estate.env (locally) or the `demo` GitHub environment (in CI) is how
// a deployment overrides them. The literal fallbacks below MUST equal
// naming.bicep's defaultCompanyPrefix / defaultEnv - verification/tests asserts
// exactly that, because a bicepparam cannot import a var from the template it
// targets and an unchecked second copy is how two sources of truth start.
//
// empty(...) ? default : value, NOT readEnvironmentVariable's own default argument:
// that default fires only when the variable is UNSET, and an undefined GitHub
// variable expands to the EMPTY STRING (F26). Without this guard a workflow passing
// an unset vars.MLS_COMPANY_PREFIX would name every resource '-rg-platform'.
param companyPrefix = empty(readEnvironmentVariable('MLS_COMPANY_PREFIX', '')) ? 'mls' : readEnvironmentVariable('MLS_COMPANY_PREFIX', '')

param demoSubscriptionId = readEnvironmentVariable('AZURE_SUBSCRIPTION_ID', '')

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus')

// Empty is the normal case: policy-assignment identities are created in the estate's region
// and STAY there, because an assignment's location cannot be updated. Set only on an estate
// whose region changed after L2 first ran.
param policyAssignmentLocation = readEnvironmentVariable('MLS_POLICY_ASSIGNMENT_LOCATION', '')

// [derived] Single-region guardrail: the demo lives entirely in AZURE_LOCATION.
param allowedLocations = [
  readEnvironmentVariable('AZURE_LOCATION', 'eastus')
]
