#!/usr/bin/env pwsh
# Fix: Add subscription context to all DeploymentScript resources in ARM templates
# Bug: UAMI in DeploymentScript ACI container doesn't auto-set SubscriptionId,
#      causing Invoke-AzVMRunCommand to fail with 'SubscriptionId cannot be null'

param(
    [string]$TemplatePath
)

$c = [IO.File]::ReadAllText($TemplatePath)

$old = "`$ErrorActionPreference='Stop'"
$fix = "`$ErrorActionPreference='Stop'\n# Ensure subscription context for UAMI in DeploymentScript container\n`$_ctx = Get-AzContext; if (-not `$_ctx.Subscription.Id) { `$_sub = (Get-AzSubscription -ErrorAction Stop | Select-Object -First 1).Id; Set-AzContext -SubscriptionId `$_sub -ErrorAction Stop | Out-Null; Write-Output (\`"[INFO] Set subscription context to `$_sub\`") }"

# Check if already fixed
if ($c.Contains('Ensure subscription context')) {
    Write-Host "Already fixed: $TemplatePath"
    return
}

$countBefore = ([regex]::Matches($c, [regex]::Escape($old))).Count
Write-Host "Found $countBefore occurrences in $TemplatePath"

$c = $c.Replace($old, $fix)

$countAfter = ([regex]::Matches($c, [regex]::Escape('Ensure subscription context'))).Count
Write-Host "Fix inserted $countAfter times"

[IO.File]::WriteAllText($TemplatePath, $c)
Write-Host "Saved: $TemplatePath"
