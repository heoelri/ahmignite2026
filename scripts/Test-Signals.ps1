#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [switch]$AllowUnverified
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$catalog = Get-Content (Join-Path $root 'infra\signals.json') -Raw | ConvertFrom-Json
function Invoke-AzureCli {
    $result = & az @args
    if ($LASTEXITCODE -ne 0) { throw "Azure read failed: $($args[0..1] -join ' ')" }
    return $result
}
function Get-HealthState($value, $signal) {
    if ($signal.operator -notin @('LessThan', 'GreaterThan')) { throw 'Unsupported signal operator.' }
    $low = $signal.operator -eq 'LessThan'
    if (($low -and $value -lt $signal.unhealthy) -or (-not $low -and $value -gt $signal.unhealthy)) {
        return 'Unhealthy'
    }
    if (($low -and $value -lt $signal.degraded) -or (-not $low -and $value -gt $signal.degraded)) {
        return 'Degraded'
    }
    return 'Healthy'
}
$config = Invoke-AzureCli deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name infrastructure --query properties.outputs.config.value -o json | ConvertFrom-Json
$rows = @()
$build = Join-Path $root '.build'
New-Item $build -ItemType Directory -Force | Out-Null
$bodyFile = Join-Path $build 'query.json'
try {
    foreach ($component in (@($catalog.components) + @($catalog.additionalLogSources))) {
        foreach ($signal in $catalog.logSignals) {
            $kind = $signal.kind
            try {
                $query = (Get-Content (Join-Path $root "infra\queries\$kind.kql") -Raw).
                    Replace('__CLUSTER_ID__', $config.aksId).Replace('__ROLE__', $component.role).Replace('__FLOW__', $component.flow)
                @{ query = $query; timespan = 'P1D' } | ConvertTo-Json | Set-Content $bodyFile
                $response = Invoke-AzureCli rest --method post --url "https://api.loganalytics.azure.com/v1/workspaces/$($config.workspaceCustomerId)/query" `
                    --resource https://api.loganalytics.io --body "@$bodyFile" -o json | ConvertFrom-Json
                if ($response.error) { throw 'Log Analytics returned a query error.' }
                $data = $response.tables[0].rows
                if ($data.Count -ne 1 -or $null -eq $data[0][0]) { throw 'Expected one numeric row.' }
                $value = [double]$data[0][0]
                $state = Get-HealthState $value $signal
                $result = if ($kind -eq 'heartbeat' -and $value -ge 3600) { 'NO TELEMETRY' } else { 'verified' }
                $rows += [pscustomobject]@{ Signal = "$($component.name)/$kind"; Source = 'ContainerLogV2'; Observed = $value; WouldBe = $state; Result = $result }
            } catch {
                $rows += [pscustomobject]@{ Signal = "$($component.name)/$kind"; Source = 'ContainerLogV2'; Observed = '-'; WouldBe = 'Unknown'; Result = $_.Exception.Message }
            }
        }
    }
    $metricSources = @(@{ name = 'aks'; resourceIdKey = $catalog.cpu.resourceIdKey; signals = @($catalog.cpu) }) + @($catalog.dependencies)
    foreach ($source in $metricSources) {
        foreach ($metric in $source.signals) {
            $name = "$($source.name)/$($metric.metric)"
            $id = $config.($source.resourceIdKey)
            try {
                $definitions = Invoke-AzureCli monitor metrics list-definitions --subscription $SubscriptionId --resource $id `
                    --namespace $metric.namespace -o json | ConvertFrom-Json
                $definition = $definitions | Where-Object { $_.name.value -eq $metric.metric }
                if (-not $definition -or $metric.aggregation -notin $definition.supportedAggregationTypes) { throw 'Metric or aggregation is not supported.' }
                $now = [datetime]::UtcNow
                $response = Invoke-AzureCli monitor metrics list --subscription $SubscriptionId --resource $id --namespace $metric.namespace `
                    --metric $metric.metric --aggregation $metric.aggregation --interval $metric.timeGrain `
                    --start-time $now.AddDays(-1).ToString('o') --end-time $now.ToString('o') -o json | ConvertFrom-Json
                $points = @($response.value[0].timeseries | ForEach-Object { $_.data } | Where-Object { $null -ne $_.($metric.aggregation) })
                if ($points.Count -eq 0) { throw 'No metric datapoints in the last 24h.' }
                $latestTime = ($points | Sort-Object timeStamp | Select-Object -Last 1).timeStamp
                $maxAgeMinutes = [math]::Max(15, [System.Xml.XmlConvert]::ToTimeSpan($metric.timeGrain).TotalMinutes + 5)
                if ([datetime]$latestTime -lt $now.AddMinutes(-$maxAgeMinutes)) { throw "Metric datapoints are stale (>$maxAgeMinutes min)." }
                $values = @($points | ForEach-Object { [double]$_.($metric.aggregation) })
                $latest = @($points | Where-Object timeStamp -eq $latestTime | ForEach-Object { [double]$_.($metric.aggregation) })
                $value = ($latest | Measure-Object -Maximum).Maximum
                $state = Get-HealthState $value $metric
                $range = $values | Measure-Object -Minimum -Maximum
                $rows += [pscustomobject]@{ Signal = $name; Source = $metric.metric; Observed = "$($range.Minimum)..$($range.Maximum) (latest $value)"; WouldBe = $state; Result = 'verified' }
            } catch {
                $rows += [pscustomobject]@{ Signal = $name; Source = $metric.metric; Observed = '-'; WouldBe = 'Unknown'; Result = $_.Exception.Message }
            }
        }
    }
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}
$rows | Format-Table -AutoSize | Out-Host
$rows | ConvertTo-Json | Set-Content (Join-Path $build 'signal-verification.json')
if (@($rows | Where-Object Result -ne 'verified').Count -gt 0 -and -not $AllowUnverified) {
    throw 'Signals are unverified. Wait for ingestion and retry; use -AllowUnverifiedSignals on Deploy.ps1 only after reviewing the gaps.'
}
$unexpected = @($rows | Where-Object { $_.Result -eq 'verified' -and $_.WouldBe -ne 'Healthy' -and $_.Signal -ne 'order-worker-aks/failures' })
if ($unexpected.Count -gt 0) {
    throw "Unexpected demo health: $($unexpected.Signal -join ', '). Only the worker AKS processing-failure signal should be unhealthy."
}
