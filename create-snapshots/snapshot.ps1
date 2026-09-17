<#
.SYNOPSIS
    Automates the creation of incremental snapshots for Azure VM disks.

.DESCRIPTION
    This script connects to an Azure subscription, iterates through a list of specified virtual machines,
    and creates incremental snapshots for both their OS and data disks. It includes a function to
    automatically match the SKU of the new snapshot to that of the most recent existing snapshot
    for cost and performance consistency. It handles errors gracefully and applies common tags.

.PARAMETER ResourceGroupName
    The name of the Azure resource group containing the virtual machines.

.PARAMETER VMNames
    An array of virtual machine names for which to create snapshots.

.PARAMETER SnapshotTags
    A hashtable of key-value pairs to apply as tags to all created snapshots, following Rax tagging standards.

.EXAMPLE
    .\snapshot.ps1 -ResourceGroupName "MyResourceGroup" -VMNames "VM-Web-01", "VM-App-02" -SnapshotTags @{"BuildBy" = "Automation"; "BuildDate" = "$(Get-Date -Format 'yyyy-MM-dd')"; "BuildTicket" = "INC12345"}

.NOTES
    Version: 1.0
    Author: Vatsal Singh
    Creation Date: 2024-07-25
    Last Modified: 2024-07-25
#>

#Requires -Modules Az.Accounts, Az.Compute

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The name of the resource group containing the VMs.")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, HelpMessage = "An array of virtual machine names to process.")]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMNames,

    [Parameter(Mandatory = $true, HelpMessage = "A hashtable of tags to apply to the new snapshots.")]
    [ValidateNotNullOrEmpty()]
    [hashtable]$SnapshotTags
)

# Set common preferences
$ErrorActionPreference = 'Stop'

# Function to get the most recent snapshot for a disk and return its SKU
function Get-LatestSnapshotSku {
    param(
        [string]$ResourceGroupName,
        [string]$DiskName
    )
    
    try {
        # Get all snapshots in the resource group that reference this disk
        $Snapshots = Get-AzSnapshot -ResourceGroupName $ResourceGroupName | Where-Object {
            $_.CreationData.SourceResourceId -eq $DiskName -or 
            $_.CreationData.SourceUri -like "*$DiskName*"
        }
        
        if ($Snapshots) {
            # Get the most recent snapshot
            $LatestSnapshot = $Snapshots | Sort-Object CreationTime -Descending | Select-Object -First 1
            Write-Host "Found existing snapshot '$($LatestSnapshot.Name)' with SKU: $($LatestSnapshot.Sku.Name)"
            return $LatestSnapshot.Sku.Name
        } else {
            Write-Host "No existing snapshots found for disk '$DiskName'. Using default SKU: Standard_LRS"
            return "Standard_LRS"
        }
    }
    catch {
        Write-Warning "Error checking existing snapshots for disk '$DiskName': $($_.Exception.Message)"
        Write-Host "Using default SKU: Standard_LRS"
        return "Standard_LRS"
    }
}

# Function to create snapshot with proper SKU matching
function New-SnapshotWithSkuMatching {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$DiskName,
        [string]$DiskId,
        [string]$Location,
        [hashtable]$Tags,
        [string]$SnapshotType # "OS" or "Data"
    )
    
    try {
        # Get the appropriate SKU for this disk
        $SkuName = Get-LatestSnapshotSku -ResourceGroupName $ResourceGroupName -DiskName $DiskName
        
        # Create snapshot configuration
        $SnapshotConfig = New-AzSnapshotConfig -SourceUri $DiskId -Location $Location -CreateOption Copy -Incremental -SkuName $SkuName -Tag $Tags
        
        # Generate snapshot name
        $SnapshotName = if ($SnapshotType -eq "OS") {
            "$VMName-OSDisk-Snapshot-$(Get-Date -Format 'yyyyMMdd')"
        } else {
            "$VMName-DataDisk-$SnapshotType-Snapshot-$(Get-Date -Format 'yyyyMMdd')"
        }
        
        # Create the snapshot
        $NewSnapshot = New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Snapshot $SnapshotConfig -Confirm:$false
        
        Write-Output "✓ Snapshot '$SnapshotName' created successfully with SKU: $SkuName"
        return $NewSnapshot
    }
    catch {
        Write-Error "Failed to create snapshot for disk '$DiskName': $($_.Exception.Message)"
        return $null
    }
}

# Main execution logic
try {
    # Validate Azure account connection
    Write-Output "Validating Azure account connection..."
    if (-not (Get-AzContext).Subscription) {
        throw "Not connected to an Azure account. Please run 'Connect-AzAccount' first."
    }

    foreach ($VMName in $VMNames) {
        Write-Output "`nProcessing VM: $VMName"
        Write-Output "=========================================="
        
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        
        if (-not $VM) {
            Write-Warning "VM '$VMName' not found in resource group '$ResourceGroupName'. Skipping..."
            continue
        }

        # Process OS Disk
        Write-Output "Processing OS Disk..."
        $OSDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $VM.StorageProfile.OsDisk.Name
        
        if ($OSDisk) {
            $OSSnapshot = New-SnapshotWithSkuMatching -ResourceGroupName $ResourceGroupName -VMName $VMName -DiskName $OSDisk.Name -DiskId $OSDisk.Id -Location $VM.Location -Tags $SnapshotTags -SnapshotType "OS"
            if (-not $OSSnapshot) {
                Write-Warning "Failed to create OS disk snapshot for $VMName"
            }
        } else {
            Write-Warning "OS disk not found for VM $VMName"
        }

        # Process Data Disks
        if ($VM.StorageProfile.DataDisks) {
            Write-Output "Processing Data Disks..."
            foreach ($DataDisk in $VM.StorageProfile.DataDisks) {
                $Disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DataDisk.Name
                
                if ($Disk) {
                    $DataSnapshot = New-SnapshotWithSkuMatching -ResourceGroupName $ResourceGroupName -VMName $VMName -DiskName $Disk.Name -DiskId $Disk.Id -Location $VM.Location -Tags $SnapshotTags -SnapshotType $DataDisk.Lun
                    if (-not $DataSnapshot) {
                        Write-Warning "Failed to create data disk snapshot for $VMName, disk $($DataDisk.Name)"
                    }
                } else {
                    Write-Warning "Data disk $($DataDisk.Name) not found for VM $VMName"
                }
            }
        } else {
            Write-Output "No data disks found for VM $VMName"
        }
    }
    
    Write-Output "`n=========================================="
    Write-Output "Snapshot creation process completed successfully!"
    Write-Output "=========================================="
    exit 0
}
catch {
    Write-Error "Script failed: $($_.Exception.Message)"
    exit 1
}