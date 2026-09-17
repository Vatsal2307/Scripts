
#Execute (the script will prompt for confirmation unless -Force is used)  .\New-VMFromSnapshots.ps1 -ConfigPath ".\vm-config.json"
<#
.SYNOPSIS
    Creates a new Azure VM from OS and Data disk snapshots with comprehensive error handling and idempotency.

.DESCRIPTION
    This script creates a new Azure Virtual Machine using snapshots of existing OS and Data disks.
    It implements best practices including idempotency, error handling, logging, and configuration management.

.PARAMETER ConfigPath
    Path to the JSON configuration file containing VM settings.

.PARAMETER ResourceGroupName
    Name of the resource group where the VM will be created.

.PARAMETER VMName
    Name of the new virtual machine.

.PARAMETER OSSnapshotName
    Name of the OS disk snapshot.

.PARAMETER DataSnapshotNames
    Array of data disk snapshot names.

.PARAMETER Location
    Azure region where resources will be created.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\New-VMFromSnapshots.ps1 -ConfigPath ".\vm-config.json" -Force

.EXAMPLE
    .\New-VMFromSnapshots.ps1 -ResourceGroupName "rg-prod" -VMName "vm-web01" -OSSnapshotName "snap-os-001" -Location "East US"
#>

[CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
param(
    [Parameter(ParameterSetName = 'ConfigFile', Mandatory = $true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$ConfigPath,
    
    [Parameter(ParameterSetName = 'Parameters', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,
    
    [Parameter(ParameterSetName = 'Parameters', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,
    
    [Parameter(ParameterSetName = 'Parameters', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OSSnapshotName,
    
    [Parameter(ParameterSetName = 'Parameters')]
    [string[]]$DataSnapshotNames = @(),
    
    [Parameter(ParameterSetName = 'Parameters', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,
    
    [Parameter()]
    [switch]$Force
)

# Configuration class for type safety and validation
class VMConfiguration {
    [string]$ResourceGroupName
    [string]$VMName
    [string]$Location
    [string]$OSSnapshotName
    [string[]]$DataSnapshotNames
    [string]$VMSize
    [string]$VNetName
    [string]$SubnetName
    [string]$NSGName
    [string]$NICName
    [string]$StorageAccountType
    [hashtable]$Tags
    [bool]$EnableBootDiagnostics
    [string]$BootDiagnosticsStorageAccount
    
    VMConfiguration() {
        $this.DataSnapshotNames = @()
        $this.VMSize = "Standard_B2s"
        $this.StorageAccountType = "Standard_LRS"
        $this.Tags = @{}
        $this.EnableBootDiagnostics = $true
    }
    
    [void] Validate() {
        if ([string]::IsNullOrWhiteSpace($this.ResourceGroupName)) {
            throw "ResourceGroupName is required"
        }
        if ([string]::IsNullOrWhiteSpace($this.VMName)) {
            throw "VMName is required"
        }
        if ([string]::IsNullOrWhiteSpace($this.Location)) {
            throw "Location is required"
        }
        if ([string]::IsNullOrWhiteSpace($this.OSSnapshotName)) {
            throw "OSSnapshotName is required"
        }
    }
}

# Logging configuration
$LogFile = "VM-Creation-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    switch ($Level) {
        'Info' { Write-Host $logEntry -ForegroundColor White }
        'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
        'Error' { Write-Host $logEntry -ForegroundColor Red }
        'Success' { Write-Host $logEntry -ForegroundColor Green }
    }
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logEntry
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "No Azure context found. Please run Connect-AzAccount first." -Level Error
            throw "Azure authentication required"
        }
        Write-Log "Connected to Azure subscription: $($context.Subscription.Name)" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to verify Azure connection: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-VMConfiguration {
    param(
        [string]$ConfigPath,
        [hashtable]$Parameters
    )
    
    try {
        $config = [VMConfiguration]::new()
        
        if ($ConfigPath) {
            Write-Log "Loading configuration from: $ConfigPath"
            $configData = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
            
            # Map JSON properties to configuration object
            $config.ResourceGroupName = $configData.ResourceGroupName
            $config.VMName = $configData.VMName
            $config.Location = $configData.Location
            $config.OSSnapshotName = $configData.OSSnapshotName
            $config.DataSnapshotNames = $configData.DataSnapshotNames ?? @()
            $config.VMSize = $configData.VMSize ?? "Standard_B2s"
            $config.VNetName = $configData.VNetName
            $config.SubnetName = $configData.SubnetName
            $config.NSGName = $configData.NSGName
            $config.NICName = $configData.NICName
            $config.StorageAccountType = $configData.StorageAccountType ?? "Standard_LRS"
            # Convert Tags to Hashtable if needed
            if ($null -ne $configData.Tags) {
                $config.Tags = @{}
                foreach ($key in $configData.Tags.PSObject.Properties.Name) {
                    $config.Tags[$key] = $configData.Tags.$key
                }
            } else {
                $config.Tags = @{}
            }
            $config.EnableBootDiagnostics = $configData.EnableBootDiagnostics ?? $true
            #$config.BootDiagnosticsStorageAccount = $configData.BootDiagnosticsStorageAccount
        }
        else {
            # Use parameters
            $config.ResourceGroupName = $Parameters.ResourceGroupName
            $config.VMName = $Parameters.VMName
            $config.Location = $Parameters.Location
            $config.OSSnapshotName = $Parameters.OSSnapshotName
            $config.DataSnapshotNames = $Parameters.DataSnapshotNames ?? @()
        }
        
        # Set default names if not provided
        if ([string]::IsNullOrWhiteSpace($config.VNetName)) {
            $config.VNetName = "$($config.VMName)-vnet"
        }
        if ([string]::IsNullOrWhiteSpace($config.SubnetName)) {
            $config.SubnetName = "$($config.VMName)-subnet"
        }
        if ([string]::IsNullOrWhiteSpace($config.NSGName)) {
            $config.NSGName = "$($config.VMName)-nsg"
        }
        if ([string]::IsNullOrWhiteSpace($config.NICName)) {
            $config.NICName = "$($config.VMName)-nic"
        }
        
        $config.Validate()
        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Test-ResourceExists {
    param(
        [string]$ResourceGroupName,
        [string]$ResourceName,
        [string]$ResourceType
    )
    
    try {
        switch ($ResourceType) {
            'VM' { 
                $resource = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction SilentlyContinue
            }
            'Snapshot' { 
                $resource = Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $ResourceName -ErrorAction SilentlyContinue
            }
            'ResourceGroup' {
                $resource = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
            }
            'VNet' {
                $resource = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction SilentlyContinue
            }
            #'PublicIP' {
                #$resource = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction SilentlyContinue
            #}
            'NSG' {
                $resource = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction SilentlyContinue
            }
            'NIC' {
                $resource = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction SilentlyContinue
            }
            default {
                throw "Unsupported resource type: $ResourceType"
            }
        }
        
        return $null -ne $resource
    }
    catch {
        Write-Log "Error checking if $ResourceType '$ResourceName' exists: $($_.Exception.Message)" -Level Warning
        return $false
    }
}

function New-ManagedDiskFromSnapshot {
    param(
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$SnapshotName,
        [string]$DiskName,
        [string]$StorageAccountType,
        [switch]$IsDataDisk
    )
    
    try {
        # Check if disk already exists (idempotency)
        $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -ErrorAction SilentlyContinue
        if ($existingDisk) {
            Write-Log "Disk '$DiskName' already exists. Skipping creation." -Level Warning
            return $existingDisk
        }
        
        Write-Log "Getting snapshot '$SnapshotName'..."
        $snapshot = Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -ErrorAction SilentlyContinue
        if (-not $snapshot) {
            if ($IsDataDisk) {
                Write-Log "Data disk snapshot '$SnapshotName' not found. Skipping data disk creation." -Level Warning
                return $null
            }
            else {
                throw "OS disk snapshot '$SnapshotName' not found in resource group '$ResourceGroupName'. OS disk is required."
            }
        }
        
        Write-Log "Creating managed disk '$DiskName' from snapshot..."
        $diskConfig = New-AzDiskConfig -Location $Location -SourceResourceId $snapshot.Id -CreateOption Copy -SkuName $StorageAccountType -OsType $snapshot.OsType
        $disk = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $diskConfig
        
        Write-Log "Successfully created disk '$DiskName'" -Level Success
        return $disk
    }
    catch {
        if ($IsDataDisk) {
            Write-Log "Failed to create data disk from snapshot '$SnapshotName': $($_.Exception.Message). Continuing without this data disk." -Level Warning
            return $null
        }
        else {
            Write-Log "Failed to create OS disk from snapshot '$SnapshotName': $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

function New-NetworkResources {
    param(
        [VMConfiguration]$Config
    )
    
    try {
        # Create or get Virtual Network
        if (-not (Test-ResourceExists -ResourceGroupName $Config.ResourceGroupName -ResourceName $Config.VNetName -ResourceType 'VNet')) {
            Write-Log "Creating Virtual Network '$($Config.VNetName)'..."
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $Config.SubnetName -AddressPrefix "10.0.1.0/24"
            $vnet = New-AzVirtualNetwork -ResourceGroupName $Config.ResourceGroupName -Location $Config.Location -Name $Config.VNetName -AddressPrefix "10.0.0.0/16" -Subnet $subnetConfig -Tag $Config.Tags
            Write-Log "Created Virtual Network '$($Config.VNetName)'" -Level Success
        }
        else {
            Write-Log "Virtual Network '$($Config.VNetName)' already exists"
            $vnet = Get-AzVirtualNetwork -ResourceGroupName $Config.ResourceGroupName -Name $Config.VNetName
        }
        
        # Create or get Network Security Group
        if (-not (Test-ResourceExists -ResourceGroupName $Config.ResourceGroupName -ResourceName $Config.NSGName -ResourceType 'NSG')) {
            Write-Log "Creating Network Security Group '$($Config.NSGName)'..."
            $rdpRule = New-AzNetworkSecurityRuleConfig -Name "RDP" -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $Config.ResourceGroupName -Location $Config.Location -Name $Config.NSGName -SecurityRules $rdpRule -Tag $Config.Tags
            Write-Log "Created Network Security Group '$($Config.NSGName)'" -Level Success
        }
        else {
            Write-Log "Network Security Group '$($Config.NSGName)' already exists"
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $Config.ResourceGroupName -Name $Config.NSGName
        }
        
        # Create or get Network Interface
        if (-not (Test-ResourceExists -ResourceGroupName $Config.ResourceGroupName -ResourceName $Config.NICName -ResourceType 'NIC')) {
            Write-Log "Creating Network Interface '$($Config.NICName)'..."
            $subnet = Get-AzVirtualNetworkSubnetConfig -Name $Config.SubnetName -VirtualNetwork $vnet
            $nic = New-AzNetworkInterface -ResourceGroupName $Config.ResourceGroupName -Location $Config.Location -Name $Config.NICName -SubnetId $subnet.Id -NetworkSecurityGroupId $nsg.Id -Tag $Config.Tags
            Write-Log "Created Network Interface '$($Config.NICName)'" -Level Success
        }
        else {
            Write-Log "Network Interface '$($Config.NICName)' already exists"
            $nic = Get-AzNetworkInterface -ResourceGroupName $Config.ResourceGroupName -Name $Config.NICName
        }
        
        return @{
            VNet = $vnet
            NSG = $nsg
            NIC = $nic
        }
    }
    catch {
        Write-Log "Failed to create network resources: $($_.Exception.Message)" -Level Error
        throw
    }
}

function New-VirtualMachine {
    param(
        [VMConfiguration]$Config,
        [object]$NetworkResources,
        [object]$OSDisk,
        [object[]]$DataDisks
    )
    
    try {
        # Check if VM already exists (idempotency)
        if (Test-ResourceExists -ResourceGroupName $Config.ResourceGroupName -ResourceName $Config.VMName -ResourceType 'VM') {
            Write-Log "Virtual Machine '$($Config.VMName)' already exists. Skipping creation." -Level Warning
            return Get-AzVM -ResourceGroupName $Config.ResourceGroupName -Name $Config.VMName
        }
        
        Write-Log "Creating Virtual Machine '$($Config.VMName)'..."
        
        # Create VM configuration
        $vmConfig = New-AzVMConfig -VMName $Config.VMName -VMSize $Config.VMSize -Tags $Config.Tags
        
        # Set OS disk
        if ($OSDisk.OsType -eq 'Linux') {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $OSDisk.Id -CreateOption Attach -Linux
        } else {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $OSDisk.Id -CreateOption Attach -Windows
        }
        
        # Add data disks if any were successfully created
        if ($DataDisks.Count -gt 0) {
            $lun = 0
            foreach ($dataDisk in $DataDisks) {
                Write-Log "Adding data disk '$($dataDisk.Name)' at LUN $lun"
                $vmConfig = Add-AzVMDataDisk -VM $vmConfig -ManagedDiskId $dataDisk.Id -CreateOption Attach -Lun $lun
                $lun++
            }
            Write-Log "Added $($DataDisks.Count) data disk(s) to VM configuration" -Level Success
        }
        else {
            Write-Log "No data disks to attach. VM will have OS disk only." -Level Info
        }
        
        # Add network interface
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $NetworkResources.NIC.Id
        
        # Configure boot diagnostics
        if ($Config.EnableBootDiagnostics) {
            if ([string]::IsNullOrWhiteSpace($Config.BootDiagnosticsStorageAccount)) {
                $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable
            }
            else {
                $storageAccount = Get-AzStorageAccount -ResourceGroupName $Config.ResourceGroupName -Name $Config.BootDiagnosticsStorageAccount -ErrorAction SilentlyContinue
                if ($storageAccount) {
                    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable -ResourceGroupName $Config.ResourceGroupName -StorageAccountName $Config.BootDiagnosticsStorageAccount
                }
                else {
                    Write-Log "Boot diagnostics storage account '$($Config.BootDiagnosticsStorageAccount)' not found. Using managed boot diagnostics." -Level Warning
                    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable
                }
            }
        }
        
        # Create the VM
        Write-Log "Creating VM - this may take several minutes..."
        $vm = New-AzVM -ResourceGroupName $Config.ResourceGroupName -Location $Config.Location -VM $vmConfig -DisableBginfoExtension
        
        Write-Log "Successfully created Virtual Machine '$($Config.VMName)'" -Level Success
        return $vm
    }
    catch {
        Write-Log "Failed to create Virtual Machine: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Show-VMSummary {
    param(
        [VMConfiguration]$Config,
        [object]$VM,
        [int]$DataDiskCount = 0
    )
    
    Write-Log "=== VM Creation Summary ===" -Level Success
    Write-Log "VM Name: $($Config.VMName)" -Level Info
    Write-Log "Resource Group: $($Config.ResourceGroupName)" -Level Info
    Write-Log "Location: $($Config.Location)" -Level Info
    Write-Log "VM Size: $($Config.VMSize)" -Level Info
    Write-Log "OS Disk: Created from snapshot '$($Config.OSSnapshotName)'" -Level Info
    
    if ($DataDiskCount -gt 0) {
        Write-Log "Data Disks: $DataDiskCount disk(s) attached" -Level Info
    }
    else {
        Write-Log "Data Disks: None (VM created with OS disk only)" -Level Info
    }
    
    Write-Log "VM ID: $($VM.Id)" -Level Info
    
    # Get public IP address
    #try {
        #$publicIP = Get-AzPublicIpAddress -ResourceGroupName $Config.ResourceGroupName -Name $Config.PublicIPName
        #if ($publicIP.IpAddress -and $publicIP.IpAddress -ne "Not Assigned") {
            #Write-Log "Public IP: $($publicIP.IpAddress)" -Level Info
        #}
        #else {
            #Write-Log "Public IP: Not yet assigned" -Level Info
        #}
   # }
    #catch {
        #Write-Log "Could not retrieve public IP information" -Level Warning
    #}
    
    Write-Log "Log file: $LogFile" -Level Info
    Write-Log "=== VM Creation Completed ===" -Level Success
}

# Main execution
try {
    Write-Log "Starting VM creation from snapshots..." -Level Info
    Write-Log "Log file: $LogFile" -Level Info
    
    # Test Azure connection
    Test-AzureConnection
    
    # Load configuration
    $paramHash = @{
        ResourceGroupName = $ResourceGroupName
        VMName = $VMName
        Location = $Location
        OSSnapshotName = $OSSnapshotName
        DataSnapshotNames = $DataSnapshotNames
    }
    
    $config = Get-VMConfiguration -ConfigPath $ConfigPath -Parameters $paramHash
    
    Write-Log "Configuration loaded successfully"
    Write-Log "Target VM: $($config.VMName) in $($config.ResourceGroupName)"
    
    # Verify resource group exists
    if (-not (Test-ResourceExists -ResourceGroupName $config.ResourceGroupName -ResourceType 'ResourceGroup')) {
        if ($Force -or (Read-Host "Resource group '$($config.ResourceGroupName)' does not exist. Create it? (y/N)") -eq 'y') {
            Write-Log "Creating resource group '$($config.ResourceGroupName)'..."
            New-AzResourceGroup -Name $config.ResourceGroupName -Location $config.Location -Tag $config.Tags
            Write-Log "Created resource group '$($config.ResourceGroupName)'" -Level Success
        }
        else {
            throw "Resource group '$($config.ResourceGroupName)' does not exist"
        }
    }
    
    # Confirm before proceeding
    if (-not $Force) {
        Write-Host "`nVM Configuration:" -ForegroundColor Cyan
        Write-Host "  Name: $($config.VMName)"
        Write-Host "  Resource Group: $($config.ResourceGroupName)"
        Write-Host "  Location: $($config.Location)"
        Write-Host "  OS Snapshot: $($config.OSSnapshotName)"
        Write-Host "  Data Snapshots: $($config.DataSnapshotNames -join ', ')"
        Write-Host "  VM Size: $($config.VMSize)"
        
        $confirm = Read-Host "`nProceed with VM creation? (y/N)"
        if ($confirm -ne 'y') {
            Write-Log "Operation cancelled by user" -Level Warning
            exit 0
        }
    }
    
    # Create OS disk from snapshot
    Write-Log "Creating OS disk from snapshot '$($config.OSSnapshotName)'..."
    $osDiskName = "$($config.VMName)-osdisk"
    $osDisk = New-ManagedDiskFromSnapshot -ResourceGroupName $config.ResourceGroupName -Location $config.Location -SnapshotName $config.OSSnapshotName -DiskName $osDiskName -StorageAccountType $config.StorageAccountType
    
    # Create data disks from snapshots (skip if snapshots don't exist)
    $dataDisks = @()
    $successfulDataDisks = 0
    
    if ($config.DataSnapshotNames.Count -gt 0) {
        Write-Log "Processing $($config.DataSnapshotNames.Count) data disk snapshot(s)..."
        
        for ($i = 0; $i -lt $config.DataSnapshotNames.Count; $i++) {
            $snapshotName = $config.DataSnapshotNames[$i]
            $diskName = "$($config.VMName)-datadisk-$($i + 1)"
            
            if (-not [string]::IsNullOrWhiteSpace($snapshotName)) {
                Write-Log "Creating data disk from snapshot '$snapshotName'..."
                $dataDisk = New-ManagedDiskFromSnapshot -ResourceGroupName $config.ResourceGroupName -Location $config.Location -SnapshotName $snapshotName -DiskName $diskName -StorageAccountType $config.StorageAccountType -IsDataDisk
                
                if ($dataDisk) {
                    $dataDisks += $dataDisk
                    $successfulDataDisks++
                }
            }
            else {
                Write-Log "Skipping empty data snapshot name at index $i" -Level Warning
            }
        }
        
        if ($successfulDataDisks -eq 0) {
            Write-Log "No data disk snapshots were found or could be processed. VM will be created with OS disk only." -Level Warning
        }
        else {
            Write-Log "Successfully processed $successfulDataDisks out of $($config.DataSnapshotNames.Count) data disk snapshots." -Level Success
        }
    }
    else {
        Write-Log "No data disk snapshots specified. VM will be created with OS disk only." -Level Info
    }
    
    # Create network resources
    Write-Log "Creating network resources..."
    $networkResources = New-NetworkResources -Config $config
    
    # Create the virtual machine
    $vm = New-VirtualMachine -Config $config -NetworkResources $networkResources -OSDisk $osDisk -DataDisks $dataDisks
    
    # Show summary
    Show-VMSummary -Config $config -VM $vm
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
finally {
    Write-Log "Script execution completed. Check log file: $LogFile"
}