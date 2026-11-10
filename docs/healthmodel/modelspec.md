# Ignite Coffee model specification

This is the current **source contract**, not a live deployment report. Service-side validation and evaluated-health verification of this revision remain pending. The deployment runbook is in the [README](../../README.md).

## Intent and scope

One application model covers browsing and ordering across an AKS frontend, API and worker, with Key Vault, Event Hubs and Blob Storage.

The intended fault is failed coffee preparation in a running worker. Only `order-worker-aks` is Unhealthy. Its **Suppressed** impact keeps every other entity Healthy when their own evidence is healthy. This intentionally excludes the processing failure from journey/root health; it does not prove that customers receive prepared coffee. The 99.9% journey objectives are illustrative, not production SLOs.

No payments, inventory, email, multi-region failover or production queue recovery is implemented.

## Entities and relationships

The model has 16 entities and 15 parent/child relationships. Root identity is the model name; the template updates that same automatically created root to manage its label/layout.

| Entity | Parent | Measurement / expected state during the isolated fault |
|---|---|---|
| Root: `healthModelName` | None | Worst journey state; Healthy |
| `browse` | Root | Worst component state; Healthy |
| `order` | Root | Worst component state; Healthy |
| `browse-web`, `browse-api` | `browse` | Process/dependency failures and heartbeat age; Healthy |
| `order-web`, `order-api` | `order` | Process/dependency failures and heartbeat age; Healthy |
| `order-worker` | `order` | Worker process/Blob probe evidence, not processing success; Healthy |
| `browse-web-aks`, `browse-api-aks` | Corresponding browse component | Shared AKS CPU; Healthy |
| `order-web-aks`, `order-api-aks` | Corresponding order component | Shared AKS CPU; Healthy |
| `order-worker-aks` | `order-worker` | Shared CPU and worker processing logs; **Unhealthy, Suppressed impact** |
| `menu-vault` | `browse-api` | Vault metrics/Resource Health; Healthy |
| `order-events` | `order-api` | Actual publish-result/freshness logs; Healthy |
| `order-storage` | `order-worker` | Storage metrics/Resource Health; Healthy |

Other entities retain Standard impact and WorstOf rollup. Unknown inputs are excluded by default; a green entity may still contain Unknown signals. No missing metric is replaced with a fabricated healthy value.

Readable relationship labels and `dependencyType` tags explain the edges. Entity tags show journey, purpose, access method or workload namespace. These tags and canvas positions do not affect health.

## Signals

[`infra\signals.json`](../../infra/signals.json) is shared by Bicep and the source verifier. It owns component role/flow pairs, metric namespaces/aggregations/grains, signal identifiers and thresholds.

There are **25 explicit signals**, refreshed every minute:

| Signal group | Count | Measurement and rules |
|---|---|---|
| Component logs | 10 | Five components, each with failures and heartbeat age |
| Worker hosting logs | 2 | `role=worker`, `flow=worker-pod`; failures and heartbeat age |
| Event Hubs publish logs | 2 | `role=api`, `flow=eventhub`; failures and heartbeat age |
| AKS CPU | 5 | One reusable Maximum/PT5M definition; Degraded >80%, Unhealthy >95% |
| Key Vault metrics | 3 | Availability <99/<95%; saturation >25/>50%; latency >500/>1000ms |
| Storage metrics | 3 | Availability <100/<95%; E2E/server latency >500/>1000ms |

Metric rules list Degraded then Unhealthy thresholds; Unhealthy is evaluated first. The configured Storage availability threshold intentionally exposes even a small availability regression. Do not lower it just to make the graph green.

[`failures.kql`](../../infra/queries/failures.kql) takes the maximum failure indicator over two minutes; any value above zero is directly Unhealthy. An empty failure window returns zero, but is paired with an independent freshness signal.

[`heartbeat.kql`](../../infra/queries/heartbeat.kql) measures seconds since the latest matching report within 15 minutes. Above 180 seconds is Degraded; above 300 is Unhealthy. Missing reports return 3600, not Healthy. Both queries filter exact cluster ID, namespace, role and flow.

The workload reports real SDK publish outcomes for Event Hubs rather than relying on sparse namespace metrics. No publish attempts eventually make its freshness signal Unhealthy. Consumer receive errors and processing failures latch on the worker leaf until a successful event clears them.

Key Vault and Storage additionally enable **two automatic Resource Health signals**. AKS/Event Hubs automatic Resource Health is disabled. A platform Unknown state remains an evidence gap even when other known signals make its entity Healthy.

## Verification and alerts

Read-only preflight makes 14 KQL checks and seven distinct metric checks, covering all explicit signals because CPU is reused five times. Metrics are queried for the preceding 24 hours; their latest bucket must be fresh for the configured grain. Automatic Resource Health must be checked separately in the evaluated model.

Preflight blocks missing evidence by default and rejects verified Degraded/Unhealthy signals outside `order-worker-aks/failures`. Updating an existing environment requires the new workload/log flows first, followed by preflight and model deployment. After deployment, compare saved configuration and fresh evaluated signal values/errors, not just provisioning status.

Both journey entities configure Sev2 Unhealthy alerts. Notification routing is empty unless reviewed action-group IDs are supplied. The suppressed worker fault alone does not trigger a journey alert.

## Permissions

| Identity | Role | Scope |
|---|---|---|
| App | Event Hubs Data Sender + Data Receiver | Event Hubs namespace |
| App | Key Vault Secrets User | Vault |
| App | Storage Blob Data Contributor | Storage account |
| AKS kubelet | AcrPull | Registry |
| AKS control plane | Network Contributor | Demo VNet |
| Operator | AKS RBAC Cluster Admin | Demo cluster |
| Health model | Reader + Monitoring Reader | Demo resource group |

These are nine assignments. App and health-model identities are separate; an operator's successful source query does not prove that the model identity has access. Newly assigned roles may take time to propagate.

## Boundaries and references

Kubernetes probes measure process availability, not coffee preparation. Genuine dependency failures or a stopped worker can still affect other entities. The worker trusts demo-generated events, uses one consumer and has no durable checkpoint or poison-event handling; replay-safe Blob writes are not a production queue design.

Reference: [entities schema](https://learn.microsoft.com/azure/templates/microsoft.cloudhealth/2026-11-01/healthmodels/entities), [relationships schema](https://learn.microsoft.com/azure/templates/microsoft.cloudhealth/2026-11-01/healthmodels/relationships), [rollup and impact](https://learn.microsoft.com/azure/azure-monitor/health-models/rollup), and the [reference demos](../../README.md#references).
