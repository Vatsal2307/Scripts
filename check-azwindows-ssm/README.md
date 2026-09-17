# check-azwindows-ssm

Checks the status of the **AmazonSSMAgent** service on all **Windows** VMs in a given Azure
resource group. Read-only — it queries service status via Azure VM Run Command.

## What it does

Retrieves all Windows VMs in the specified resource group and remotely runs
`Get-Service -Name "AmazonSSMAgent"` on each via `Invoke-AzVMRunCommand`, printing the result.

## Prerequisites

- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount`
- Reader + VM Run Command permissions on the resource group

## Usage

```powershell
.\Check-AzWindowsSSM.ps1 -ResourceGroupName "my-production-rg"
```

## Parameters

| Parameter            | Description                                    |
| -------------------- | ---------------------------------------------- |
| `-ResourceGroupName` | (Required) Resource group of the Windows VMs.  |

## Related

- [`check-azlinux-ssm`](../check-azlinux-ssm) — the Linux equivalent
- [`remove-ssm-agent`](../remove-ssm-agent) — uninstall the agent
