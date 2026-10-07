<#
.SYNOPSIS
    Migrate multiple Azure VMs from ADE (Azure Disk Encryption) to Encryption at Host
    in parallel, using ARM deployment templates.

.DESCRIPTION
    This script launches one independent ARM template deployment per VM using PowerShell
    background jobs (-AsJob). Each VM runs its full migration chain independently —
    no VM waits for another to complete any step.

    The ARM template handles the entire migration for each VM:
      1. Disable ADE (BitLocker) and wait until all volumes show 0% encrypted
      2. Remove the ADE extension
      3. Capture VM metadata (NICs, extensions, boot diagnostics, zones, tags, identity)
      4. Stop and deallocate the VM
      5. Copy all disks via SAS — this clears the UDE (Unified Disk Encryption) flag
         (snapshots do NOT clear UDE — only SAS-based copy works)
      6. Optionally apply SSE+CMK to copied disks
      7. Delete the source VM (preserves disks and NICs) and recreate with copied disks
      8. Enable Encryption at Host on the recreated VM

    WHY PARALLEL? Each VM deployment runs as Azure Container Instances (server-side).
    If you disconnect from Cloud Shell or close your laptop, deployments continue running
    in Azure. VMs with smaller disks finish faster without waiting for larger ones.

    IMPORTANT:
    - Each deployment creates helper resources (Managed Identity, Storage Account, Role
      Assignment) that must be cleaned up after migration.
    - Original disks are preserved as backup. Delete them ONLY after validating the
      migrated VM is healthy (recommended: 48-72 hours soak period).
    - Windows VMs ONLY. Linux VMs with ADE on the OS disk cannot be migrated with this
      template — the OS disk must be rebuilt from scratch (data disks can be migrated).

.PARAMETER VmNames
    Array of VM names to migrate. All VMs must be in the same resource group.
    Example: @("web-prod-01", "web-prod-02", "web-prod-03")

.PARAMETER ResourceGroupName
    The resource group containing the VMs.

.PARAMETER TemplateFile
    Path to the ARM template JSON file. Can be a local path, Cloud Shell path, or URI.
    If not specified, defaults to 'DisableADEandEnableAEH_SingleVM.json' in the same
    directory as this script (or the +SSECMK variant when -EnableSSECMK is set).

.PARAMETER EnableSSECMK
    Enable Server-Side Encryption with Customer-Managed Keys on the copied disks.
    Requires -DiskEncryptionSetId.

.PARAMETER DiskEncryptionSetId
    Full ARM resource ID of the Disk Encryption Set. Required when -EnableSSECMK is set.
    Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/diskEncryptionSets/<name>

.PARAMETER DiskEncryptionType
    Disk encryption type for SSE+CMK. Default: EncryptionAtRestWithCustomerKey.
    Use 'EncryptionAtRestWithPlatformAndCustomerKeys' for double encryption.

.PARAMETER ThrottleLimit
    Maximum number of concurrent ARM deployments. Default: 5.
    Azure Resource Manager allows up to 800 deployments per resource group.
    Higher values may trigger ARM throttling (HTTP 429). For large fleets (50+ VMs),
    start with 5 and increase if no throttling is observed.

.EXAMPLE
    # Migrate 3 VMs to Encryption at Host (EAH only)
    .\Deploy-ADE-Migration.ps1 `
        -VmNames @("web-01", "web-02", "web-03") `
        -ResourceGroupName "rg-production-westus2" `
        -TemplateFile ".\DisableADEandEnableAEH_SingleVM.json"

.EXAMPLE
    # Migrate 5 VMs to EAH + SSE+CMK, max 3 concurrent
    .\Deploy-ADE-Migration.ps1 `
        -VmNames @("db-01", "db-02", "db-03", "app-01", "app-02") `
        -ResourceGroupName "rg-production-westus2" `
        -TemplateFile ".\DisableADEandEnableAEH+SSECMK_SingleVM.json" `
        -EnableSSECMK `
        -DiskEncryptionSetId "/subscriptions/xxxxxxxx/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/des-prod" `
        -ThrottleLimit 3

.EXAMPLE
    # Cloud Shell — upload files to ~/clouddrive, then run
    .\Deploy-ADE-Migration.ps1 `
        -VmNames @("vm1", "vm2", "vm3") `
        -ResourceGroupName "myRG" `
        -TemplateFile "$HOME/clouddrive/DisableADEandEnableAEH_SingleVM.json"

.EXAMPLE
    # Dry run — see what would happen without deploying
    .\Deploy-ADE-Migration.ps1 `
        -VmNames @("vm1", "vm2") `
        -ResourceGroupName "myRG" `
        -WhatIf

.NOTES
    Requires: Az.Compute, Az.Resources modules (pre-installed in Azure Cloud Shell).
    Author:   Azure IaaS VM Support — github.com/Azure
    Version:  1.0.0

.LINK
    https://learn.microsoft.com/azure/virtual-machines/disk-encryption-overview

.LINK
    https://learn.microsoft.com/azure/virtual-machines/disk-encryption
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, HelpMessage = "Array of VM names to migrate.")]
    [ValidateNotNullOrEmpty()]
    [string[]]$VmNames,

    [Parameter(Mandatory, HelpMessage = "Resource group containing the VMs.")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(HelpMessage = "Path to the ARM template JSON file.")]
    [string]$TemplateFile,

    [Parameter(HelpMessage = "Enable SSE+CMK on copied disks.")]
    [switch]$EnableSSECMK,

    [Parameter(HelpMessage = "ARM resource ID of the Disk Encryption Set.")]
    [string]$DiskEncryptionSetId,

    [Parameter(HelpMessage = "Disk encryption type for SSE+CMK.")]
    [ValidateSet("EncryptionAtRestWithCustomerKey", "EncryptionAtRestWithPlatformAndCustomerKeys")]
    [string]$DiskEncryptionType = "EncryptionAtRestWithCustomerKey",

    [Parameter(HelpMessage = "Max concurrent deployments (default: 5).")]
    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 5
)

$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
#  RESOLVE TEMPLATE
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $TemplateFile) {
    # Auto-resolve: look for the template in the same directory as this script
    $scriptDir = $PSScriptRoot
    if ($EnableSSECMK) {
        $TemplateFile = Join-Path $scriptDir "DisableADEandEnableAEH+SSECMK_SingleVM.json"
    } else {
        $TemplateFile = Join-Path $scriptDir "DisableADEandEnableAEH_SingleVM.json"
    }
}

if (-not (Test-Path $TemplateFile)) {
    throw "Template not found at: $TemplateFile`nDownload the ARM templates from this repo and place them in the same directory as this script, or specify -TemplateFile explicitly."
}
$TemplateFile = (Resolve-Path $TemplateFile).Path

# ═══════════════════════════════════════════════════════════════════════════════
#  VALIDATE PARAMETERS
# ═══════════════════════════════════════════════════════════════════════════════

if ($EnableSSECMK) {
    if ([string]::IsNullOrWhiteSpace($DiskEncryptionSetId)) {
        throw "-EnableSSECMK requires -DiskEncryptionSetId. Provide the full ARM resource ID of your Disk Encryption Set."
    }
    if ($DiskEncryptionSetId -notmatch '^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\.Compute/diskEncryptionSets/.+$') {
        throw "Invalid -DiskEncryptionSetId format.`nExpected: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/diskEncryptionSets/<name>"
    }
}

# Deduplicate VM names
$VmNames = $VmNames | Select-Object -Unique
if ($VmNames.Count -eq 0) { throw "No VM names provided." }

# ═══════════════════════════════════════════════════════════════════════════════
#  DISPLAY PLAN
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  ADE → Encryption at Host — Parallel Migration                 ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Template:       $(Split-Path $TemplateFile -Leaf)" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  VMs to migrate: $($VmNames.Count)" -ForegroundColor White
foreach ($vm in $VmNames) {
    Write-Host "                  • $vm" -ForegroundColor Gray
}
Write-Host "  SSE+CMK:        $($EnableSSECMK.IsPresent)" -ForegroundColor White
if ($EnableSSECMK) {
    Write-Host "  DES:            .../$($DiskEncryptionSetId.Split('/')[-1])" -ForegroundColor White
    Write-Host "  Encryption:     $DiskEncryptionType" -ForegroundColor White
}
Write-Host "  Max concurrent: $ThrottleLimit" -ForegroundColor White
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
#  WHATIF — dry run
# ═══════════════════════════════════════════════════════════════════════════════

if ($WhatIfPreference) {
    Write-Host "[WHATIF] Would create $($VmNames.Count) independent ARM deployments." -ForegroundColor Yellow
    Write-Host "[WHATIF] Each deployment runs the full migration chain for one VM." -ForegroundColor Yellow
    Write-Host "[WHATIF] No changes made." -ForegroundColor Yellow
    return
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "[PRE-FLIGHT] Verifying VMs..." -ForegroundColor Yellow

$preflightFailed = $false
foreach ($vmName in $VmNames) {
    try {
        $vmObj = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
        $osType = $vmObj.StorageProfile.OsDisk.OsType

        if ($osType -ne 'Windows') {
            Write-Host "  ✗ $vmName — OS type is '$osType'. This template supports Windows only." -ForegroundColor Red
            Write-Host "    Linux VMs with ADE on the OS disk must be rebuilt." -ForegroundColor DarkGray
            $preflightFailed = $true
            continue
        }

        # Check if VM size supports Encryption at Host
        $vmSize = $vmObj.HardwareProfile.VmSize
        $skuInfo = Get-AzComputeResourceSku -Location $vmObj.Location |
            Where-Object { $_.Name -eq $vmSize -and $_.ResourceType -eq 'virtualMachines' }
        $eahCapable = $skuInfo.Capabilities |
            Where-Object { $_.Name -eq 'EncryptionAtHostSupported' -and $_.Value -eq 'True' }

        if (-not $eahCapable) {
            Write-Host "  ✗ $vmName — VM size '$vmSize' does not support Encryption at Host." -ForegroundColor Red
            Write-Host "    Resize to a supported SKU before running this script." -ForegroundColor DarkGray
            $preflightFailed = $true
            continue
        }

        Write-Host "  ✓ $vmName ($vmSize, Windows)" -ForegroundColor Green
    }
    catch {
        Write-Host "  ✗ $vmName — $($_.Exception.Message)" -ForegroundColor Red
        $preflightFailed = $true
    }
}

# Check EncryptionAtHost feature registration
Write-Host ""
Write-Host "[PRE-FLIGHT] Checking EncryptionAtHost feature registration..." -ForegroundColor Yellow
try {
    $feature = Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost
    if ($feature.RegistrationState -ne 'Registered') {
        Write-Host "  ✗ EncryptionAtHost feature is '$($feature.RegistrationState)' — must be 'Registered'." -ForegroundColor Red
        Write-Host "    Run: Register-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost" -ForegroundColor DarkGray
        $preflightFailed = $true
    } else {
        Write-Host "  ✓ EncryptionAtHost feature is registered" -ForegroundColor Green
    }
}
catch {
    Write-Host "  ⚠ Could not verify feature registration: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($preflightFailed) {
    Write-Host ""
    Write-Host "[ABORT] Pre-flight checks failed. Fix the issues above and re-run." -ForegroundColor Red
    return
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CONFIRMATION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "⚠  WARNING: This will cause DOWNTIME on all listed VMs." -ForegroundColor Yellow
Write-Host "   Each VM will be stopped, disks copied, VM deleted and recreated." -ForegroundColor Yellow
Write-Host "   Original disks are preserved as backup." -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Type 'YES' to proceed with migration of $($VmNames.Count) VMs"
if ($confirm -ne 'YES') {
    Write-Host "[CANCELLED] No deployments were created." -ForegroundColor Yellow
    return
}
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
#  LAUNCH DEPLOYMENTS
# ═══════════════════════════════════════════════════════════════════════════════

$jobs            = @()
$deploymentNames = @{}
$startTime       = Get-Date

foreach ($vm in $VmNames) {
    # Throttle: wait if we've hit the concurrent limit
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
        Write-Host "[THROTTLE] $ThrottleLimit deployments running — waiting for a slot..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }

    $deploymentName = "ade-eah-$vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $deploymentNames[$vm] = $deploymentName

    Write-Host "[LAUNCH] $vm → deployment '$deploymentName'" -ForegroundColor Cyan

    $templateParams = @{
        vmName            = $vm
        resourceGroupName = $ResourceGroupName
    }

    if ($EnableSSECMK) {
        $templateParams['enableSSECMK']        = $true
        $templateParams['diskEncryptionSetId']  = $DiskEncryptionSetId
        $templateParams['diskEncryptionType']   = $DiskEncryptionType
    }

    $job = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $TemplateFile `
        -TemplateParameterObject $templateParams `
        -AsJob

    $job.Name = "ADE-EAH-$vm"
    $jobs += $job

    # Small delay between launches to avoid ARM burst throttling
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "[INFO] All $($VmNames.Count) deployments launched." -ForegroundColor Yellow
Write-Host "[INFO] Deployments run server-side — they continue even if you close this session." -ForegroundColor DarkGray
Write-Host "[INFO] To check status later:" -ForegroundColor DarkGray
Write-Host "  Get-AzResourceGroupDeployment -ResourceGroupName '$ResourceGroupName' | Where-Object DeploymentName -like 'ade-eah-*'" -ForegroundColor DarkGray
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
#  MONITOR PROGRESS
# ═══════════════════════════════════════════════════════════════════════════════

$completed = @{}
while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
    foreach ($job in $jobs) {
        $vm = $job.Name -replace '^ADE-EAH-', ''
        if ($completed.ContainsKey($vm)) { continue }

        if ($job.State -ne 'Running') {
            $completed[$vm] = $job.State
            $duration = if ($job.PSEndTime -and $job.PSBeginTime) {
                ($job.PSEndTime - $job.PSBeginTime).ToString('hh\:mm\:ss')
            } else { 'unknown' }

            if ($job.State -eq 'Completed') {
                Write-Host "  ✓ $vm — completed in $duration" -ForegroundColor Green
            } else {
                Write-Host "  ✗ $vm — $($job.State) after $duration" -ForegroundColor Red
            }
        }
    }
    Start-Sleep -Seconds 15
}

# Catch any that finished in the last loop iteration
foreach ($job in $jobs) {
    $vm = $job.Name -replace '^ADE-EAH-', ''
    if (-not $completed.ContainsKey($vm)) {
        $completed[$vm] = $job.State
        $duration = if ($job.PSEndTime -and $job.PSBeginTime) {
            ($job.PSEndTime - $job.PSBeginTime).ToString('hh\:mm\:ss')
        } else { 'unknown' }
        if ($job.State -eq 'Completed') {
            Write-Host "  ✓ $vm — completed in $duration" -ForegroundColor Green
        } else {
            Write-Host "  ✗ $vm — $($job.State) after $duration" -ForegroundColor Red
        }
    }
}

$totalDuration = ((Get-Date) - $startTime).ToString('hh\:mm\:ss')

# ═══════════════════════════════════════════════════════════════════════════════
#  RESULTS SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  MIGRATION RESULTS  (total time: $totalDuration)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$succeeded = @()
$failed    = @()

foreach ($job in $jobs) {
    $vm = $job.Name -replace '^ADE-EAH-', ''
    if ($job.State -eq 'Completed') {
        $null = Receive-Job $job -ErrorAction SilentlyContinue
        $succeeded += $vm
    } else {
        $errMsg = ($job.Error | Select-Object -First 1)
        Write-Host "  ✗ $vm — Error: $errMsg" -ForegroundColor Red
        $failed += $vm
    }
}

Write-Host ""
if ($succeeded.Count -gt 0) {
    Write-Host "  Succeeded: $($succeeded.Count)/$($VmNames.Count)" -ForegroundColor Green
    foreach ($vm in $succeeded) { Write-Host "    ✓ $vm" -ForegroundColor Green }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "  Failed: $($failed.Count)/$($VmNames.Count)" -ForegroundColor Red
    foreach ($vm in $failed) { Write-Host "    ✗ $vm" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  To debug failed deployments:" -ForegroundColor Yellow
    foreach ($vm in $failed) {
        Write-Host "    Get-AzResourceGroupDeploymentOperation -ResourceGroupName '$ResourceGroupName' -Name '$($deploymentNames[$vm])'" -ForegroundColor DarkGray
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  POST-MIGRATION CHECKLIST
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  POST-MIGRATION CHECKLIST" -ForegroundColor White
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  1. Verify each migrated VM:" -ForegroundColor White
Write-Host "     • VM is running and accessible (RDP)" -ForegroundColor Gray
Write-Host "     • Applications are working correctly" -ForegroundColor Gray
Write-Host '     • EAH is enabled:' -ForegroundColor Gray
Write-Host '       (Get-AzVM -ResourceGroupName "<rg>" -Name "<vm>").SecurityProfile.EncryptionAtHost' -ForegroundColor DarkGray
Write-Host '     • ADE is fully removed:' -ForegroundColor Gray
Write-Host '       Get-AzVMDiskEncryptionStatus -ResourceGroupName "<rg>" -VMName "<vm>"' -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. Wait 48-72 hours (soak period) before deleting anything." -ForegroundColor White
Write-Host ""
Write-Host "  3. After the soak period, clean up helper resources:" -ForegroundColor White
Write-Host "     • User-Assigned Managed Identity  (name starts with 'ui-')" -ForegroundColor Gray
Write-Host "     • Storage Account                 (name starts with 'dss')" -ForegroundColor Gray
Write-Host "     • Role Assignment                 (Contributor on the RG)" -ForegroundColor Gray
Write-Host "     • Original disks                  (only AFTER full validation)" -ForegroundColor Gray
Write-Host ""

# Clean up PowerShell jobs
$jobs | Remove-Job -Force -ErrorAction SilentlyContinue
