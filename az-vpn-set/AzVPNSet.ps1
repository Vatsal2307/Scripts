# PowerShell script to deploy Site-to-Site VPN components in Azure
# Requires Azure PowerShell module (Az)

# =============================================================================
# CONFIGURATION SECTION - Modify these parameters for your deployment
# =============================================================================

# Basic Configuration
$SubscriptionId = "your-subscription-id"
$ResourceGroupName = "rg-vpn-s2s"
$Location = "East US"
$Tags = @{
    Environment = "Production"
    Project = "S2S-VPN"
    Owner = "NetworkTeam"
}

# Virtual Network Configuration
$VNetName = "vnet-hub-s2s"
$VNetAddressSpace = "10.0.0.0/16"
$GatewaySubnetPrefix = "10.0.0.0/24"      # Must be named 'GatewaySubnet'
$InternalSubnetName = "subnet-internal"
$InternalSubnetPrefix = "10.0.1.0/24"

# VPN Gateway Configuration
$VpnGatewayName = "vgw-s2s-primary"
$VpnGatewaySku = "VpnGw1"                 # Options: Basic, VpnGw1, VpnGw2, VpnGw3, VpnGw4, VpnGw5
$VpnType = "RouteBased"                   # Options: RouteBased, PolicyBased
$PublicIpName = "pip-vgw-s2s"

# Local Network Gateway Configuration (On-premises)
$LocalGatewayName = "lgw-onprem"
$OnPremPublicIP = "203.0.113.100"        # Your on-premises public IP
$OnPremAddressPrefix = @("192.168.0.0/16", "172.16.0.0/16")  # On-premises networks

# VPN Connection Configuration
$ConnectionName = "conn-s2s-onprem"
$SharedKey = "YourSecureSharedKey123!"    # Change this to your secure shared key
$ConnectionType = "IPsec"

# Network Security Group (Optional)
$CreateNSG = $true
$NSGName = "nsg-internal-subnet"

# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipGateway,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Function to write colored output
function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "Info"
    )
    
    $color = switch ($Status) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Info" { "Cyan" }
        "Progress" { "Magenta" }
        default { "White" }
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

# Function to handle errors gracefully
function Handle-Error {
    param(
        [string]$Operation,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    Write-Status "❌ Failed: $Operation" "Error"
    Write-Status "Error Details: $($ErrorRecord.Exception.Message)" "Error"
    
    if ($ErrorRecord.Exception.InnerException) {
        Write-Status "Inner Exception: $($ErrorRecord.Exception.InnerException.Message)" "Error"
    }
    
    return $false
}

# Function to create or get resource group
function New-ResourceGroupIfNotExists {
    param(
        [string]$ResourceGroupName,
        [string]$Location,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if resource group '$ResourceGroupName' exists..." "Progress"
        
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($rg) {
            Write-Status "✅ Resource group '$ResourceGroupName' already exists" "Success"
            return $rg
        } else {
            if ($WhatIf) {
                Write-Status "🔍 WHAT-IF: Would create resource group '$ResourceGroupName' in '$Location'" "Progress"
                return $true
            }
            
            Write-Status "📦 Creating resource group '$ResourceGroupName' in '$Location'..." "Progress"
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags
            Write-Status "✅ Resource group created successfully" "Success"
            return $rg
        }
    }
    catch {
        Handle-Error "Creating resource group '$ResourceGroupName'" $_
        return $false
    }
}

# Function to create virtual network
function New-VirtualNetwork {
    param(
        [string]$VNetName,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$AddressSpace,
        [string]$GatewaySubnetPrefix,
        [string]$InternalSubnetName,
        [string]$InternalSubnetPrefix,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if virtual network '$VNetName' exists..." "Progress"
        
        $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($vnet) {
            Write-Status "✅ Virtual network '$VNetName' already exists" "Success"
            return $vnet
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create virtual network '$VNetName' with address space '$AddressSpace'" "Progress"
            return $true
        }
        
        Write-Status "🌐 Creating virtual network '$VNetName'..." "Progress"
        
        # Create subnets
        Write-Status "📡 Creating Gateway subnet..." "Progress"
        $gatewaySubnet = New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -AddressPrefix $GatewaySubnetPrefix
        
        Write-Status "🏢 Creating internal subnet '$InternalSubnetName'..." "Progress"
        $internalSubnet = New-AzVirtualNetworkSubnetConfig -Name $InternalSubnetName -AddressPrefix $InternalSubnetPrefix
        
        # Create virtual network
        $vnet = New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $AddressSpace -Subnet $gatewaySubnet, $internalSubnet -Tag $Tags
        
        Write-Status "✅ Virtual network created successfully" "Success"
        return $vnet
    }
    catch {
        Handle-Error "Creating virtual network '$VNetName'" $_
        return $false
    }
}

# Function to create Network Security Group
function New-NetworkSecurityGroup {
    param(
        [string]$NSGName,
        [string]$ResourceGroupName,
        [string]$Location,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if NSG '$NSGName' exists..." "Progress"
        
        $nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($nsg) {
            Write-Status "✅ NSG '$NSGName' already exists" "Success"
            return $nsg
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create NSG '$NSGName'" "Progress"
            return $true
        }
        
        Write-Status "🛡️ Creating Network Security Group '$NSGName'..." "Progress"
        
        # Create some basic security rules
        $rule1 = New-AzNetworkSecurityRuleConfig -Name "Allow-RDP" -Description "Allow RDP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389
        $rule2 = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH" -Description "Allow SSH" -Access Allow -Protocol Tcp -Direction Inbound -Priority 1001 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
        $rule3 = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" -Description "Allow HTTP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 1002 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80
        $rule4 = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" -Description "Allow HTTPS" -Access Allow -Protocol Tcp -Direction Inbound -Priority 1003 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443
        
        $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $Location -Name $NSGName -SecurityRules $rule1, $rule2, $rule3, $rule4 -Tag $Tags
        
        Write-Status "✅ NSG created successfully" "Success"
        return $nsg
    }
    catch {
        Handle-Error "Creating NSG '$NSGName'" $_
        return $false
    }
}

# Function to create public IP for VPN Gateway
function New-PublicIPForGateway {
    param(
        [string]$PublicIpName,
        [string]$ResourceGroupName,
        [string]$Location,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if public IP '$PublicIpName' exists..." "Progress"
        
        $publicIp = Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($publicIp) {
            Write-Status "✅ Public IP '$PublicIpName' already exists" "Success"
            return $publicIp
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create public IP '$PublicIpName'" "Progress"
            return $true
        }
        
        Write-Status "🌍 Creating public IP '$PublicIpName'..." "Progress"
        
        $publicIp = New-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -Tag $Tags
        
        Write-Status "✅ Public IP created successfully: $($publicIp.IpAddress)" "Success"
        return $publicIp
    }
    catch {
        Handle-Error "Creating public IP '$PublicIpName'" $_
        return $false
    }
}

# Function to create VPN Gateway
function New-VpnGateway {
    param(
        [string]$VpnGatewayName,
        [string]$ResourceGroupName,
        [string]$Location,
        [object]$VNet,
        [object]$PublicIp,
        [string]$VpnGatewaySku,
        [string]$VpnType,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if VPN Gateway '$VpnGatewayName' exists..." "Progress"
        
        $vpnGw = Get-AzVirtualNetworkGateway -Name $VpnGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($vpnGw) {
            Write-Status "✅ VPN Gateway '$VpnGatewayName' already exists" "Success"
            return $vpnGw
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create VPN Gateway '$VpnGatewayName' with SKU '$VpnGatewaySku'" "Progress"
            Write-Status "⚠️  Note: VPN Gateway creation takes 20-45 minutes" "Warning"
            return $true
        }
        
        Write-Status "🚪 Creating VPN Gateway '$VpnGatewayName'..." "Progress"
        Write-Status "⏳ This will take 20-45 minutes. Please be patient..." "Warning"
        
        $gatewaySubnet = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $VNet
        $gwIpConfig = New-AzVirtualNetworkGatewayIpConfig -Name "gwIpConfig" -Subnet $gatewaySubnet -PublicIpAddress $PublicIp
        
        $vpnGw = New-AzVirtualNetworkGateway -Name $VpnGatewayName -ResourceGroupName $ResourceGroupName -Location $Location -IpConfigurations $gwIpConfig -GatewayType Vpn -VpnType $VpnType -GatewaySku $VpnGatewaySku -Tag $Tags
        
        Write-Status "✅ VPN Gateway created successfully" "Success"
        return $vpnGw
    }
    catch {
        Handle-Error "Creating VPN Gateway '$VpnGatewayName'" $_
        return $false
    }
}

# Function to create Local Network Gateway
function New-LocalNetworkGateway {
    param(
        [string]$LocalGatewayName,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$OnPremPublicIP,
        [string[]]$OnPremAddressPrefix,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if Local Network Gateway '$LocalGatewayName' exists..." "Progress"
        
        $localGw = Get-AzLocalNetworkGateway -Name $LocalGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($localGw) {
            Write-Status "✅ Local Network Gateway '$LocalGatewayName' already exists" "Success"
            return $localGw
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create Local Network Gateway '$LocalGatewayName' with IP '$OnPremPublicIP'" "Progress"
            return $true
        }
        
        Write-Status "🏠 Creating Local Network Gateway '$LocalGatewayName'..." "Progress"
        
        $localGw = New-AzLocalNetworkGateway -Name $LocalGatewayName -ResourceGroupName $ResourceGroupName -Location $Location -GatewayIpAddress $OnPremPublicIP -AddressPrefix $OnPremAddressPrefix -Tag $Tags
        
        Write-Status "✅ Local Network Gateway created successfully" "Success"
        return $localGw
    }
    catch {
        Handle-Error "Creating Local Network Gateway '$LocalGatewayName'" $_
        return $false
    }
}

# Function to create VPN Connection
function New-VpnConnection {
    param(
        [string]$ConnectionName,
        [string]$ResourceGroupName,
        [string]$Location,
        [object]$VpnGateway,
        [object]$LocalGateway,
        [string]$SharedKey,
        [string]$ConnectionType,
        [hashtable]$Tags
    )
    
    try {
        Write-Status "🔍 Checking if VPN Connection '$ConnectionName' exists..." "Progress"
        
        $connection = Get-AzVirtualNetworkGatewayConnection -Name $ConnectionName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($connection) {
            Write-Status "✅ VPN Connection '$ConnectionName' already exists" "Success"
            return $connection
        }
        
        if ($WhatIf) {
            Write-Status "🔍 WHAT-IF: Would create VPN Connection '$ConnectionName'" "Progress"
            return $true
        }
        
        Write-Status "🔗 Creating VPN Connection '$ConnectionName'..." "Progress"
        
        $connection = New-AzVirtualNetworkGatewayConnection -Name $ConnectionName -ResourceGroupName $ResourceGroupName -Location $Location -VirtualNetworkGateway1 $VpnGateway -LocalNetworkGateway2 $LocalGateway -ConnectionType $ConnectionType -SharedKey $SharedKey -Tag $Tags
        
        Write-Status "✅ VPN Connection created successfully" "Success"
        return $connection
    }
    catch {
        Handle-Error "Creating VPN Connection '$ConnectionName'" $_
        return $false
    }
}

# Main execution
Write-Status "🚀 Starting Azure Site-to-Site VPN deployment..." "Info"
Write-Status "📋 Configuration Summary:" "Info"
Write-Status "  • Resource Group: $ResourceGroupName" "Info"
Write-Status "  • Location: $Location" "Info"
Write-Status "  • VNet: $VNetName ($VNetAddressSpace)" "Info"
Write-Status "  • VPN Gateway: $VpnGatewayName ($VpnGatewaySku)" "Info"
Write-Status "  • On-premises IP: $OnPremPublicIP" "Info"

if ($WhatIf) {
    Write-Status "🔍 RUNNING IN WHAT-IF MODE - No resources will be created" "Warning"
}

try {
    # Set subscription context
    if ($SubscriptionId -ne "your-subscription-id") {
        Write-Status "🔧 Setting subscription context..." "Progress"
        Set-AzContext -SubscriptionId $SubscriptionId
    }

    $deploymentResults = @{
        ResourceGroup = $false
        VirtualNetwork = $false
        NetworkSecurityGroup = $false
        PublicIP = $false
        VpnGateway = $false
        LocalGateway = $false
        VpnConnection = $false
    }

    # Step 1: Create Resource Group
    Write-Status "`n=== STEP 1: Resource Group ===" "Info"
    $rg = New-ResourceGroupIfNotExists -ResourceGroupName $ResourceGroupName -Location $Location -Tags $Tags
    $deploymentResults.ResourceGroup = ($rg -ne $false)

    if (-not $deploymentResults.ResourceGroup) {
        throw "Failed to create or access resource group. Cannot continue."
    }

    # Step 2: Create Virtual Network
    Write-Status "`n=== STEP 2: Virtual Network ===" "Info"
    $vnet = New-VirtualNetwork -VNetName $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressSpace $VNetAddressSpace -GatewaySubnetPrefix $GatewaySubnetPrefix -InternalSubnetName $InternalSubnetName -InternalSubnetPrefix $InternalSubnetPrefix -Tags $Tags
    $deploymentResults.VirtualNetwork = ($vnet -ne $false)

    # Step 3: Create Network Security Group (Optional)
    if ($CreateNSG) {
        Write-Status "`n=== STEP 3: Network Security Group ===" "Info"
        $nsg = New-NetworkSecurityGroup -NSGName $NSGName -ResourceGroupName $ResourceGroupName -Location $Location -Tags $Tags
        $deploymentResults.NetworkSecurityGroup = ($nsg -ne $false)
        
        # Associate NSG with internal subnet
        if ($nsg -ne $false -and $vnet -ne $false -and -not $WhatIf) {
            try {
                Write-Status "🔗 Associating NSG with internal subnet..." "Progress"
                $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $InternalSubnetName
                $subnet.NetworkSecurityGroup = $nsg
                Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
                Write-Status "✅ NSG associated with subnet successfully" "Success"
            }
            catch {
                Write-Status "⚠️  Warning: Failed to associate NSG with subnet: $($_.Exception.Message)" "Warning"
            }
        }
    }

    # Step 4: Create Public IP for VPN Gateway
    Write-Status "`n=== STEP 4: Public IP for VPN Gateway ===" "Info"
    $publicIp = New-PublicIPForGateway -PublicIpName $PublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -Tags $Tags
    $deploymentResults.PublicIP = ($publicIp -ne $false)

    # Step 5: Create Local Network Gateway
    Write-Status "`n=== STEP 5: Local Network Gateway ===" "Info"
    $localGw = New-LocalNetworkGateway -LocalGatewayName $LocalGatewayName -ResourceGroupName $ResourceGroupName -Location $Location -OnPremPublicIP $OnPremPublicIP -OnPremAddressPrefix $OnPremAddressPrefix -Tags $Tags
    $deploymentResults.LocalGateway = ($localGw -ne $false)

    # Step 6: Create VPN Gateway (if not skipped)
    if (-not $SkipGateway) {
        Write-Status "`n=== STEP 6: VPN Gateway ===" "Info"
        $vpnGw = New-VpnGateway -VpnGatewayName $VpnGatewayName -ResourceGroupName $ResourceGroupName -Location $Location -VNet $vnet -PublicIp $publicIp -VpnGatewaySku $VpnGatewaySku -VpnType $VpnType -Tags $Tags
        $deploymentResults.VpnGateway = ($vpnGw -ne $false)

        # Step 7: Create VPN Connection
        if ($vpnGw -ne $false -and $localGw -ne $false) {
            Write-Status "`n=== STEP 7: VPN Connection ===" "Info"
            $connection = New-VpnConnection -ConnectionName $ConnectionName -ResourceGroupName $ResourceGroupName -Location $Location -VpnGateway $vpnGw -LocalGateway $localGw -SharedKey $SharedKey -ConnectionType $ConnectionType -Tags $Tags
            $deploymentResults.VpnConnection = ($connection -ne $false)
        }
    } else {
        Write-Status "`n=== STEP 6: VPN Gateway (SKIPPED) ===" "Warning"
        Write-Status "VPN Gateway creation skipped due to -SkipGateway parameter" "Warning"
    }

    # Final Summary
    Write-Status "`n=== DEPLOYMENT SUMMARY ===" "Info"
    foreach ($component in $deploymentResults.Keys) {
        $status = if ($deploymentResults[$component]) { "✅ SUCCESS" } else { "❌ FAILED" }
        $color = if ($deploymentResults[$component]) { "Green" } else { "Red" }
        Write-Host "  $component : $status" -ForegroundColor $color
    }

    # Next Steps
    if (-not $WhatIf) {
        Write-Status "`n=== NEXT STEPS ===" "Info"
        Write-Status "1. Configure your on-premises VPN device with the following settings:" "Info"
        Write-Status "   • Azure VPN Gateway Public IP: Check Azure portal" "Info"
        Write-Status "   • Shared Key: $SharedKey" "Info"
        Write-Status "   • Azure VNet Address Space: $VNetAddressSpace" "Info"
        Write-Status "2. Test the VPN connection from Azure portal" "Info"
        Write-Status "3. Deploy VMs in the internal subnet to test connectivity" "Info"
        Write-Status "4. Configure routing on your on-premises network if needed" "Info"
        
        if ($SkipGateway) {
            Write-Status "`n⚠️  Note: VPN Gateway was skipped. Run the script again without -SkipGateway to create it." "Warning"
        }
    }

    $successCount = ($deploymentResults.Values | Where-Object { $_ -eq $true }).Count
    $totalCount = $deploymentResults.Keys.Count
    
    Write-Status "`n🎉 Deployment completed: $successCount/$totalCount components successful" "Success"

}
catch {
    Write-Status "`n💥 DEPLOYMENT FAILED" "Error"
    Handle-Error "Site-to-Site VPN deployment" $_
}

# Usage examples and documentation
<#
.SYNOPSIS
    Deploys Azure Site-to-Site VPN infrastructure components.

.DESCRIPTION
    This script creates all necessary components for Azure Site-to-Site VPN:
    - Resource Group
    - Virtual Network with Gateway and Internal subnets
    - Network Security Group (optional)
    - Public IP for VPN Gateway
    - VPN Gateway
    - Local Network Gateway
    - VPN Connection

.PARAMETER WhatIf
    Shows what would be deployed without actually creating resources.

.PARAMETER SkipGateway
    Skips VPN Gateway creation (useful for testing other components first).

.PARAMETER Force
    Skips confirmation prompts.

.EXAMPLES
    # Deploy all components
    .\Deploy-S2S-VPN.ps1

    # Preview deployment
    .\Deploy-S2S-VPN.ps1 -WhatIf

    # Deploy everything except VPN Gateway
    .\Deploy-S2S-VPN.ps1 -SkipGateway

.NOTES
    - VPN Gateway creation takes 20-45 minutes
    - Modify the configuration section before running
    - Ensure you have appropriate Azure permissions
    - Test with -WhatIf first
#>