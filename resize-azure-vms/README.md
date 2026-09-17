# resize-azure-vms

Resizes Azure Virtual Machines to a target size, in bulk or individually, with a
what-if preview and size-availability checks.

This folder contains **two variants** of the tool:

- `Resize-AzureVMs.ps1` — parameter-driven (recommended for automation)
- `resizeVM.ps1` — same core logic, but also supports an in-script VM list you edit at the top

Pick whichever fits your workflow; they don't need to be run together.

## Prerequisites

- Azure PowerShell module (`Az.Compute`)
- Authenticated session: `Connect-AzAccount`

## Usage

```powershell
# Preview (no changes)
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3" -WhatIf

# Resize specific VMs
.\Resize-AzureVMs.ps1 -VMNames @("vm1","vm2") -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3"

# Resize all VMs in a resource group
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3"

# Verify current size before resizing
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -CurrentSize "Standard_D2s_v3" -TargetSize "Standard_D4s_v3"

# Skip size-mismatch prompts
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3" -Force
```

For `resizeVM.ps1`, you can instead edit the `$VMList` block at the top and run it with no
parameters.

## Parameters

| Parameter            | Description                                                    |
| -------------------- | ------------------------------------------------------------- |
| `-SubscriptionId`    | Subscription to operate in.                                   |
| `-ResourceGroupName` | Resource group of the VMs.                                     |
| `-VMNames`           | Array of specific VM names to resize.                          |
| `-CurrentSize`       | Expected current size; warns if a VM doesn't match.            |
| `-TargetSize`        | Desired new size (e.g. `Standard_D4s_v3`).                     |
| `-MaxVMs`            | Cap on how many VMs to process.                                |
| `-WhatIf`            | Preview only; makes no changes.                                |
| `-Force`             | Skip confirmation prompts.                                     |

## Notes

- A running VM may need to restart for the resize to complete.
- The script checks that the target size is available in the VM's region before resizing.
