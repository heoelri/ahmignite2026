#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Infrastructure', 'Workload', 'Model')][string]$Phase,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'swedencentral',
    [string]$ModelLocation = 'uksouth',
    [ValidatePattern('^[a-z][a-z0-9]{2,15}$')][string]$Name = 'ignitecoffee',
    [string]$OperatorPrincipalId,
    [string[]]$ActionGroupIds = @(),
    [switch]$AllowUnverifiedSignals
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$build = Join-Path $root '.build'
$catalog = Get-Content (Join-Path $root 'infra\signals.json') -Raw | ConvertFrom-Json
$entityCount = 3 + 2 * $catalog.components.Count + $catalog.dependencies.Count
$metricCount = ($catalog.dependencies | ForEach-Object { $_.signals.Count } | Measure-Object -Sum).Sum
$signalCount = ($catalog.components.Count + $catalog.additionalLogSources.Count) * $catalog.logSignals.Count + $catalog.components.Count + $metricCount

function Invoke-AzureCli {
    $result = & az @args
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($args[0..1] -join ' ')" }
    return $result
}
function Kube {
    & kubectl --kubeconfig (Join-Path $build 'kubeconfig') @args
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($args[0])" }
}

$changes = switch ($Phase) {
    'Infrastructure' { 'Configure RG, Entra-only two-node AKS with managed Prometheus, ACR, Event Hubs Basic, private purge-protected Key Vault, Storage, Log Analytics and Azure Monitor workspaces, two identities, VNet/NSG/private endpoint/DNS, log/metrics collection rules, diagnostics and seven scoped role assignments' }
    'Workload' { 'Build/push image; create namespace, configuration, service account, four deployments and two internal services; start traffic and intentional worker failure' }
    'Model' { "Configure health model, $entityCount entities including automatic root, $($entityCount - 1) relationships, $signalCount explicit signals plus two automatic Resource Health signals and Reader + Monitoring Reader assignments on the demo RG; isolate the worker AKS fault with Suppressed impact; enable two flow alerts" }
}
Write-Host "$changes`nTarget: $SubscriptionId / $ResourceGroup. Workload region: $Location. Model region: $ModelLocation."
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroup", $changes)) { return }
New-Item $build -ItemType Directory -Force | Out-Null

if ($Phase -eq 'Infrastructure') {
    if (-not $OperatorPrincipalId) {
        $OperatorPrincipalId = Invoke-AzureCli ad signed-in-user show --query id -o tsv
    }
    if (-not $OperatorPrincipalId) { throw 'Supply the Entra user object ID via -OperatorPrincipalId.' }
    Invoke-AzureCli group create --subscription $SubscriptionId --name $ResourceGroup --location $Location --tags purpose=ignite-health-model-demo --only-show-errors -o none
    Invoke-AzureCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup --name infrastructure `
        --template-file (Join-Path $root 'infra\main.bicep') --parameters "name=$Name" "location=$Location" "operatorPrincipalId=$OperatorPrincipalId" --only-show-errors -o none
    return
}

$config = Invoke-AzureCli deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name infrastructure --query properties.outputs.config.value -o json | ConvertFrom-Json

if ($Phase -eq 'Workload') {
    if (-not (Get-Command kubelogin -ErrorAction SilentlyContinue)) {
        throw 'kubelogin is required for Entra-authenticated cluster access.'
    }
    $tag = "demo:$(Get-Date -Format 'yyyyMMddHHmmss')"
    Invoke-AzureCli acr build --subscription $SubscriptionId --resource-group $ResourceGroup --registry $config.registryName `
        --image $tag (Join-Path $root 'workload') --only-show-errors --no-logs -o none
    Invoke-AzureCli aks get-credentials --subscription $SubscriptionId --resource-group $ResourceGroup --name $config.aksName `
        --file (Join-Path $build 'kubeconfig') --overwrite-existing --only-show-errors
    & kubelogin convert-kubeconfig --kubeconfig (Join-Path $build 'kubeconfig') -l azurecli
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure Entra authentication.' }
    $namespace = 'ignite-demo'
    $items = @(
        @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = $namespace } },
        @{
            apiVersion = 'v1'; kind = 'ServiceAccount'
            metadata = @{ name = 'app'; namespace = $namespace; annotations = @{ 'azure.workload.identity/client-id' = $config.clientId } }
        },
        @{
            apiVersion = 'v1'; kind = 'ConfigMap'
            metadata = @{ name = 'app'; namespace = $namespace }
            data = @{
                API_URL = 'http://api:8080'; FRONTEND_URL = 'http://frontend:8080'
                EVENT_NAMESPACE = $config.eventNamespace; EVENT_HUB = $config.eventHub
                VAULT_URL = $config.vaultUrl; BLOB_URL = $config.blobUrl
            }
        }
    )
    foreach ($role in @('api', 'worker', 'frontend', 'load')) {
        $usesIdentity = $role -in @('api', 'worker')
        $labels = @{ app = $role }
        if ($usesIdentity) { $labels['azure.workload.identity/use'] = 'true' }
        $container = @{
            name = $role; image = "$($config.registryServer)/$tag"
            envFrom = @(@{ configMapRef = @{ name = 'app' } })
            env = @(@{ name = 'ROLE'; value = $role })
            resources = @{ requests = @{ cpu = '50m'; memory = '80Mi' }; limits = @{ cpu = '500m'; memory = '256Mi' } }
            securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
        }
        if ($role -eq 'worker') { $container.env += @{ name = 'FAIL_PROCESSING'; value = 'true' } }
        if ($role -ne 'load') {
            $container.ports = @(@{ containerPort = 8080 })
            $container.livenessProbe = @{ httpGet = @{ path = '/healthz'; port = 8080 }; initialDelaySeconds = 15; periodSeconds = 15 }
            $container.readinessProbe = @{ httpGet = @{ path = '/healthz'; port = 8080 }; periodSeconds = 5 }
        }
        $pod = @{
            automountServiceAccountToken = $false
            securityContext = @{ runAsNonRoot = $true; runAsUser = 10001; seccompProfile = @{ type = 'RuntimeDefault' } }
            containers = @($container)
        }
        if ($usesIdentity) { $pod.serviceAccountName = 'app' }
        $items += @{
            apiVersion = 'apps/v1'; kind = 'Deployment'
            metadata = @{ name = $role; namespace = $namespace }
            spec = @{
                replicas = 1
                strategy = @{ type = 'Recreate' }
                selector = @{ matchLabels = @{ app = $role } }
                template = @{ metadata = @{ labels = $labels }; spec = $pod }
            }
        }
    }
    foreach ($service in @('frontend', 'api')) {
        $items += @{
            apiVersion = 'v1'; kind = 'Service'
            metadata = @{ name = $service; namespace = $namespace }
            spec = @{ type = 'ClusterIP'; selector = @{ app = $service }; ports = @(@{ port = 8080; targetPort = 8080 }) }
        }
    }
    $manifest = Join-Path $build 'workload.json'
    @{ apiVersion = 'v1'; kind = 'List'; items = $items } | ConvertTo-Json -Depth 30 | Set-Content $manifest
    Kube apply -f $manifest
    foreach ($role in @('api', 'worker', 'frontend', 'load')) {
        Kube rollout status "deployment/$role" -n $namespace --timeout=300s
    }
    Write-Host "Workload ready. Worker intentionally cannot prepare coffee. Re-running this phase resets the fault."
    Write-Host "Open via: kubectl --kubeconfig .build\kubeconfig -n ignite-demo port-forward service/frontend 8080:8080"
    return
}

& (Join-Path $PSScriptRoot 'Test-Signals.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -AllowUnverified:$AllowUnverifiedSignals
$modelName = "$Name-health"
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        healthModelName = @{ value = $modelName }
        location = @{ value = $ModelLocation }
        config = @{ value = $config }
        actionGroupIds = @{ value = @($ActionGroupIds) }
    }
}
$parameterFile = Join-Path $build 'healthmodel.parameters.json'
$parameters | ConvertTo-Json -Depth 20 | Set-Content $parameterFile
Invoke-AzureCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup --name healthmodel `
    --template-file (Join-Path $root 'infra\healthmodel.bicep') --parameters "@$parameterFile" --only-show-errors -o none
Write-Host "Configuration saved: $modelName. Verify evaluated signal states, not just provisioning success."
