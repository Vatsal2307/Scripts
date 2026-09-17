# PowerShell script to set TLS 1.2 for Azure Storage Accounts
# Requires Azure PowerShell module (Az.Storage)

# Ensure you're connected to Azure
# Connect-AzAccount

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$StorageAccountNames,
    
    [Parameter(Mandatory=$false)]
    [int]$MaxAccounts = 20
)

# Function to set TLS version for a storage account
function Set-StorageAccountTLS {
    param(
        [string]$StorageAccountName,
        [string]$ResourceGroupName
    )
    
    try {
        Write-Host "Setting TLS 1.2 for storage account: $StorageAccountName" -ForegroundColor Yellow
        
        # Set minimum TLS version to 1.2
        Set-AzStorageAccount -ResourceGroupName $ResourceGroupName `
                           -Name $StorageAccountName `
                           -MinimumTlsVersion TLS1_2 `
                           -EnableHttpsTrafficOnly $true
        
        Write-Host "✓ Successfully set TLS 1.2 for $StorageAccountName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "✗ Failed to set TLS for $StorageAccountName : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main execution
try {
    # Set subscription if provided
    if ($SubscriptionId) {
        Write-Host "Setting subscription context to: $SubscriptionId" -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $SubscriptionId
    }

    $successCount = 0
    $failureCount = 0
    $processedAccounts = @()

    # Option 0: Use predefined storage account list from script configuration
    if (-not $StorageAccountNames -and -not $ResourceGroupName -and $StorageAccountList.Count -gt 0) {
        Write-Host "Processing predefined storage accounts from script configuration..." -ForegroundColor Cyan
        
        foreach ($accountInfo in $StorageAccountList[0..($MaxAccounts-1)]) {
            $accountName = $accountInfo.Name
            $rgName = $accountInfo.ResourceGroup
            
            if (Set-StorageAccountTLS -StorageAccountName $accountName -ResourceGroupName $rgName) {
                $successCount++
            } else {
                $failureCount++
            }
            $processedAccounts += $accountName
        }
    }
    # Option 0B: Use single resource group with predefined names
    elseif (-not $StorageAccountNames -and -not $ResourceGroupName -and $StorageAccountNamesOnly.Count -gt 0 -and $SingleResourceGroup) {
        Write-Host "Processing predefined storage accounts from single resource group: $SingleResourceGroup..." -ForegroundColor Cyan
        
        foreach ($accountName in $StorageAccountNamesOnly[0..($MaxAccounts-1)]) {
            if (Set-StorageAccountTLS -StorageAccountName $accountName -ResourceGroupName $SingleResourceGroup) {
                $successCount++
            } else {
                $failureCount++
            }
            $processedAccounts += $accountName
        }
    }
    # Option 1: Use provided storage account names
    if ($StorageAccountNames -and $StorageAccountNames.Count -gt 0) {
        Write-Host "Processing specified storage accounts..." -ForegroundColor Cyan
        
        # If no resource group specified, try to find each storage account
        if (-not $ResourceGroupName) {
            foreach ($accountName in $StorageAccountNames[0..($MaxAccounts-1)]) {
                try {
                    $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $accountName }
                    if ($storageAccount) {
                        $rgName = $storageAccount.ResourceGroupName
                        if (Set-StorageAccountTLS -StorageAccountName $accountName -ResourceGroupName $rgName) {
                            $successCount++
                        } else {
                            $failureCount++
                        }
                        $processedAccounts += $accountName
                    } else {
                        Write-Host "✗ Storage account '$accountName' not found" -ForegroundColor Red
                        $failureCount++
                    }
                }
                catch {
                    Write-Host "✗ Error processing $accountName : $($_.Exception.Message)" -ForegroundColor Red
                    $failureCount++
                }
            }
        } else {
            # Process with specified resource group
            foreach ($accountName in $StorageAccountNames[0..($MaxAccounts-1)]) {
                if (Set-StorageAccountTLS -StorageAccountName $accountName -ResourceGroupName $ResourceGroupName) {
                    $successCount++
                } else {
                    $failureCount++
                }
                $processedAccounts += $accountName
            }
        }
    }
    # Option 2: Get storage accounts from resource group
    elseif ($ResourceGroupName) {
        Write-Host "Getting storage accounts from resource group: $ResourceGroupName" -ForegroundColor Cyan
        $storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName | Select-Object -First $MaxAccounts
        
        foreach ($account in $storageAccounts) {
            if (Set-StorageAccountTLS -StorageAccountName $account.StorageAccountName -ResourceGroupName $ResourceGroupName) {
                $successCount++
            } else {
                $failureCount++
            }
            $processedAccounts += $account.StorageAccountName
        }
    }
    # Option 3: Get storage accounts from entire subscription
    else {
        Write-Host "Getting storage accounts from current subscription..." -ForegroundColor Cyan
        $storageAccounts = Get-AzStorageAccount | Select-Object -First $MaxAccounts
        
        foreach ($account in $storageAccounts) {
            if (Set-StorageAccountTLS -StorageAccountName $account.StorageAccountName -ResourceGroupName $account.ResourceGroupName) {
                $successCount++
            } else {
                $failureCount++
            }
            $processedAccounts += $account.StorageAccountName
        }
    }

    # Summary
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Total accounts processed: $($processedAccounts.Count)" -ForegroundColor White
    Write-Host "Successful updates: $successCount" -ForegroundColor Green
    Write-Host "Failed updates: $failureCount" -ForegroundColor Red
    
    if ($processedAccounts.Count -gt 0) {
        Write-Host "`nProcessed accounts:" -ForegroundColor White
        $processedAccounts | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    }

    # Verification option
    $verify = Read-Host "`nWould you like to verify the TLS settings? (y/n)"
    if ($verify -eq 'y' -or $verify -eq 'Y') {
        Write-Host "`nVerifying TLS settings..." -ForegroundColor Cyan
        foreach ($accountName in $processedAccounts) {
            try {
                $account = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $accountName }
                if ($account) {
                    $tlsVersion = $account.MinimumTlsVersion
                    $httpsOnly = $account.EnableHttpsTrafficOnly
                    $status = if ($tlsVersion -eq "TLS1_2" -and $httpsOnly) { "✓" } else { "✗" }
                    Write-Host "$status $accountName - TLS: $tlsVersion, HTTPS Only: $httpsOnly" -ForegroundColor $(if ($status -eq "✓") { "Green" } else { "Red" })
                }
            }
            catch {
                Write-Host "✗ Could not verify $accountName" -ForegroundColor Red
            }
        }
    }
}
catch {
    Write-Host "Script execution failed: $($_.Exception.Message)" -ForegroundColor Red
}



# Usage examples:
<#
# Example 1: Process specific storage accounts
.\Set-StorageAccountTLS.ps1 -StorageAccountNames @("storage1", "storage2", "storage3")

# Example 2: Process storage accounts in a specific resource group
.\Set-StorageAccountTLS.ps1 -ResourceGroupName "myResourceGroup"

# Example 3: Process storage accounts in a specific subscription and resource group
.\Set-StorageAccountTLS.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "myResourceGroup"

# Example 4: Process first 10 storage accounts from current subscription
.\Set-StorageAccountTLS.ps1 -MaxAccounts 10

# Example 5: Use the predefined list in the script
# Just run the script without parameters to use $StorageAccountList
#>