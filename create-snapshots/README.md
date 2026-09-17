# create-snapshots

Creates **incremental snapshots** of the OS and data disks for one or more Azure VMs.

## What it does

- Iterates a list of VMs in a resource group
- Creates incremental snapshots for each VM's OS disk and every data disk
- Matches the new snapshot's SKU to the most recent existing snapshot for consistency
- Applies common tags (Rax tagging standard)
- Names snapshots predictably:
  - OS: `{VMName}-OSDisk-Snapshot-{yyyyMMdd}`
  - Data: `{VMName}-DataDisk-{Lun}-Snapshot-{yyyyMMdd}`

## Prerequisites

- Azure PowerShell modules (`Az.Accounts`, `Az.Compute`)
- Authenticated session: `Connect-AzAccount`

## Usage

```powershell
.\snapshot.ps1 -ResourceGroupName "MyResourceGroup" `
    -VMNames "VM-Web-01","VM-App-02" `
    -SnapshotTags @{ "BuildBy" = "Automation"; "BuildDate" = "$(Get-Date -Format 'yyyy-MM-dd')"; "BuildTicket" = "INC12345" }
```

## Parameters

| Parameter            | Description                                     |
| -------------------- | ----------------------------------------------- |
| `-ResourceGroupName` | (Required) Resource group containing the VMs.   |
| `-VMNames`           | (Required) Array of VM names to snapshot.       |
| `-SnapshotTags`      | (Required) Hashtable of tags for the snapshots. |

## Related

- [`remove-snapshots`](../remove-snapshots) — clean up snapshots created here
- [`build-vm-from-snapshot`](../build-vm-from-snapshot) — rebuild a VM from these snapshots
