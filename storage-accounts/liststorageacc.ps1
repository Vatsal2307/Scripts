# Script to list all storage accounts across all subscriptions in an Azure tenant
# Requires Az PowerShell module

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$WhatIf
)

# Ensure you're connected to Azure
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not connected to Azure. Please run Connect-AzAccount first." -ForegroundColor Red
        exit
    }
    Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "Error checking Azure connection: $_" -ForegroundColor Red
    exit
}

# Get all subscriptions
Write-Host "`nRetrieving all subscriptions..." -ForegroundColor Cyan
$subscriptions = Get-AzSubscription

Write-Host "Found $($subscriptions.Count) subscription(s)" -ForegroundColor Green

# Initialize array to store results
$allStorageAccounts = [System.Collections.ArrayList]::new()

# Loop through each subscription
foreach ($sub in $subscriptions) {
    Write-Host "`nProcessing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Yellow
    
    try {
        # Set context to current subscription
        if ($PSCmdlet.ShouldProcess("Subscription: $($sub.Name)", "Set Azure Context")) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
            
            # Get all storage accounts in this subscription
            $storageAccounts = Get-AzStorageAccount -ErrorAction Stop
        } else {
            continue
        }
        
        if ($storageAccounts -and $storageAccounts.Count -gt 0) {
            Write-Host "  Found $($storageAccounts.Count) storage account(s)" -ForegroundColor Green
            
            # Add subscription info to each storage account
            foreach ($sa in $storageAccounts) {
                [void]$allStorageAccounts.Add([PSCustomObject]@{
                    SubscriptionName = $sub.Name
                    SubscriptionId = $sub.Id
                    StorageAccountName = $sa.StorageAccountName
                    ResourceGroupName = $sa.ResourceGroupName
                    Location = $sa.Location
                    SkuName = $sa.Sku.Name
                    Kind = $sa.Kind
                    CreationTime = $sa.CreationTime
                    PrimaryLocation = $sa.PrimaryLocation
                    AccessTier = $sa.AccessTier
                    EnableHttpsTrafficOnly = $sa.EnableHttpsTrafficOnly
                })
            }
        } else {
            Write-Host "  No storage accounts found" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Error processing subscription: $_" -ForegroundColor Red
    }
}

# Display results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SUMMARY: Total Storage Accounts Found: $($allStorageAccounts.Count)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Display in a formatted table
if ($allStorageAccounts.Count -gt 0) {
    $allStorageAccounts | Format-Table -AutoSize
}

# Optional: Export to CSV
if (-not $WhatIf) {
    $exportChoice = Read-Host "`nWould you like to export results to CSV? (Y/N)"
    if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
    $csvPath = "AzureStorageAccounts_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    
        $allStorageAccounts | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "Results exported to: $csvPath" -ForegroundColor Green
    }
}