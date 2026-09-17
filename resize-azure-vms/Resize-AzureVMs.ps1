<#
.SYNOPSIS
    Resizes one or more Azure Virtual Machines within a specified Resource Group.

.DESCRIPTION
    This script automates the process of resizing Azure VMs. It can target a single VM, a list of VMs, or all VMs in a resource group.
    The script first checks the power state of the VM. If the VM is running, it will be deallocated before the resize operation, and then started again afterward.
    If the VM is already deallocated, the script will simply perform the resize and start it.
    This script is designed to be idempotent.

.PARAMETER SubscriptionId
    The ID of the Azure subscription where the resources are located.

.PARAMETER ResourceGroupName
    The name of the Resource Group containing the Virtual Machine(s).

.PARAMETER VMName
    (Optional) The name of a specific Virtual Machine to resize.
    To resize multiple specific VMs, provide a comma-separated list of names (e.g., "vm1","vm2").
    If this parameter is omitted, the script will target all VMs in the specified Resource Group.

.PARAMETER NewSize
    The target SKU for the Virtual Machine(s) (e.g., "Standard_D4s_v3").

.EXAMPLE
    .\Resize-AzureVM.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "MyResourceGroup" -VMName "MyVM" -NewSize "Standard_B2s"
    Description: Resizes a single VM named "MyVM" in "MyResourceGroup" to the "Standard_B2s" size.

.EXAMPLE
    .\Resize-AzureVM.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "MyResourceGroup" -VMName "vm1","vm2" -NewSize "Standard_F8s_v2"
    Description: Resizes two VMs, "vm1" and "vm2", in "MyResourceGroup" to the "Standard_F8s_v2" size.

.EXAMPLE
    .\Resize-AzureVM.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "MyResourceGroup" -NewSize "Standard_DS2_v2"
    Description: Resizes all Virtual Machines within the "MyResourceGroup" to the "Standard_DS2_v2" size.

.NOTES
    Author: Gemini
    Version: 1.0
    Requires: Az.Accounts and Az.Compute PowerShell modules.
    Make sure you are authenticated to Azure before running this script (e.g., via Connect-AzAccount).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The ID of the Azure subscription.")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "The name of the Resource Group containing the VM(s).")]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Optional. The name(s) of the VM(s) to resize. If not provided, all VMs in the resource group will be targeted.")]
    [string[]]$VMName,

    [Parameter(Mandatory = $true, HelpMessage = "The new size for the VM(s).")]
    [string]$NewSize
)

Function Resize-TargetVM {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$VM
    )

    try {
        Write-Verbose "Processing VM: $($VM.Name)"

        # Check if the VM is already the target size
        if ($VM.HardwareProfile.VmSize -eq $NewSize) {
            Write-Host "VM '$($VM.Name)' is already size '$NewSize'. No action needed."
            # Ensure the VM is running if it was found in a stopped state
            $status = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
            $powerState = $status.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -ExpandProperty DisplayStatus
            if ($powerState -ne "VM running") {
                 if ($PSCmdlet.ShouldProcess("Start VM '$($VM.Name)'", "VM is already the correct size but is not running.")) {
                    Write-Host "Starting VM '$($VM.Name)' as it is the correct size but not running."
                    Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
                 }
            }
            return
        }

        # Get the power state of the VM
        $vmStatus = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
        $powerState = $vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -ExpandProperty DisplayStatus
        Write-Verbose "Current power state for VM '$($VM.Name)': $powerState"

        # Deallocate the VM if it is running
        if ($powerState -eq "VM running") {
            Write-Host "VM '$($VM.Name)' is running. Deallocating before resize..."
            if ($PSCmdlet.ShouldProcess("Stop VM '$($VM.Name)'", "Deallocation is required to change VM size.")) {
                Stop-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force
            }
        }
        else {
            Write-Host "VM '$($VM.Name)' is already in a stopped/deallocated state."
        }

        # Set the new VM size
        Write-Host "Setting VM size for '$($VM.Name)' to '$NewSize'..."
        $VM.HardwareProfile.VmSize = $NewSize

        # Update the VM configuration
        if ($PSCmdlet.ShouldProcess("Update VM '$($VM.Name)' to size '$NewSize'", "Applying the new size configuration to the VM.")) {
            Update-AzVM -VM $VM -ResourceGroupName $VM.ResourceGroupName
        }

        # Start the VM
        Write-Host "Starting VM '$($VM.Name)'..."
        if ($PSCmdlet.ShouldProcess("Start VM '$($VM.Name)'", "Restarting the VM after successful resize.")) {
            Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
        }

        Write-Host "Successfully resized VM '$($VM.Name)' to '$NewSize'." -ForegroundColor Green
    }
    catch {
        Write-Error "An error occurred while processing VM '$($VM.Name)': $_"
        # Attempt to start the VM if it was stopped but the resize failed
        if ($powerState -eq "VM running") {
            try {
                Write-Warning "Attempting to restart VM '$($VM.Name)' to its original state."
                Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
            }
            catch {
                Write-Error "Failed to restart VM '$($VM.Name)'. Manual intervention may be required."
            }
        }
    }
}

try {
    # Connect to Azure and set context
    Write-Host "Connecting to Azure and setting subscription context..."
    $context = Get-AzContext
    if ($context.Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
    Write-Host "Successfully set context to subscription: $SubscriptionId" -ForegroundColor Cyan

    $targetVMs = @()
    if ($PSBoundParameters.ContainsKey('VMName')) {
        Write-Host "Targeting specific VM(s) provided: $($VMName -join ', ')"
        foreach ($name in $VMName) {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction SilentlyContinue
            if ($vm) {
                $targetVMs += $vm
            }
            else {
                Write-Warning "VM '$name' not found in resource group '$ResourceGroupName'."
            }
        }
    }
    else {
        Write-Host "No specific VM name provided. Targeting all VMs in resource group '$ResourceGroupName'."
        $targetVMs = Get-AzVM -ResourceGroupName $ResourceGroupName
    }

    if ($targetVMs.Count -eq 0) {
        Write-Warning "No VMs found to process."
        return
    }

    Write-Host "$($targetVMs.Count) VM(s) targeted for resize operation." -ForegroundColor Yellow
    
    foreach ($vmToResize in $targetVMs) {
        Resize-TargetVM -VM $vmToResize
    }

}
catch {
    Write-Error "A critical error occurred: $_"
}
finally {
    Write-Host "Script execution finished."
}
