#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$scenario = @{ missingTelemetry = $false; convertedLogin = $false; workerBroken = $true; storageLatency = 10; storageAvailability = 100 }
function Assert($condition, $message) {
    if (-not $condition) { throw $message }
}
# Offline command doubles: this file never invokes the Azure CLI or kubectl executables.
function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'deployment') {
        return @{
            aksName = 'demo-aks'; aksId = '/subscriptions/test/resourceGroups/demo/providers/Microsoft.ContainerService/managedClusters/demo-aks'
            registryName = 'demoacr'; registryServer = 'demoacr.azurecr.io'; clientId = 'demo-client'
            eventNamespace = 'demo.servicebus.windows.net'; eventHub = 'orders'
            vaultUrl = 'https://demo.vault.azure.net/'; blobUrl = 'https://demo.blob.core.windows.net/'
            workspaceId = '/workspaces/demo'; workspaceCustomerId = 'test'
            vaultId = '/vaults/demo'; eventNamespaceId = '/events/demo'; storageId = '/storage/demo'
        } | ConvertTo-Json
    }
    if ($args[0] -eq 'rest') {
        $body = Get-Content (($args[($args.IndexOf('--body') + 1)]).TrimStart('@')) -Raw | ConvertFrom-Json
        $value = if ($body.query -match 'lastSeen') {
            if ($scenario.missingTelemetry) { 3600 } else { 15 }
        } elseif ($body.query.Contains("'worker-pod'") -and $scenario.workerBroken) { 1 } else { 0 }
        return '{"tables":[{"rows":[[' + $value + ']]}]}'
    }
    if ($args[0] -eq 'monitor') {
        if ($args -contains 'list-definitions') {
            return @('node_cpu_usage_percentage', 'Availability', 'SaturationShoebox', 'ServiceApiLatency', 'SuccessE2ELatency', 'SuccessServerLatency') | ForEach-Object {
                @{ name = @{ value = $_ }; supportedAggregationTypes = @('Average', 'Maximum', 'Total') }
            } | ConvertTo-Json -Depth 10
        }
        $metric = $args[($args.IndexOf('--metric') + 1)]
        $interval = switch ($metric) {
            'SaturationShoebox' { 'PT30M' }
            'ServiceApiLatency' { 'PT15M' }
            default { 'PT5M' }
        }
        Assert ($args[($args.IndexOf('--interval') + 1)] -eq $interval) 'Source checks must use the configured signal time grain.'
        $resource = $args[($args.IndexOf('--resource') + 1)]
        $value = if ($metric -eq 'Availability') {
            if ($resource -eq '/storage/demo') { $scenario.storageAvailability } else { 100 }
        } elseif ($metric -like 'Success*Latency') { $scenario.storageLatency } else { 10 }
        $timestamp = [datetime]::UtcNow
        $point = @{ timeStamp = $timestamp.ToString('o'); average = $value; maximum = $value; total = $value }
        return @{ value = @(@{ timeseries = @(@{ data = @($point) }) }) } | ConvertTo-Json -Depth 10
    }
}
function kubectl { $global:LASTEXITCODE = 0 }
function kubelogin {
    $global:LASTEXITCODE = 0
    Assert ($args -contains 'azurecli') 'Cluster login must use the existing Azure CLI Entra session.'
    $scenario.convertedLogin = $true
}

$originals = @{}
foreach ($name in @('workload.json', 'signal-verification.json')) {
    $path = Join-Path $root ".build\$name"
    $originals[$path] = if (Test-Path $path) { [System.IO.File]::ReadAllBytes($path) } else { $null }
}
try {
& (Join-Path $root 'scripts\Deploy.ps1') -Phase Workload -SubscriptionId test -ResourceGroup demo -Confirm:$false
Assert $scenario.convertedLogin 'Entra kubeconfig conversion must precede workload deployment.'
$manifest = Get-Content (Join-Path $root '.build\workload.json') -Raw | ConvertFrom-Json
$deployments = @($manifest.items | Where-Object kind -eq 'Deployment')
Assert ($deployments.Count -eq 4) 'Expected frontend, api, worker and load deployments.'
foreach ($deployment in $deployments) {
    $role = $deployment.metadata.name
    $pod = $deployment.spec.template
    Assert ($pod.spec.automountServiceAccountToken -eq $false) 'Kubernetes API tokens must not be automatically mounted.'
    $wi = $pod.metadata.labels.'azure.workload.identity/use'
    Assert (($wi -eq 'true') -eq ($role -in @('api', 'worker'))) 'Only backend pods should receive workload identity.'
}
$worker = ($deployments | Where-Object { $_.metadata.name -eq 'worker' }).spec.template.spec.containers[0]
Assert (($worker.env | Where-Object name -eq 'FAIL_PROCESSING').value -eq 'true') 'Worker must start broken.'
Assert (@($manifest.items | Where-Object { $_.kind -eq 'Service' -and $_.spec.type -ne 'ClusterIP' }).Count -eq 0) 'No public application endpoints.'

& (Join-Path $root 'scripts\Test-Signals.ps1') -SubscriptionId test -ResourceGroup demo
$rows = Get-Content (Join-Path $root '.build\signal-verification.json') -Raw | ConvertFrom-Json
Assert ($rows.Count -eq 21) 'Expected fourteen log checks and seven distinct metric checks covering twenty-five explicit signals.'
Assert (@($rows | Where-Object Result -ne 'verified').Count -eq 0) 'Healthy fake telemetry should verify.'
Assert (@($rows | Where-Object WouldBe -ne 'Healthy').Count -eq 1) 'Exactly one signal should be unhealthy for the starting fault.'
Assert (($rows | Where-Object Signal -eq 'order-worker-aks/failures').WouldBe -eq 'Unhealthy') 'The worker fault must be scoped to its AKS leaf.'
$scenario.workerBroken = $false
& (Join-Path $root 'scripts\Test-Signals.ps1') -SubscriptionId test -ResourceGroup demo
$rows = Get-Content (Join-Path $root '.build\signal-verification.json') -Raw | ConvertFrom-Json
Assert (@($rows | Where-Object WouldBe -ne 'Healthy').Count -eq 0) 'Recovery must leave every signal healthy.'
$scenario.storageLatency = 1500
$blocked = $false
try {
    & (Join-Path $root 'scripts\Test-Signals.ps1') -SubscriptionId test -ResourceGroup demo
} catch { $blocked = $_.Exception.Message -like 'Unexpected demo health*' }
Assert $blocked 'Real unhealthy dependencies must not be hidden to force the isolated demo state.'
$scenario.storageLatency = 10
foreach ($availability in @(99.5, 94)) {
    $scenario.storageAvailability = $availability
    $blocked = $false
    try {
        & (Join-Path $root 'scripts\Test-Signals.ps1') -SubscriptionId test -ResourceGroup demo
    } catch { $blocked = $_.Exception.Message -like 'Unexpected demo health*' }
    Assert $blocked 'Storage availability regressions must remain visible, not be masked for demo colors.'
    $rows = Get-Content (Join-Path $root '.build\signal-verification.json') -Raw | ConvertFrom-Json
    $expected = if ($availability -lt 95) { 'Unhealthy' } else { 'Degraded' }
    Assert (($rows | Where-Object Signal -eq 'order-storage/Availability').WouldBe -eq $expected) 'LessThan rules must check the unhealthy threshold first.'
}
$scenario.storageAvailability = 100
$scenario.missingTelemetry = $true
$blocked = $false
try {
    & (Join-Path $root 'scripts\Test-Signals.ps1') -SubscriptionId test -ResourceGroup demo
} catch { $blocked = $_.Exception.Message -like 'Signals are unverified*' }
Assert $blocked 'Absent heartbeats must block model deployment.'
Write-Host 'Offline deployment and signal-gate checks passed.'
} finally {
    foreach ($path in $originals.Keys) {
        if ($null -eq $originals[$path]) {
            Remove-Item $path -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::WriteAllBytes($path, $originals[$path])
        }
    }
}
