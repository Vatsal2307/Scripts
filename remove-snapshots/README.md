# remove-snapshots

Cleans up (deletes) Azure VM disk **snapshots** in a resource group, with filtering and
interactive selection. Complements [`create-snapshots`](../create-snapshots).

## What it does

- Lists all snapshots in the target resource group first
- Deletes either an interactively chosen subset, or a filtered set
- Supports `-WhatIf` for a safe preview and a `yes` confirmation before deleting

## Prerequisites

- Azure PowerShell modules (`Az.Accounts`, `Az.Compute`)
- Authenticated session: `Connect-AzAccount`

## Usage

```powershell
# Interactive: lists every snapshot, then prompts (type 'all', or numbers like 1,3,4)
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup"

# Preview without deleting
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -WhatIf

# Delete snapshots older than 7 days
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -RetentionDays 7

# Delete snapshots for specific VMs
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -VMNames "VM-Web-01","VM-App-02"

# Delete by tag, without prompting
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -Tags @{ "BuildTicket" = "INC12345" } -Force

# Delete ALL snapshots in the group without prompting (use with care)
.\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -Force
```

### Deleting all after the interactive list

Run with only `-ResourceGroupName`. When the `Your selection` prompt appears, type `all`
and press Enter, then type `yes` at the confirmation. To delete a subset, enter the listed
numbers separated by commas (e.g. `1,3,4`).

## Parameters

| Parameter            | Description                                                            |
| -------------------- | ---------------------------------------------------------------------- |
| `-ResourceGroupName` | (Required) Resource group containing the snapshots.                    |
| `-VMNames`           | Only snapshots whose name starts with `{VMName}-`.                     |
| `-NamePattern`       | Wildcard match on snapshot name. Defaults to all (`*`).               |
| `-Tags`              | Hashtable; a snapshot must have all these tags to match.               |
| `-RetentionDays`     | Only delete snapshots older than this many days.                       |
| `-Force`             | Skip the confirmation prompt.                                          |
| `-WhatIf`            | Preview only; deletes nothing.                                         |
