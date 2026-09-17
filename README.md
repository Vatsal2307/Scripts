# Azure Admin Scripts

A collection of PowerShell and Bash scripts for administering Azure infrastructure —
VMs, snapshots, storage accounts, networking, and the AWS SSM Agent on Azure VMs.

Each subfolder is a self-contained script (or tool) with its own README.

## Scripts

| Folder | Purpose |
| ------ | ------- |
| [`audit`](./audit) | Find Azure VMs with no Data Collection Rule (DCR) association. |
| [`az-vpn-set`](./az-vpn-set) | Deploy Azure Site-to-Site VPN infrastructure end to end. |
| [`build-vm-from-snapshot`](./build-vm-from-snapshot) | Create a new VM from OS/data disk snapshots. |
| [`check-azlinux-ssm`](./check-azlinux-ssm) | Check Amazon SSM Agent status on Linux VMs (PowerShell + Bash). |
| [`check-azwindows-ssm`](./check-azwindows-ssm) | Check AmazonSSMAgent service on Windows VMs in a resource group. |
| [`create-snapshots`](./create-snapshots) | Create incremental snapshots of VM OS and data disks. |
| [`get-appgateway-tls-version`](./get-appgateway-tls-version) | Report TLS/SSL policy on Application Gateways. |
| [`get-iis-worker-process-info`](./get-iis-worker-process-info) | Map an IIS worker PID to its app pool and sites. |
| [`remove-snapshots`](./remove-snapshots) | Clean up disk snapshots with filtering and interactive selection. |
| [`remove-ssm-agent`](./remove-ssm-agent) | Uninstall the Amazon SSM Agent (Windows + Linux). |
| [`resize-azure-vms`](./resize-azure-vms) | Resize VMs in bulk or individually, with what-if preview. |
| [`ssm-fixer`](./ssm-fixer) | Auto-remediate SSM Agent failures via Azure Run Command. |
| [`storage-accounts`](./storage-accounts) | Storage account utilities: TLS, IP whitelisting, listing, blob search. |
| [`traffic-manager-non-azure-endpoints`](./traffic-manager-non-azure-endpoints) | List Traffic Manager endpoints that are not Azure endpoints. |

## Prerequisites

Most scripts require:

- [Azure PowerShell (`Az`)](https://learn.microsoft.com/powershell/azure/install-azure-powershell) or the [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- An authenticated session (`Connect-AzAccount` or `az login`)
- Appropriate Azure RBAC permissions for the resources involved

See each script's own README for its specific requirements, parameters, and examples.

## Notes

- Several scripts support `-WhatIf` for a safe, no-change preview. Use it first.
- Do not commit secrets. Provide subscription IDs, tenant IDs, and keys at runtime via
  parameters rather than hardcoding them.
