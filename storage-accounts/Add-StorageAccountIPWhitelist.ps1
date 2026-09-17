param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string[]]$IPAddressOrCIDR,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

# Function to validate IP address or CIDR format
function Test-IPAddressOrCIDR {
    param([string]$IPString)
    
    try {
        # Check if it's a CIDR block
        if ($IPString -match '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
            $parts = $IPString.Split('/')
            $ip = $parts[0]
            $prefix = [int]$parts[1]
            
            # Validate IP part
            $octets = $ip.Split('.')
            foreach ($octet in $octets) {
                if ([int]$octet -lt 0 -or [int]$octet -gt 255) {
                    return $false
                }
            }
            
            # Validate prefix length
            if ($prefix -lt 0 -or $prefix -gt 32) {
                return $false
            }
            
            return $true
        }
        # Check if it's a single IP address
        elseif ($IPString -match '^(\d{1,3}\.){3}\d{1,3}$') {
            $octets = $IPString.Split('.')
            foreach ($octet in $octets) {
                if ([int]$octet -lt 0 -or [int]$octet -gt 255) {
                    return $false
                }
            }
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        return $false
    }
}

# Function to add IP rules to storage account
function Add-StorageAccountIPRule {
    param(
        [string]$StorageAccountName,
        [string]$ResourceGroup,
        [string[]]$IPList,
        [bool]$WhatIfMode
    )
    
    try {
        Write-Host "Processing Storage Account: $StorageAccountName" -ForegroundColor Cyan
        
        # Get current network rule set
        $currentRules = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $StorageAccountName
        
        if ($currentRules.DefaultAction -eq "Allow") {
            Write-Warning "Storage Account '$StorageAccountName' has DefaultAction set to 'Allow'. Network rules may not be effective."
        }
        
        # Get existing IP rules to avoid duplicates
        $existingIPs = @()
        if ($currentRules.IpRules) {
            $existingIPs = $currentRules.IpRules | ForEach-Object { $_.IPAddressOrRange }
        }
        
        $newRulesAdded = 0
        $duplicatesSkipped = 0
        
        foreach ($ip in $IPList) {
            if ($existingIPs -contains $ip) {
                Write-Host "  - IP/CIDR '$ip' already exists, skipping..." -ForegroundColor Yellow
                $duplicatesSkipped++
            }
            else {
                if ($WhatIfMode) {
                    Write-Host "  - [WHAT-IF] Would add IP/CIDR: $ip" -ForegroundColor Green
                }
                else {
                    Write-Host "  - Adding IP/CIDR: $ip" -ForegroundColor Green
                    Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroup -Name $StorageAccountName -IPAddressOrRange $ip
                }
                $newRulesAdded++
            }
        }
        
        Write-Host "  Summary - New rules: $newRulesAdded, Duplicates skipped: $duplicatesSkipped" -ForegroundColor Magenta
        return $true
    }
    catch {
        Write-Error "Failed to process storage account '$StorageAccountName': $($_.Exception.Message)"
        return $false
    }
}

# Main script execution
try {
    Write-Host "=== Storage Account IP Whitelist Script ===" -ForegroundColor Blue
    Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Blue
    Write-Host "IP Addresses/CIDR blocks to add: $($IPAddressOrCIDR -join ', ')" -ForegroundColor Blue
    
    if ($WhatIf) {
        Write-Host "Running in WHAT-IF mode - no changes will be made" -ForegroundColor Yellow
    }
    
    # Validate all IP addresses/CIDR blocks before proceeding
    Write-Host "`nValidating IP addresses/CIDR blocks..." -ForegroundColor Blue
    $invalidIPs = @()
    foreach ($ip in $IPAddressOrCIDR) {
        if (-not (Test-IPAddressOrCIDR -IPString $ip)) {
            $invalidIPs += $ip
        }
    }
    
    if ($invalidIPs.Count -gt 0) {
        Write-Error "Invalid IP addresses/CIDR blocks found: $($invalidIPs -join ', ')"
        Write-Host "Please provide valid IPv4 addresses (e.g., '192.168.1.1') or CIDR blocks (e.g., '192.168.1.0/24')" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "All IP addresses/CIDR blocks are valid." -ForegroundColor Green
    
    # Set subscription if provided
    if ($SubscriptionId) {
        Write-Host "`nSetting Azure subscription context..." -ForegroundColor Blue
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        Write-Host "Subscription context set to: $SubscriptionId" -ForegroundColor Green
    }
    
    # Check if user is logged in to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not logged in to Azure. Please run 'Connect-AzAccount' first."
        exit 1
    }
    
    Write-Host "Current Azure context: $($context.Account.Id) | Subscription: $($context.Subscription.Name)" -ForegroundColor Green
    
    # Get all storage accounts in the resource group
    Write-Host "`nRetrieving storage accounts from resource group '$ResourceGroupName'..." -ForegroundColor Blue
    $storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    
    if ($storageAccounts.Count -eq 0) {
        Write-Warning "No storage accounts found in resource group '$ResourceGroupName'"
        exit 0
    }
    
    Write-Host "Found $($storageAccounts.Count) storage account(s) in resource group '$ResourceGroupName'" -ForegroundColor Green
    
    # Process each storage account
    Write-Host "`nProcessing storage accounts..." -ForegroundColor Blue
    $successCount = 0
    $failureCount = 0
    
    foreach ($storageAccount in $storageAccounts) {
        $result = Add-StorageAccountIPRule -StorageAccountName $storageAccount.StorageAccountName -ResourceGroup $ResourceGroupName -IPList $IPAddressOrCIDR -WhatIfMode $WhatIf.IsPresent
        
        if ($result) {
            $successCount++
        }
        else {
            $failureCount++
        }
        
        Write-Host "" # Empty line for readability
    }
    
    # Final summary
    Write-Host "=== EXECUTION SUMMARY ===" -ForegroundColor Blue
    Write-Host "Total storage accounts processed: $($storageAccounts.Count)" -ForegroundColor Blue
    Write-Host "Successful: $successCount" -ForegroundColor Green
    Write-Host "Failed: $failureCount" -ForegroundColor Red
    
    if ($WhatIf) {
        Write-Host "`nThis was a WHAT-IF run. To apply changes, run the script without the -WhatIf parameter." -ForegroundColor Yellow
    }
    
    if ($failureCount -eq 0) {
        Write-Host "`nScript completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "`nScript completed with some failures. Please check the error messages above." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}

# Example usage:
<#
# Add single IP to all storage accounts in a resource group
.\Add-StorageAccountIPWhitelist.ps1 -ResourceGroupName "myResourceGroup" -IPAddressOrCIDR "203.0.113.1"

# Add multiple IPs and CIDR blocks
.\Add-StorageAccountIPWhitelist.ps1 -ResourceGroupName "myResourceGroup" -IPAddressOrCIDR @("203.0.113.1", "192.168.1.0/24", "10.0.0.0/16")

# Run with specific subscription
.\Add-StorageAccountIPWhitelist.ps1 -ResourceGroupName "myResourceGroup" -IPAddressOrCIDR "203.0.113.1" -SubscriptionId "12345678-1234-1234-1234-123456789012"

# Test run without making changes (What-If mode)
.\Add-StorageAccountIPWhitelist.ps1 -ResourceGroupName "myResourceGroup" -IPAddressOrCIDR "203.0.113.1" -WhatIf
#>