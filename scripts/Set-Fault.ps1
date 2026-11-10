#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Broken', 'Healthy')][string]$State
)
$ErrorActionPreference = 'Stop'
$kubeconfig = Join-Path (Split-Path $PSScriptRoot) '.build\kubeconfig'
if (-not (Test-Path $kubeconfig)) { throw 'Deploy the workload first.' }
if (-not $PSCmdlet.ShouldProcess('ignite-demo/worker', "Set coffee preparation to $State")) { return }
$fail = if ($State -eq 'Broken') { 'true' } else { 'false' }
& kubectl --kubeconfig $kubeconfig -n ignite-demo set env deployment/worker "FAIL_PROCESSING=$fail"
if ($LASTEXITCODE -ne 0) { throw 'Could not change worker fault.' }
& kubectl --kubeconfig $kubeconfig -n ignite-demo rollout status deployment/worker --timeout=180s
if ($LASTEXITCODE -ne 0) { throw 'Worker rollout failed.' }
Write-Host "Worker $State. Only its AKS leaf should change color; its impact is suppressed. Allow roughly 3-8 minutes for log ingestion, the two-minute error window and model evaluation."
