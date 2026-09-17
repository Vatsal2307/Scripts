# build-vm-from-snapshot

Creates a new Azure VM from **OS and data disk snapshots**, with idempotency, logging,
and error handling.

## What it does

- Creates managed disks from an OS snapshot (and optional data disk snapshots)
- Creates supporting network resources (VNet, subnet, NSG, NIC) if they don't exist
- Builds the VM and attaches the disks
- Skips resources that already exist (safe to re-run)
- Writes a timestamped log file next to the script

## Prerequisites

- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount`
- The source snapshots must already exist in the target resource group

## Usage

Two ways to supply configuration:

**1. Config file (recommended)** — edit `vm-config.json`, then:

```powershell
.\BuildVmFromSnap.ps1 -ConfigPath ".\vm-config.json"
.\BuildVmFromSnap.ps1 -ConfigPath ".\vm-config.json" -Force   # skip prompts
```

**2. Inline parameters:**

```powershell
.\BuildVmFromSnap.ps1 -ResourceGroupName "rg-prod" -VMName "vm-web01" `
    -OSSnapshotName "snap-os-001" -Location "UK South"
```

## Parameters

| Parameter            | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `-ConfigPath`        | Path to the JSON config file (config-file mode).     |
| `-ResourceGroupName` | Target resource group (parameter mode).              |
| `-VMName`            | Name of the new VM (parameter mode).                 |
| `-OSSnapshotName`    | Name of the OS disk snapshot (parameter mode).       |
| `-DataSnapshotNames` | Array of data disk snapshot names (optional).        |
| `-Location`          | Azure region (parameter mode).                       |
| `-Force`             | Skip confirmation prompts.                           |

## vm-config.json

The included `vm-config.json` is a template. Fill in `ResourceGroupName`, `VMName`,
`Location`, `OSSnapshotName`, `DataSnapshotNames`, `VMSize`, networking names, and `Tags`.

## Related

Pairs with [`create-snapshots`](../create-snapshots) which produces the source snapshots.
