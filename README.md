# Ignite Coffee

A small Azure Monitor Health Models demo with a real three-tier AKS application, Event Hubs, Key Vault and Blob Storage.

The website accepts orders, but the worker starts with an intentional processing fault. Only **AKS: ignitecoffee-aks (order-worker)** should be Unhealthy. Its **Suppressed** impact keeps the other entities Healthy when their own signals are healthy. This demonstrates impact control: green journey/root states deliberately do **not** prove that coffee was prepared.

```text
Browser / internal load -> frontend -> API -> Event Hubs -> worker -> Blob Storage
                                       |
                                   Key Vault

Container stdout -> Log Analytics -> Health Model
Azure platform metrics -----------> Health Model
AKS Prometheus metrics -> Azure Monitor workspace
```

**Validation status:** local tests and Bicep compilation cover this revision. Service-side validation and live evaluation of the current workload/model remain pending. A successful deployment alone does not establish health.

## Repository

| Path | Purpose |
|---|---|
| `infra\main.bicep` | Two-node AKS, supporting services, identities, networking and monitoring |
| `infra\healthmodel.bicep` | Separate health model, layout, metadata, relationships and alerts |
| `infra\signals.json` | Shared components, sources and thresholds used by Bicep and preflight |
| `infra\queries\` | Exact failure-count and heartbeat-age KQL |
| `workload\` | One Python image running frontend, API, worker or internal load |
| `scripts\` | Confirmed deployment phases, read-only signal checks and fault control |
| `tests\` | Workload behavior and offline deployment/preflight checks |
| [Plan](docs/healthmodel/plan.md) / [Specification](docs/healthmodel/modelspec.md) | Demo story and current model contract |

## Deploy

Use a dedicated disposable resource group. Requires PowerShell 7, an existing Azure CLI user login, Bicep, kubectl and kubelogin. The operator needs permission to deploy resources, assign roles and query Log Analytics. No health-model CLI extension or local Docker engine is required; ACR Tasks builds the image.

Register the required providers beforehand: `Microsoft.ContainerService`, `Microsoft.ContainerRegistry`, `Microsoft.ManagedIdentity`, `Microsoft.EventHub`, `Microsoft.KeyVault`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, `Microsoft.Monitor`, `Microsoft.Insights`, `Microsoft.Network`, `Microsoft.Compute`, `Microsoft.CloudHealth` and `Microsoft.AlertsManagement`. Scripts do not register providers or bypass policy.

Defaults are **Sweden Central for the workload** and **UK South for the model**. Confirm that your subscription supports the SKU, quota, API and regions before deployment. Use the same `-Name` in every phase if overriding `ignitecoffee`.

```powershell
$subscription = '<subscription-id>'
$group = 'rg-ignite-coffee'

# Read-only: inspect available model regions and APIs.
az provider show --subscription $subscription -n Microsoft.CloudHealth `
  --query "resourceTypes[?resourceType=='healthmodels'].{regions:locations,versions:apiVersions}"

# Each deployment phase prints its scope and asks before writing.
.\scripts\Deploy.ps1 -Phase Infrastructure -SubscriptionId $subscription -ResourceGroup $group
.\scripts\Deploy.ps1 -Phase Workload -SubscriptionId $subscription -ResourceGroup $group

# Wait for logs/metrics, then require verified source telemetry.
.\scripts\Test-Signals.ps1 -SubscriptionId $subscription -ResourceGroup $group
.\scripts\Deploy.ps1 -Phase Model -SubscriptionId $subscription -ResourceGroup $group
```

`-WhatIf` previews script actions without deploying. Override `-Location` on Infrastructure or `-ModelLocation` on Model when needed. For updates, deploy **Workload before Model**: the model requires the `worker-pod` and `eventhub` log flows emitted by this workload version.

Preflight checks 14 KQL measurements and seven distinct metrics, covering 25 explicit signals. The intended worker failure is allowed; other verified Degraded/Unhealthy signals block the demo deployment. Missing heartbeats also block deployment. Results go to ignored `.build\signal-verification.json`. `-AllowUnverifiedSignals` is an explicit exception for reviewed evidence gaps, not a way to skip the new workload rollout.

The model has 16 entities, 15 relationships, two automatic Resource Health signals and two Sev2 journey alerts. Notifications have **no routing by default**; supply reviewed `-ActionGroupIds` to the Model phase if needed. No journey alert fires for the deliberately suppressed worker fault.

## Run the demo

1. Start a tunnel and open `http://localhost:8080`:

   ```powershell
   kubectl --kubeconfig .build\kubeconfig -n ignite-demo port-forward service/frontend 8080:8080
   ```

2. Read the menu and place an order. It is accepted but remains pending. Internal load also places an order every 15 seconds.
3. Open **Azure Monitor > Health Models > ignitecoffee-health**. Only the worker AKS leaf should be red. Show its `failed-operations` signal, `worker-pod` container logs and **Suppressed** impact.
4. Recover the worker:

   ```powershell
   .\scripts\Set-Fault.ps1 -State Healthy
   ```

   The pending order becomes ready. Allow roughly 3-8 minutes for ingestion, the two-minute failure window and model evaluation to clear the red leaf.
5. Reset with `.\scripts\Set-Fault.ps1 -State Broken`. Re-running the Workload phase also resets the fault.

Kubernetes probes check process availability, not coffee preparation. Stopping the whole worker or breaking a real dependency is a different failure and can turn other entities red. Inspect signal timestamps/errors: Unknown is missing evidence, not Healthy, and default WorstOf rollup excludes Unknown inputs.

## Access, monitoring and costs

AKS has a **public, Entra/RBAC-protected API endpoint**, private node subnets, disabled local accounts and no public application ingress. The infrastructure assigns the operator AKS RBAC Cluster Admin on this demo cluster; `-OperatorPrincipalId` selects a different Entra user. Workload access uses ignored `.build\kubeconfig` and the existing Azure CLI login.

Key Vault uses a private endpoint/DNS and purge protection. Event Hubs and Storage use authenticated public endpoints with local/shared-key access disabled. The API and worker share a workload identity. See the [permission table](docs/healthmodel/modelspec.md#permissions) for the nine scoped assignments.

Log Analytics receives container logs and diagnostics from AKS, Key Vault, Event Hubs, Storage and the Blob service. A separate Azure Monitor workspace receives managed Prometheus metrics; this model does not use PromQL signals or Grafana. Two Standard_D2s_v5 nodes provide room for monitoring agents as well as the app.

This is **small, not free**: nodes, disks, load balancer/IP, private endpoint/DNS, ACR, Event Hubs, telemetry and Health Models can incur charges. All-log diagnostics, especially AKS audit logs, increase ingestion. Run only for rehearsal/demo time.

The sample has no application login, TLS ingress, autoscaling or multi-replica availability. A single worker replays one-day retained, trusted demo events after restart, using stable Blob names for idempotent writes. There is no durable checkpoint or poison-event handling; do not use it as a production queue consumer.

After confirming the resource group contains **only this demo**, delete it through the Azure portal. Key Vault soft deletion retains its name for seven days; purge protection prevents early permanent deletion. Remove local `.build\kubeconfig` when finished.

## Local checks

```powershell
New-Item .build -ItemType Directory -Force | Out-Null
az bicep build --file .\infra\main.bicep --outfile .\.build\main.json
az bicep build --file .\infra\healthmodel.bicep --outfile .\.build\healthmodel.json
python -m venv .\.build\venv
.\.build\venv\Scripts\python.exe -m pip install -r .\workload\requirements.txt
.\.build\venv\Scripts\python.exe -m unittest discover -s .\tests -v
.\tests\Test-Deployment.ps1
```

The PowerShell tests replace Azure CLI/kubectl with command doubles and restore generated artifacts. No tests deploy resources or switch a live fault.

## References

Inspired by [Azure/kcjpn26demo](https://github.com/Azure/kcjpn26demo) (AKS/model patterns) and [Azure/octoahm0826](https://github.com/Azure/octoahm0826) (business flows and Key Vault). This sample adds its own Event Hubs producer/consumer and uses the `Microsoft.CloudHealth` API `2026-11-01`.
