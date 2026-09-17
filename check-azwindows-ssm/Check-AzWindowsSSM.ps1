<#
.SYNOPSIS
    Checks the status of the AmazonSSMAgent service on all Windows VMs in a specified Azure Resource Group.

.DESCRIPTION
    This script retrieves all Windows VMs within a target Resource Group and uses the Azure VM Run Command
    feature to remotely execute 'Get-Service -Name "AmazonSSMAgent"'.

.EXAMPLE
    .\Check-AzWindowsSSM.ps1 -ResourceGroupName "my-production-rg"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="The name of the Azure Resource Group to check.")]
    [string]$ResourceGroupName
)

# Enforce strict error handling for robustness
$ErrorActionPreference = "Stop"

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Azure Windows VM SSM Agent Status Checker" -ForegroundColor Cyan
Write-Host " Target Resource Group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Verify Azure PowerShell login context
try {
    # Suppress output; we just want to ensure the session context exists
    $null = Get-AzContext -ErrorAction Stop
}
catch {
    Write-Error "You are not logged into Azure PowerShell. Please run 'Connect-AzAccount' first."
    exit 1
}

Write-Host "`nFetching a list of Windows VMs in resource group '$ResourceGroupName'..."

# 2. Retrieve Windows VMs ONLY for the specified Resource Group
try {
    # Get all VMs in the Resource Group, then filter client-side for Windows OS
    $allVms = Get-AzVM -ResourceGroupName $ResourceGroupName
    $windowsVms = $allVms | Where-Object { $_.StorageProfile.OsDisk.OsType -eq 'Windows' }
}
catch {
    Write-Error "Failed to retrieve VMs. Verify the Resource Group name and your RBAC permissions."
    Write-Error $_.Exception.Message
    exit 1
}

# Cast to an array to ensure .Count works accurately even if only one VM is returned
$windowsVmsArray = @($windowsVms)

if ($windowsVmsArray.Count -eq 0) {
    Write-Host "No Windows VMs found in resource group '$ResourceGroupName'." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($windowsVmsArray.Count) Windows VM(s). Initiating Run Command execution..."
Write-Host "------------------------------------------------------"

# 3. Iterate through each VM and execute the command remotely
foreach ($vm in $windowsVmsArray) {
    Write-Host "Checking VM: $($vm.Name) | Resource Group: $($vm.ResourceGroupName)" -ForegroundColor Cyan
    
    try {
        # Execute the PowerShell command via Azure VM Run Command
        # -ScriptString allows inline execution without needing to upload a local .ps1 file
        $runResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $vm.ResourceGroupName `
            -VMName $vm.Name `
            -CommandId 'RunPowerShellScript' `
            -ScriptString 'Get-Service -Name "AmazonSSMAgent"' `
            -ErrorAction Stop
        
        # The RunCommand payload stores the standard output in the first array item of the Value property
        $outputMessage = $runResult.Value[0].Message
        
        Write-Host "Status Output:`n$outputMessage"
    }
    catch {
        Write-Host "Error executing command on $($vm.Name)." -ForegroundColor Red
        Write-Host "Note: Ensure the VM is powered on and the Azure Virtual Machine Agent is healthy." -ForegroundColor Yellow
        Write-Host "Log: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "------------------------------------------------------"
}

Write-Host "Operation successfully completed." -ForegroundColor Cyan