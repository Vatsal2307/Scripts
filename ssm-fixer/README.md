# ssm-fixer

Auto-remediates **AWS SSM Agent** failures on Azure VMs via **Azure Run Command** — no RDP
or SSH required. Supports both Windows and Linux (OS auto-detected).

## Files

- `Invoke-SSMFixer.ps1` — entry point (run this)
- `SSMFixer.Core.ps1` — shared schema and workflow engine, dot-sourced by the entry point

Keep both files together in the same folder.

## How it works

The tool escalates through steps, stopping as soon as the agent is healthy:

1. **Diagnose** — service status, agent version, registration, connectivity, logs
2. **Restart** — restart the SSM Agent service (low risk)
3. **Reregister** — clear registration and re-register via bootstrap (medium risk)
4. **Reinstall** — full uninstall + reinstall via bootstrap (high risk)

By default it diagnoses, shows a menu of suggested actions, and waits for your choice
before changing anything.

## Prerequisites

- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount`
- VM Run Command permissions on the target VM

## Usage

```powershell
# Interactive: diagnose, then choose an action
.\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01"

# Diagnostics only, no changes
.\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -DiagnoseOnly

# Headless: decide and apply remediation automatically
.\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Auto

# Structured JSON output (implies -Auto) for pipelines
.\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Json

# Jump straight to a specific step
.\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Region "us-east-1" -SkipToStep 3
```

## Parameters

| Parameter            | Description                                                        |
| -------------------- | ----------------------------------------------------------------- |
| `-ResourceGroupName` | (Required) Resource group of the target VM.                       |
| `-VMName`            | (Required) Target VM name.                                         |
| `-Region`            | AWS region override for SSM endpoints. Auto-detected if omitted.  |
| `-Platform`          | Bootstrap platform: Azure (default), Dedicated, VMWare, GCP, OpenStack. |
| `-HttpProxy`         | Proxy URL if the VM uses one.                                     |
| `-DiagnoseOnly`      | Run diagnostics only (step 1).                                    |
| `-MaxStep`           | Highest step to attempt (1–4, default 4).                         |
| `-SkipToStep`        | Jump directly to a step (1–4, default 1).                         |
| `-TimeoutSeconds`    | Per Run Command timeout (default 300).                            |
| `-Json`              | Emit a single JSON result object (implies `-Auto`).               |
| `-Auto`              | Run without interactive prompts.                                  |

## Related

- [`check-azlinux-ssm`](../check-azlinux-ssm) / [`check-azwindows-ssm`](../check-azwindows-ssm) — quick status checks
- [`remove-ssm-agent`](../remove-ssm-agent) — uninstall the agent
