// L2 demo parameters. IDs are never committed (CLAUDE.md hard rule 5 / spec F5):
// the subscription ID and region are read from environment variables that the
// layer-02 workflow exports from the GitHub `demo` environment. The empty /
// placeholder defaults keep local `bicep build-params` green with no env set —
// an empty subscription ID compiles but skips subscription placement + NIST.
using './main.bicep'

param demoSubscriptionId = readEnvironmentVariable('AZURE_SUBSCRIPTION_ID', '')

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus')

// [derived] Single-region guardrail: the demo lives entirely in AZURE_LOCATION.
param allowedLocations = [
  readEnvironmentVariable('AZURE_LOCATION', 'eastus')
]
