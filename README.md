# ADE to Encryption at Host — Migration Toolkit

Migrate Azure VMs from **Azure Disk Encryption (ADE/BitLocker)** to **Encryption at Host (EAH)** using ARM deployment templates — including a parallel wrapper script to migrate multiple VMs simultaneously.

> **Important:** Azure Disk Encryption (ADE) for Windows VMs using BEK-only and BEK+KEK scenarios is [retiring on September 15, 2028](https://learn.microsoft.com/azure/virtual-machines/disk-encryption-overview). Customers should plan their migration well ahead of this date.

## How It Works

### Architecture Overview

```
Your Machine / Cloud Shell                        Azure (server-side)
┌──────────────────────────┐                     ┌────────────────────────────────┐
│                          │                     │                                │
│  Deploy-ADE-Migration.ps1│──── AsJob ──────►   │  ARM Deployment: vm1           │
│                          │                     │  ┌──────────────────────────┐   │
│  (launches N independent │──── AsJob ──────►   │  │ DisableADE → Capture →  │   │
│   ARM deployments)       │                     │  │ Stop → CopyDisks →      │   │
│                          │──── AsJob ──────►   │  │ Recreate → EnableEAH    │   │
│                          │                     │  └──────────────────────────┘   │
│  Monitors progress,      │                     │                                │
│  can disconnect safely   │                     │  ARM Deployment: vm2           │
│                          │                     │  ┌──────────────────────────┐   │
└──────────────────────────┘                     │  │ (same chain, independent)│   │
                                                 │  └──────────────────────────┘   │
                                                 │                                │
                                                 │  ARM Deployment: vm3           │
                                                 │  ┌──────────────────────────┐   │
                                                 │  │ (same chain, independent)│   │
                                                 │  └──────────────────────────┘   │
                                                 └────────────────────────────────┘
```

**Each VM gets its own independent ARM deployment** with its own deployment scripts (Azure Container Instances). VMs with smaller disks finish faster — they never wait for larger ones.

### What Happens Per VM

The ARM template executes these steps **sequentially for each VM**, but **in parallel across VMs**:

| Step | Action | What It Does |
|------|--------|-------------|
| 1 | Validate SSE+CMK inputs | *(Only if using SSE+CMK)* Validates Disk Encryption Set exists |
| 2 | Disable ADE | Disables BitLocker, polls until all volumes report 0% encrypted, removes ADE VM extension |
| 3 | Capture VM metadata | Saves NICs, extensions, boot diagnostics settings, availability zone, tags, and identity config |
| 4 | Stop VM | Deallocates the VM to allow disk operations |
| 5 | Copy all disks | Creates new disks via **SAS-based copy** — this clears the UDE (Unified Disk Encryption) flag. Snapshots do NOT clear UDE. AzCopy throughput is ~86 GB/min |
| 6 | Apply SSE+CMK | *(Only if using SSE+CMK)* Applies Customer-Managed Key encryption to copied disks |
| 7 | Recreate VM | Deletes source VM (preserves original disks + NICs), creates new VM with copied disks |
| 8 | Enable EAH | Enables Encryption at Host on the recreated VM |

### Why SAS Copy Instead of Snapshots?

When ADE is active, Azure sets an internal flag called **UDE (Unified Disk Encryption)** on the disk. Snapshots preserve this flag, which means a disk created from a snapshot still "looks" ADE-encrypted to Azure — even after BitLocker is removed. **Only a SAS-based disk copy clears the UDE flag**, allowing Encryption at Host to be enabled.

### Cloud Shell Compatibility

The migration runs entirely **server-side** as Azure Container Instances. This means:

- You can run the script from **Azure Cloud Shell** — no local PowerShell required
- If Cloud Shell **disconnects** (20-minute idle timeout), all deployments **continue running in Azure**
- When you reconnect, check progress with:
  ```powershell
  Get-AzResourceGroupDeployment -ResourceGroupName "myRG" |
      Where-Object DeploymentName -like 'ade-eah-*' |
      Select-Object DeploymentName, ProvisioningState, Timestamp
  ```

## Prerequisites

1. **Azure PowerShell modules** — `Az.Compute` and `Az.Resources` (pre-installed in Cloud Shell)
2. **EncryptionAtHost feature** must be registered on the subscription:
   ```powershell
   # Check registration
   Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost

   # Register if needed (one-time, takes a few minutes)
   Register-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost
   Register-AzResourceProvider -ProviderNamespace Microsoft.Compute
   ```
3. **VM sizes must support EAH** — Most modern SKUs do. The script checks this automatically.
   - [Full list of supported VM sizes](https://learn.microsoft.com/azure/virtual-machines/linux/disks-enable-host-based-encryption-powershell#supported-vm-sizes)
4. **Windows VMs only** — Linux VMs with ADE on the OS disk cannot use this template (see [Linux Notes](#linux-notes))
5. **Maintenance window** — Each VM will experience downtime during the migration (stop → copy → recreate)

## Quick Start

### Step 1: Download the Files

Download these files to the same directory:

| File | Description |
|------|-------------|
| `Deploy-ADE-Migration-Parallel.ps1` | Parallel wrapper script |
| `DisableADEandEnableAEH_SingleVM.json` | ARM template — EAH only |
| `DisableADEandEnableAEH+SSECMK_SingleVM.json` | ARM template — EAH + SSE+CMK |

### Step 2: Connect to Azure

```powershell
# Local PowerShell — authenticate first
Connect-AzAccount
Set-AzContext -Subscription "your-subscription-id"

# Cloud Shell — already authenticated, just select subscription
Set-AzContext -Subscription "your-subscription-id"
```

### Step 3: Run the Migration

#### Option A: Encryption at Host only

```powershell
.\Deploy-ADE-Migration-Parallel.ps1 `
    -VmNames @("vm-web-01", "vm-web-02", "vm-app-01") `
    -ResourceGroupName "rg-production-westus2" `
    -TemplateFile ".\DisableADEandEnableAEH_SingleVM.json"
```

#### Option B: Encryption at Host + Server-Side Encryption with Customer-Managed Keys

```powershell
.\Deploy-ADE-Migration-Parallel.ps1 `
    -VmNames @("vm-db-01", "vm-db-02", "vm-db-03") `
    -ResourceGroupName "rg-production-westus2" `
    -TemplateFile ".\DisableADEandEnableAEH+SSECMK_SingleVM.json" `
    -EnableSSECMK `
    -DiskEncryptionSetId "/subscriptions/xxxxxxxx-xxxx/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/des-prod"
```

#### Option C: Dry run (no changes)

```powershell
.\Deploy-ADE-Migration-Parallel.ps1 `
    -VmNames @("vm1", "vm2") `
    -ResourceGroupName "myRG" `
    -TemplateFile ".\DisableADEandEnableAEH_SingleVM.json" `
    -WhatIf
```

### Step 4: Monitor Progress

The script shows live progress. If you get disconnected:

```powershell
# Check all ADE migration deployments
Get-AzResourceGroupDeployment -ResourceGroupName "myRG" |
    Where-Object DeploymentName -like 'ade-eah-*' |
    Format-Table DeploymentName, ProvisioningState, Timestamp -AutoSize

# Detailed operations for a specific VM
Get-AzResourceGroupDeploymentOperation -ResourceGroupName "myRG" `
    -Name "ade-eah-vm-web-01-20260604-143022"
```

### Step 5: Post-Migration Verification

For each migrated VM:

```powershell
# Verify Encryption at Host is enabled
(Get-AzVM -ResourceGroupName "myRG" -Name "vm-web-01").SecurityProfile.EncryptionAtHost
# Expected: True

# Verify ADE is fully removed
Get-AzVMDiskEncryptionStatus -ResourceGroupName "myRG" -VMName "vm-web-01"
# Expected: OsVolumeEncrypted = NotEncrypted, DataVolumesEncrypted = NotEncrypted
```

### Step 6: Cleanup (After 48-72 Hour Soak Period)

Each deployment creates helper resources that should be removed after validation:

| Resource | Naming Pattern | How to Identify |
|----------|----------------|-----------------|
| User-Assigned Managed Identity | `ui-*` | Used by deployment scripts to run PowerShell as ACI |
| Storage Account | `dss*` | Stores deployment script logs |
| Role Assignment | Contributor on RG | Grants the UAMI access to manage VMs and disks |
| Original disks | Your original disk names | Preserved as backup — **delete only after full validation** |

```powershell
# Find helper resources
Get-AzUserAssignedIdentity -ResourceGroupName "myRG" | Where-Object Name -like 'ui-*'
Get-AzStorageAccount -ResourceGroupName "myRG" | Where-Object StorageAccountName -like 'dss*'
```

## Parameters Reference

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-VmNames` | Yes | — | Array of VM names. All must be in the same resource group |
| `-ResourceGroupName` | Yes | — | Resource group containing the VMs |
| `-TemplateFile` | No* | Auto-detect | Path to ARM template JSON. Auto-resolves if in same directory |
| `-EnableSSECMK` | No | `$false` | Enable SSE+CMK on copied disks |
| `-DiskEncryptionSetId` | If SSE+CMK | — | Full ARM resource ID of Disk Encryption Set |
| `-DiskEncryptionType` | No | `EncryptionAtRestWithCustomerKey` | CMK encryption type |
| `-ThrottleLimit` | No | `5` | Max concurrent ARM deployments |
| `-WhatIf` | No | — | Dry run — shows plan without deploying |

## FAQ

**Q: How long does each VM take?**
A: Depends on total disk size. AzCopy throughput is ~86 GB/min. A VM with a 128GB OS disk and 256GB data disk takes roughly 15-25 minutes total (including stop/start overhead). A 2TB disk takes longer.

**Q: What happens if one VM fails?**
A: Other VMs are unaffected — each runs independently. The failed VM's original disks are preserved. Debug with `Get-AzResourceGroupDeploymentOperation` and re-run the script with just the failed VM.

**Q: Can I run this during business hours?**
A: Each VM will experience downtime. Plan for a maintenance window. You can stagger using `-ThrottleLimit 1` to migrate one at a time.

**Q: Does this work with VMs that have multiple data disks?**
A: Yes. The template copies ALL disks (OS + all data disks) via SAS.

**Q: What if my VM size doesn't support EAH?**
A: The script checks this in pre-flight and stops before making changes. Resize the VM to a supported SKU first.

**Q: Can I rollback?**
A: The original disks are preserved. To rollback: stop the new VM, swap the OS disk back to the original, and start.

## Linux Notes

- **Linux VMs with ADE on the OS disk cannot be migrated** with this template. DM-Crypt headers on the OS disk make it incompatible with the copy-and-recreate approach. The OS disk must be rebuilt from scratch.
- **Linux VMs with ADE only on data disks** can use this template — the data disks will be copied and the UDE flag cleared.

## Contributing

Pull requests welcome. Please test against non-production VMs before submitting changes.

## License

MIT — See [LICENSE](LICENSE) for details.
