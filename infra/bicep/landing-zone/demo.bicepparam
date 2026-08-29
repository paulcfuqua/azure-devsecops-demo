// L2 demo parameters. IDs are never committed (CLAUDE.md hard rule 5 / spec F5):
// the subscription ID and region are read from environment variables that the
// layer-02 workflow exports from the GitHub `demo` environment. The empty /
// placeholder defaults keep local `bicep build-params` green with no env set —
// an empty subscription ID compiles but skips the NIST assignment.
using './main.bicep'

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
