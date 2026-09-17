# audit

Finds Azure VMs that have **no Data Collection Rule (DCR) association**.

## What it does

Enumerates every VM in the current subscription context, checks each one for DCR
associations, and prints a table of the VMs that have none. Read-only — it makes no changes.

## Prerequisites

- Azure PowerShell modules (`Az.Accounts`, `Az.Monitor`, `Az.Compute`)
- Authenticated session: `Connect-AzAccount`
- The correct subscription selected: `Set-AzContext -Subscription "<id>"`

## Usage

```powershell
.\audit.ps1
```

No parameters. It operates against whatever subscription is active in your current
Azure context, so set that first.

## Output

A table of VM name + resource group for every VM missing a DCR association.
