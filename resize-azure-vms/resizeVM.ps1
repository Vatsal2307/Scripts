# PowerShell script to resize Azure Virtual Machines
# Requires Azure PowerShell module (Az.Compute)

# =============================================================================
# CONFIGURATION SECTION - Add your VMs here
# =============================================================================

# Option A: Define VMs with their resource groups and target sizes
$VMList = @(
    @{ Name = "vm-web-01"; ResourceGroup = "rg-prod-east"; CurrentSize = "Standard_D2s_v3"; TargetSize = "Standard_D4s_v3" },
    @{ Name = "vm-web-02"; ResourceGroup = "rg-prod-west"; CurrentSize = "Standard_D2s_v3"; TargetSize = "Standard_D4s_v3" },
    @{ Name = "vm-db-01"; ResourceGroup = "rg-prod-east"; CurrentSize = "Standard_D4s_v3"; TargetSize = "Standard_D8s_v3" },
    @{ Name = "vm-app-01"; ResourceGroup = "rg-dev-east"; CurrentSize = "Standard_B2s"; TargetSize = "Standard_B4ms" },
    @{ Name = "vm-test-01"; ResourceGroup = "rg-test-west"; CurrentSize = "Standard_D2s_v3"; TargetSize = "Standard_D2s_v4" }
    # Add more VMs here following the same pattern
    # @{ Name = "vmname"; ResourceGroup = "resourcegroupname"; CurrentSize = "current_vm_size"; TargetSize = "target_vm_size" },
)

# Option B: If all VMs are in the same resource group and same resize operation
$SingleResourceGroup = "your-resource-group-name"  # Set this if all VMs are in same RG
$SingleCurrentSize = "Standard_D2s_v3"            # Current size of all VMs
$SingleTargetSize = "Standard_D4s_v3"             # Target size for all VMs
$VMNamesOnly = @(
    "vm-web-01",
    "vm-web-02",
    "vm-app-01"
    # Add more VM names here
)

# =============================================================================

# Ensure you're connected to Azure
# Connect-AzAccount

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string[]]$VMNames,
    
    [Parameter(Mandatory=$false)]
    [string]$CurrentSize,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetSize,
    
    [Parameter(Mandatory=$false)]
    [int]$MaxVMs = 50,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Function to resize a VM
function Resize-AzureVM {
    param(
        [string]$VMName,
        [string]$ResourceGroupName,
        [string]$CurrentSize,
        [string]$TargetSize,
        [bool]$WhatIfMode = $false
    )
    
    try {
        Write-Host "Processing VM: $VMName in RG: $ResourceGroupName" -ForegroundColor Yellow
        
        # Get the VM
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        
        # Check current size
        $actualCurrentSize = $vm.HardwareProfile.VmSize
        Write-Host "  Current size: $actualCurrentSize" -ForegroundColor Cyan
        
        # Verify current size matches expected (if provided)
        if ($CurrentSize -and $actualCurrentSize -ne $CurrentSize) {
            Write-Host "  ⚠️  WARNING: Expected size '$CurrentSize' but found '$actualCurrentSize'" -ForegroundColor Yellow
            if (-not $Force) {
                $continue = Read-Host "  Continue anyway? (y/n)"
                if ($continue -ne 'y' -and $continue -ne 'Y') {
                    Write-Host "  ⏭️  Skipping $VMName" -ForegroundColor Yellow
                    return "Skipped"
                }
            }
        }
        
        # Check if already the target size
        if ($actualCurrentSize -eq $TargetSize) {
            Write-Host "  ✓ VM is already the target size: $TargetSize" -ForegroundColor Green
            return "AlreadyCorrectSize"
        }
        
        Write-Host "  Target size: $TargetSize" -ForegroundColor Cyan
        
        # Check if target size is available in the VM's location
        $location = $vm.Location
        $availableSizes = Get-AzVMSize -Location $location | Where-Object { $_.Name -eq $TargetSize }
        
        if (-not $availableSizes) {
            Write-Host "  ✗ Target size '$TargetSize' is not available in location '$location'" -ForegroundColor Red
            return "SizeNotAvailable"
        }
        
        if ($WhatIfMode) {
            Write-Host "  🔍 WHAT-IF: Would resize $VMName from $actualCurrentSize to $TargetSize" -ForegroundColor Magenta
            return "WhatIf"
        }
        
        # Get VM status
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        
        Write-Host "  Current power state: $powerState" -ForegroundColor Cyan
        
        # Resize the VM
        Write-Host "  🔄 Resizing VM..." -ForegroundColor Yellow
        $vm.HardwareProfile.VmSize = $TargetSize
        Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        
        Write-Host "  ✓ Successfully resized $VMName to $TargetSize" -ForegroundColor Green
        
        # Note about restart
        if ($powerState -eq "VM running") {
            Write-Host "  ⚠️  Note: VM may need to restart to complete the resize" -ForegroundColor Yellow
        }
        
        return "Success"
    }
    catch {
        Write-Host "  ✗ Failed to resize $VMName : $($_.Exception.Message)" -ForegroundColor Red
        return "Failed"
    }
}

# Function to get available VM sizes for a location
function Show-AvailableVMSizes {
    param([string]$Location)
    
    Write-Host "`nAvailable VM sizes in $($Location):" -ForegroundColor Cyan
    $sizes = Get-AzVMSize -Location $Location | Sort-Object Name
    $sizes | Format-Table Name, NumberOfCores, MemoryInMB, MaxDataDiskCount -AutoSize
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
    $skippedCount = 0
    $alreadyCorrectCount = 0
    $processedVMs = @()
    $results = @()
    
    if ($WhatIf) {
        Write-Host "🔍 RUNNING IN WHAT-IF MODE - No changes will be made" -ForegroundColor Magenta
    }

    # Option 0: Use predefined VM list from script configuration
    if (-not $VMNames -and -not $ResourceGroupName -and $VMList.Count -gt 0) {
        Write-Host "Processing predefined VMs from script configuration..." -ForegroundColor Cyan
        
        foreach ($vmInfo in $VMList[0..($MaxVMs-1)]) {
            $vmName = $vmInfo.Name
            $rgName = $vmInfo.ResourceGroup
            $currentSize = $vmInfo.CurrentSize
            $targetSize = $vmInfo.TargetSize
            
            $result = Resize-AzureVM -VMName $vmName -ResourceGroupName $rgName -CurrentSize $currentSize -TargetSize $targetSize -WhatIfMode $WhatIf
            
            switch ($result) {
                "Success" { $successCount++ }
                "Failed" { $failureCount++ }
                "Skipped" { $skippedCount++ }
                "AlreadyCorrectSize" { $alreadyCorrectCount++ }
                "WhatIf" { $successCount++ }
            }
            
            $processedVMs += $vmName
            $results += @{ VM = $vmName; ResourceGroup = $rgName; Result = $result; CurrentSize = $currentSize; TargetSize = $targetSize }
        }
    }
    # Option 0B: Use single resource group with predefined names
    elseif (-not $VMNames -and -not $ResourceGroupName -and $VMNamesOnly.Count -gt 0 -and $SingleResourceGroup -and $SingleTargetSize) {
        Write-Host "Processing predefined VMs from single resource group: $SingleResourceGroup..." -ForegroundColor Cyan
        
        foreach ($vmName in $VMNamesOnly[0..($MaxVMs-1)]) {
            $result = Resize-AzureVM -VMName $vmName -ResourceGroupName $SingleResourceGroup -CurrentSize $SingleCurrentSize -TargetSize $SingleTargetSize -WhatIfMode $WhatIf
            
            switch ($result) {
                "Success" { $successCount++ }
                "Failed" { $failureCount++ }
                "Skipped" { $skippedCount++ }
                "AlreadyCorrectSize" { $alreadyCorrectCount++ }
                "WhatIf" { $successCount++ }
            }
            
            $processedVMs += $vmName
            $results += @{ VM = $vmName; ResourceGroup = $SingleResourceGroup; Result = $result; CurrentSize = $SingleCurrentSize; TargetSize = $SingleTargetSize }
        }
    }
    # Option 1: Use provided VM names with parameters
    elseif ($VMNames -and $VMNames.Count -gt 0 -and $ResourceGroupName -and $TargetSize) {
        Write-Host "Processing specified VMs with command line parameters..." -ForegroundColor Cyan
        
        foreach ($vmName in $VMNames[0..($MaxVMs-1)]) {
            $result = Resize-AzureVM -VMName $vmName -ResourceGroupName $ResourceGroupName -CurrentSize $CurrentSize -TargetSize $TargetSize -WhatIfMode $WhatIf
            
            switch ($result) {
                "Success" { $successCount++ }
                "Failed" { $failureCount++ }
                "Skipped" { $skippedCount++ }
                "AlreadyCorrectSize" { $alreadyCorrectCount++ }
                "WhatIf" { $successCount++ }
            }
            
            $processedVMs += $vmName
            $results += @{ VM = $vmName; ResourceGroup = $ResourceGroupName; Result = $result; CurrentSize = $CurrentSize; TargetSize = $TargetSize }
        }
    }
    # Option 2: Process all VMs in a resource group
    elseif ($ResourceGroupName -and $TargetSize) {
        Write-Host "Getting all VMs from resource group: $ResourceGroupName" -ForegroundColor Cyan
        $vms = Get-AzVM -ResourceGroupName $ResourceGroupName | Select-Object -First $MaxVMs
        
        foreach ($vm in $vms) {
            $result = Resize-AzureVM -VMName $vm.Name -ResourceGroupName $ResourceGroupName -CurrentSize $CurrentSize -TargetSize $TargetSize -WhatIfMode $WhatIf
            
            switch ($result) {
                "Success" { $successCount++ }
                "Failed" { $failureCount++ }
                "Skipped" { $skippedCount++ }
                "AlreadyCorrectSize" { $alreadyCorrectCount++ }
                "WhatIf" { $successCount++ }
            }
            
            $processedVMs += $vm.Name
            $results += @{ VM = $vm.Name; ResourceGroup = $ResourceGroupName; Result = $result; CurrentSize = $CurrentSize; TargetSize = $TargetSize }
        }
    }
    else {
        Write-Host "❌ Insufficient parameters provided. Please use one of the following methods:" -ForegroundColor Red
        Write-Host "1. Configure the VM list in the script and run without parameters" -ForegroundColor Yellow
        Write-Host "2. Use: -ResourceGroupName 'rg-name' -TargetSize 'Standard_D4s_v3'" -ForegroundColor Yellow
        Write-Host "3. Use: -VMNames @('vm1','vm2') -ResourceGroupName 'rg-name' -TargetSize 'Standard_D4s_v3'" -ForegroundColor Yellow
        return
    }

    # Summary
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Total VMs processed: $($processedVMs.Count)" -ForegroundColor White
    Write-Host "Successful resizes: $successCount" -ForegroundColor Green
    Write-Host "Failed resizes: $failureCount" -ForegroundColor Red
    Write-Host "Skipped VMs: $skippedCount" -ForegroundColor Yellow
    Write-Host "Already correct size: $alreadyCorrectCount" -ForegroundColor Blue
    
    if ($processedVMs.Count -gt 0) {
        Write-Host "`nDetailed Results:" -ForegroundColor White
        foreach ($result in $results) {
            $color = switch ($result.Result) {
                "Success" { "Green" }
                "Failed" { "Red" }
                "Skipped" { "Yellow" }
                "AlreadyCorrectSize" { "Blue" }
                "WhatIf" { "Magenta" }
                default { "Gray" }
            }
            Write-Host "  $($result.VM) [$($result.ResourceGroup)] - $($result.Result)" -ForegroundColor $color
        }
    }

    # Show available sizes option
    if ($failureCount -gt 0) {
        $showSizes = Read-Host "`nWould you like to see available VM sizes for troubleshooting? (y/n)"
        if ($showSizes -eq 'y' -or $showSizes -eq 'Y') {
            $location = Read-Host "Enter the Azure region (e.g., East US, West US 2)"
            if ($location) {
                Show-AvailableVMSizes -Location $location
            }
        }
    }
}
catch {
    Write-Host "Script execution failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Usage examples:
<#
# Example 1: Use predefined VM list in script (Method 1)
.\Resize-AzureVMs.ps1

# Example 2: What-if mode to see what would happen
.\Resize-AzureVMs.ps1 -WhatIf

# Example 3: Resize specific VMs
.\Resize-AzureVMs.ps1 -VMNames @("vm1", "vm2") -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3"

# Example 4: Resize all VMs in a resource group
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3"

# Example 5: Resize with current size verification
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -CurrentSize "Standard_D2s_v3" -TargetSize "Standard_D4s_v3"

# Example 6: Force resize without size verification prompts
.\Resize-AzureVMs.ps1 -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3" -Force

# Example 7: Process specific subscription
.\Resize-AzureVMs.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "myRG" -TargetSize "Standard_D4s_v3"
#>