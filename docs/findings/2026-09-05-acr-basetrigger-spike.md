# Spike: can ACR Tasks track a Docker Hub base image? (P1 for lane 3)

**Date:** 2026-09-05
**Task:** Task 1 of `.superpowers/sdd/2026-09-05-acr-foundation/` — establish precondition
P1 before anything else in the ACR-foundation plan is built.
**Question:** Can an Azure Container Registry Task watch a base image hosted on Docker Hub
(not in ACR) and trigger a rebuild when that base image is patched?

## Verdict: INCONCLUSIVE

The probe could not reach the question it was sent to answer. ACR Tasks is rejected
outright for this subscription/registry pair — for **every** task creation attempt, with
and without a base-image trigger, with and without a Docker Hub base — so no evidence was
produced about whether a Docker Hub base specifically is accepted or ignored. This is not a
"no": we never got as far as the base-image-trigger mechanism at all. Reporting it as "no"
would overstate what was observed; reporting "yes" would be worse. The honest record is that
the probe was blocked one layer below the thing it was testing.

## What was run, in order, with exact output

### Step 0 — confirm subscription context

```
$ az account show -o json
{
  "environmentName": "AzureCloud",
  "homeTenantId": "c3571944-a345-43e4-bcb5-fd12ac314f8f",
  "id": "a8f2925d-d5e2-4edc-911e-c32041633a56",
  "isDefault": true,
  "managedByTenants": [],
  "name": "mls-demo-subscription",
  "state": "Enabled",
  "tenantDefaultDomain": "paulcfuquahotmail.onmicrosoft.com",
  "tenantDisplayName": "Default Directory",
  "tenantId": "c3571944-a345-43e4-bcb5-fd12ac314f8f",
  "user": {
    "name": "admin@paulcfuquahotmail.onmicrosoft.com",
    "type": "user"
  }
}
```

Confirmed: correct subscription (`mls-demo-subscription`).

### Step 1 — register the provider

```
$ az provider register --namespace Microsoft.ContainerRegistry --wait
(no output, exit 0)

$ az provider show -n Microsoft.ContainerRegistry --query registrationState -o tsv
Registered
```

### Step 2 — create a throwaway registry to probe with

```
$ az group create -n mls-rg-spike -l centralus --tags env=demo app=spike costCenter=demo owner=platform dataClassification=public managedBy=iac
{
  "id": "/subscriptions/a8f2925d-d5e2-4edc-911e-c32041633a56/resourceGroups/mls-rg-spike",
  "location": "centralus",
  "managedBy": null,
  "name": "mls-rg-spike",
  "properties": { "provisioningState": "Succeeded" },
  "tags": {
    "app": "spike", "costCenter": "demo", "dataClassification": "public",
    "env": "demo", "managedBy": "iac", "owner": "platform"
  },
  "type": "Microsoft.Resources/resourceGroups"
}

$ az acr create -n mlsspike10534 -g mls-rg-spike --sku Basic -l centralus
{
  ... (truncated for brevity — full JSON captured in the task transcript) ...
  "loginServer": "mlsspike10534.azurecr.io",
  "name": "mlsspike10534",
  "provisioningState": "Succeeded",
  "sku": { "name": "Basic", "tier": "Basic" },
  ...
}
```

Registry created at **Basic** SKU, as required by the G2 spend gate — confirmed in the
`sku` block above. No Standard/Premium tier was created at any point in this spike.

### Step 3 — create a task whose base is a Docker Hub image, and read back the trigger

The brief's command, run verbatim first:

```
$ ACR=$(az acr list -g mls-rg-spike --query "[0].name" -o tsv)   # -> mlsspike10534
$ printf 'FROM nginx:1.31-alpine\nRUN echo probe\n' > /tmp/Dockerfile.probe
$ az acr task create --registry "$ACR" --name basetrigger-probe \
    --context /dev/null --file /tmp/Dockerfile.probe \
    --base-image-trigger-enabled true --base-image-trigger-type All \
    --commit-trigger-enabled false
ERROR: (InvalidInputValue) Some of the properties of 'taskCreateParameters' are invalid.. InnerErrors: DockerBuildStep:Missing required property 'ImageNames'.
Code: InvalidInputValue
Message: Some of the properties of 'taskCreateParameters' are invalid.. InnerErrors: DockerBuildStep:Missing required property 'ImageNames'.
Target: request
Exception Details:	(MissingRequiredProperty) Missing required property 'ImageNames'.
	Code: MissingRequiredProperty
	Message: Missing required property 'ImageNames'.
	Target: DockerBuildStep
```

This first failure is unrelated to the Docker Hub question: `az acr task create` requires
naming an output image (`--image`), which the brief's command omitted. Retried with the
minimal required addition (`--image basetrigger-probe:{{.Run.ID}}`), everything else
unchanged:

```
$ az acr task create --registry "$ACR" --name basetrigger-probe \
    --image basetrigger-probe:{{.Run.ID}} \
    --context /dev/null --file /tmp/Dockerfile.probe \
    --base-image-trigger-enabled true --base-image-trigger-type All \
    --commit-trigger-enabled false
ERROR: (TasksOperationsNotAllowed) ACR Tasks requests for the registry mlsspike10534 and a8f2925d-d5e2-4edc-911e-c32041633a56 are not permitted. Please file an Azure support request at http://aka.ms/azuresupport for assistance.
Code: TasksOperationsNotAllowed
Message: ACR Tasks requests for the registry mlsspike10534 and a8f2925d-d5e2-4edc-911e-c32041633a56 are not permitted. Please file an Azure support request at http://aka.ms/azuresupport for assistance.
Target: request
```

**Control check — is this specific to the Docker Hub base, or to ACR Tasks as a whole on
this subscription?** Retried again with every base-image-trigger flag removed, so the only
thing being tested was "can this subscription create *any* ACR task at all":

```
$ az acr task create --registry "$ACR" --name minimal-probe \
    --image minimal-probe:{{.Run.ID}} \
    --context /dev/null --file /tmp/Dockerfile.probe \
    --commit-trigger-enabled false
ERROR: (TasksOperationsNotAllowed) ACR Tasks requests for the registry mlsspike10534 and a8f2925d-d5e2-4edc-911e-c32041633a56 are not permitted. Please file an Azure support request at http://aka.ms/azuresupport for assistance.
Code: TasksOperationsNotAllowed
Message: ACR Tasks requests for the registry mlsspike10534 and a8f2925d-d5e2-4edc-911e-c32041633a56 are not permitted. Please file an Azure support request at http://aka.ms/azuresupport for assistance.
Target: request
```

Identical error, with no base-image trigger involved at all. **This confirms the block is
at the level of "can this subscription use ACR Tasks", not "does ACR Tasks accept a Docker
Hub base."** `az acr task show` (the read-back step in the brief) was never reached because
no task was ever created.

### Ancillary check — is there a self-service feature flag to enable this?

```
$ az feature list --namespace Microsoft.ContainerRegistry -o table
Name                                                                    RegistrationState
----------------------------------------------------------------------  -------------------
Microsoft.ContainerRegistry/qac-3c737fd7-1389-4626-868f-c18df5790cb6    NotRegistered
Microsoft.ContainerRegistry/itn-3c737fd7-1389-4626-868f-c18df5790cb6    NotRegistered
Microsoft.ContainerRegistry/ArchiveBeta                                 NotRegistered
Microsoft.ContainerRegistry/DeprecatedAPI                               NotRegistered
... (14 more region/beta flags, all NotRegistered)
Microsoft.ContainerRegistry/TasksPrivatePreview                         NotRegistered
```

Nothing here names a "Tasks" capability that this session can self-register (and doing so
speculatively is outside this spike's scope — it would be a config change to production
infra behavior, not a read of it). The registry's own error message points at an Azure
support ticket, not a subscription-level `az feature register`, as the resolution path.

### Step 5 — tear the spike down

```
$ az group delete -n mls-rg-spike --yes --no-wait
(no output, exit 0)

$ az group show -n mls-rg-spike --query "properties.provisioningState" -o tsv
Deleting
```

Deletion was submitted and observed in progress (`Deleting`) before this document was
written. `mls-rg-spike` is RG-scoped demo/spike infrastructure, so its teardown is
gate-free per CLAUDE.md.

## Reasoning

The working agreement in this repo's CLAUDE.md is explicit: *"An audit that cannot see a
thing says so; it never reports the thing as absent."* That is exactly this situation. The
probe hit a wall (`TasksOperationsNotAllowed`) one layer below the mechanism P1 asks about.
The control check (retrying with no base-image-trigger flags at all, and getting the
identical error) rules out the interpretation "ACR Tasks works fine but rejects Docker Hub
bases specifically" — if that were true, the minimal task with no trigger and an ACR-hosted
concept would have succeeded. It did not. So this is not evidence against P1; it is an
absence of evidence for or against P1, produced by a different, subscription-level
restriction on ACR Tasks entirely.

Two things are worth separating, because they carry different next actions:

1. **Whether ACR Tasks can track a Docker Hub base (P1 itself).** Still unknown. Microsoft's
   published ACR Tasks documentation states base-image triggers support registries other
   than the task's own registry, Docker Hub included, subject to the task being able to
   resolve and poll the base manifest. That is a documentation claim, not something this
   session verified against a live registry, and this repo's culture (per CLAUDE.md) is to
   distrust a claim about another system that was not resolved against that system. This
   spike does not close that gap.
2. **Whether ACR Tasks is usable at all in `mls-demo-subscription`.** This is now
   established: no, not without first filing the Azure support request the error message
   names. This is a new, independent blocker, separate from P1, and it blocks *any* use of
   ACR Tasks in this estate — not just the Docker Hub base-trigger scenario lane 3 depends
   on.

## Recommendation

Per the plan's own stop condition, this spike does not clear P1 as "yes," and the plan says
nothing else in lane 3 should be built until P1 is answered. Given the result is
INCONCLUSIVE rather than a clean NO, the recommendation is:

- **Do not proceed with building lane 3 (Task 7 and onward) yet.** The precondition remains
  unverified, and building on an unverified precondition is the exact failure mode this spike
  exists to prevent.
- **File the Azure support request** named in the `TasksOperationsNotAllowed` error to enable
  ACR Tasks for `a8f2925d-d5e2-4edc-911e-c32041633a56`, then re-run this exact spike (Steps
  2–4) to get a real answer to P1. Until that support request resolves, this subscription
  cannot answer the question at all, by any command.
- **Amend the spec's §2 and §8** to record that P1 is blocked on an unresolved
  subscription-level restriction, not decided against — and that lane 3's fallback
  (scheduled rebuild) is the safe default until a rerun produces a real yes or no.

## Cleanup record

- `mls-rg-spike` (containing the Basic ACR `mlsspike10534`) — deletion submitted via
  `az group delete -n mls-rg-spike --yes --no-wait` and observed in `Deleting` state. No
  task was ever successfully created inside it (both creation attempts errored before any
  task object was persisted), so there is nothing else to clean up.
- No spend-profile increase occurred: the only registry created was Basic-tier, and it is
  being deleted.
