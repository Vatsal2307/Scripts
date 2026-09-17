# az-vpn-set

Deploys Azure **Site-to-Site (S2S) VPN** infrastructure end to end.

## What it does

Creates all components required for an S2S VPN, each step idempotent (skips resources that
already exist):

- Resource Group
- Virtual Network with a `GatewaySubnet` and an internal subnet
- Network Security Group (optional)
- Public IP for the VPN Gateway
- VPN Gateway
- Local Network Gateway (your on-premises side)
- VPN Connection

## Prerequisites

- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount`
- Appropriate permissions to create networking resources

## Configuration

> Edit the **CONFIGURATION SECTION** at the top of the script before running.

Set your resource group, location, address spaces, gateway SKU, on-premises public IP,
and on-premises address prefixes there.

> **Security note:** the script contains a placeholder `$SharedKey = "YourSecureSharedKey123!"`.
> Replace it with your own secure pre-shared key before deploying. Do not commit a real key.

## Usage

```powershell
# Deploy everything
.\AzVPNSet.ps1

# Preview what would be created (no changes)
.\AzVPNSet.ps1 -WhatIf

# Deploy everything except the VPN Gateway (useful for staged testing)
.\AzVPNSet.ps1 -SkipGateway
```

## Parameters

| Parameter      | Description                                             |
| -------------- | ------------------------------------------------------- |
| `-WhatIf`      | Show what would be deployed without creating resources. |
| `-SkipGateway` | Skip VPN Gateway creation.                              |
| `-Force`       | Skip confirmation prompts.                              |

## Notes

- VPN Gateway creation typically takes **20–45 minutes**.
- Run with `-WhatIf` first to validate your configuration.
