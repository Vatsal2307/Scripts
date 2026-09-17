# get-appgateway-tls-version

Reports the **TLS/SSL policy version** configured on Azure **Application Gateways** across
one or more subscriptions. Read-only.

## What it does

Connects to Azure (optionally to a specific tenant), iterates the requested subscriptions,
and inspects each Application Gateway's SSL policy, with logging and error handling.

## Prerequisites

- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount` (or let the script prompt)
- Reader access on the target subscriptions

## Usage

```powershell
# Check all accessible subscriptions in the default tenant
.\Get-AppGatewayTLSVersion.ps1

# Target a specific tenant and subscriptions
.\Get-AppGatewayTLSVersion.ps1 -TenantId "12345678-1234-1234-1234-123456789012" `
    -SubscriptionId @("sub1", "sub2")
```

## Parameters

| Parameter         | Description                                                      |
| ----------------- | ---------------------------------------------------------------- |
| `-TenantId`       | Azure AD tenant ID (GUID). Optional; uses default tenant if omitted. |
| `-SubscriptionId` | Array of subscription IDs to check. Optional; all accessible if omitted. |
