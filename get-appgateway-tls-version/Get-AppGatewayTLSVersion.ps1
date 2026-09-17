#Requires -Modules Az.Accounts, Az.Network
<#
.SYNOPSIS
    Checks and displays the minimum TLS version configuration for all Application Gateways in specified Azure subscriptions.

.DESCRIPTION
    This script connects to Azure and retrieves the minimum TLS version settings for all Application Gateways
    across one or more subscriptions. It supports multi-tenant scenarios and provides detailed output with
    error handling and logging capabilities.

.PARAMETER TenantId
    The Azure Active Directory Tenant ID. If not specified, uses the default tenant.

.PARAMETER SubscriptionId
    Array of Subscription IDs to check. If not specified, checks all accessible subscriptions.

.PARAMETER OutputPath
    Path to export results to CSV file. Optional.

.PARAMETER Detailed
    Switch to include additional details like resource group, location, and SKU information.

.PARAMETER LogPath
    Path for log file. If not specified, logs to console only.

.EXAMPLE
    .\Get-AppGatewayTLSVersion.ps1
    Checks all Application Gateways in all accessible subscriptions using default tenant.

.EXAMPLE
    .\Get-AppGatewayTLSVersion.ps1 -TenantId "12345678-1234-1234-1234-123456789012" -SubscriptionId @("sub1", "sub2")
    Checks Application Gateways in specific subscriptions within a specific tenant.

.EXAMPLE
    .\Get-AppGatewayTLSVersion.ps1 -Detailed -OutputPath "C:\Reports\TLS-Report.csv" -LogPath "C:\Logs\TLS-Check.log"
    Performs detailed check with CSV export and file logging.

.NOTES
    Author: Azure PowerShell Expert
    Version: 1.0
    Requires: Az.Accounts and Az.Network PowerShell modules
    Permissions: Reader role on subscriptions or Application Gateway Contributor role
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        $parentPath = Split-Path $_ -Parent
        if ($parentPath -and !(Test-Path $parentPath)) {
            throw "Directory '$parentPath' does not exist"
        }
        $true
    })]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$Detailed,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        $parentPath = Split-Path $_ -Parent
        if ($parentPath -and !(Test-Path $parentPath)) {
            throw "Directory '$parentPath' does not exist"
        }
        $true
    })]
    [string]$LogPath
)

# Initialize logging function
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'ERROR' { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'DEBUG' { Write-Host $logMessage -ForegroundColor Gray }
        default { Write-Host $logMessage -ForegroundColor White }
    }
    
    # File output if LogPath is specified
    if ($LogPath) {
        try {
            $logMessage | Out-File -FilePath $LogPath -Append -Encoding UTF8
        }
        catch {
            Write-Warning "Failed to write to log file: $_"
        }
    }
}

# Function to check required modules
function Test-RequiredModules {
    $requiredModules = @('Az.Accounts', 'Az.Network')
    $missingModules = @()
    
    foreach ($module in $requiredModules) {
        if (!(Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-Log "Missing required modules: $($missingModules -join ', ')" -Level ERROR
        Write-Log "Install missing modules using: Install-Module $($missingModules -join ', ') -Scope CurrentUser" -Level INFO
        throw "Required modules are missing"
    }
    
    Write-Log "All required modules are available" -Level INFO
}

# Function to connect to Azure
function Connect-ToAzure {
    param([string]$TenantId)
    
    try {
        $context = Get-AzContext
        if ($null -eq $context) {
            Write-Log "No Azure context found. Initiating login..." -Level INFO
            if ($TenantId) {
                Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
            } else {
                Connect-AzAccount -ErrorAction Stop | Out-Null
            }
        } else {
            Write-Log "Using existing Azure context: $($context.Account.Id)" -Level INFO
            if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
                Write-Log "Switching to specified tenant: $TenantId" -Level INFO
                Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
            }
        }
        
        $currentContext = Get-AzContext
        Write-Log "Connected to Azure - Tenant: $($currentContext.Tenant.Id), Account: $($currentContext.Account.Id)" -Level INFO
        return $true
    }
    catch {
        Write-Log "Failed to connect to Azure: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# Function to get accessible subscriptions
function Get-AccessibleSubscriptions {
    param([string[]]$SpecificSubscriptions)
    
    try {
        if ($SpecificSubscriptions) {
            $subscriptions = @()
            foreach ($subId in $SpecificSubscriptions) {
                try {
                    $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                    $subscriptions += $sub
                    Write-Log "Found subscription: $($sub.Name) ($($sub.Id))" -Level INFO
                }
                catch {
                    Write-Log "Cannot access subscription $subId : $($_.Exception.Message)" -Level WARNING
                }
            }
        } else {
            $subscriptions = Get-AzSubscription
            Write-Log "Found $($subscriptions.Count) accessible subscriptions" -Level INFO
        }
        
        return $subscriptions
    }
    catch {
        Write-Log "Failed to retrieve subscriptions: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# Function to get Application Gateway TLS configuration
function Get-AppGatewayTLSConfig {
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [bool]$IncludeDetails
    )
    
    $results = @()
    
    try {
        # Set subscription context
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        Write-Log "Processing subscription: $SubscriptionName ($SubscriptionId)" -Level INFO
        
        # Get all Application Gateways
        $appGateways = Get-AzApplicationGateway -ErrorAction Continue
        
        if ($appGateways.Count -eq 0) {
            Write-Log "No Application Gateways found in subscription $SubscriptionName" -Level INFO
            return $results
        }
        
        Write-Log "Found $($appGateways.Count) Application Gateway(s) in $SubscriptionName" -Level INFO
        
        foreach ($appGw in $appGateways) {
            try {
                Write-Log "Processing Application Gateway: $($appGw.Name)" -Level DEBUG
                
                # Get SSL Policy and determine actual TLS version
                $sslPolicy = $appGw.SslPolicy
                $minTlsVersion = "Unknown"
                $policyType = "Not Configured"
                $policyName = "Not Configured"
                $tlsVersionDisplay = "Unknown"
                
                if ($sslPolicy) {
                    $policyType = if ($sslPolicy.PolicyType) { $sslPolicy.PolicyType } else { "Default" }
                    $policyName = if ($sslPolicy.PolicyName) { $sslPolicy.PolicyName } else { "Custom/Default" }
                    
                    # Determine the actual minimum TLS version
                    if ($sslPolicy.MinProtocolVersion) {
                        $minTlsVersion = $sslPolicy.MinProtocolVersion
                        # Convert to readable format
                        switch ($sslPolicy.MinProtocolVersion) {
                            "TLSv1_0" { $tlsVersionDisplay = "TLS 1.0" }
                            "TLSv1_1" { $tlsVersionDisplay = "TLS 1.1" }
                            "TLSv1_2" { $tlsVersionDisplay = "TLS 1.2" }
                            "TLSv1_3" { $tlsVersionDisplay = "TLS 1.3" }
                            default { $tlsVersionDisplay = $sslPolicy.MinProtocolVersion }
                        }
                    } else {
                        # If no explicit MinProtocolVersion is set, check policy name for predefined policies
                        if ($sslPolicy.PolicyName) {
                            switch ($sslPolicy.PolicyName) {
                                "AppGwSslPolicy20150501" { 
                                    $minTlsVersion = "TLSv1_0"
                                    $tlsVersionDisplay = "TLS 1.0 (Legacy Policy)"
                                }
                                "AppGwSslPolicy20170401" { 
                                    $minTlsVersion = "TLSv1_1"
                                    $tlsVersionDisplay = "TLS 1.1 (Legacy Policy)"
                                }
                                "AppGwSslPolicy20170401S" { 
                                    $minTlsVersion = "TLSv1_2"
                                    $tlsVersionDisplay = "TLS 1.2 (Secure Policy)"
                                }
                                "AppGwSslPolicy20220101" { 
                                    $minTlsVersion = "TLSv1_2"
                                    $tlsVersionDisplay = "TLS 1.2 (Current Policy)"
                                }
                                "AppGwSslPolicy20220101S" { 
                                    $minTlsVersion = "TLSv1_2"
                                    $tlsVersionDisplay = "TLS 1.2 (Secure Policy)"
                                }
                                default { 
                                    $minTlsVersion = "Custom Policy"
                                    $tlsVersionDisplay = "Custom Policy - Check Manually"
                                }
                            }
                        } else {
                            # Default Azure behavior - typically TLS 1.0 for older gateways, TLS 1.2 for newer ones
                            $minTlsVersion = "Default (Azure Managed)"
                            $tlsVersionDisplay = "Default (Likely TLS 1.0 - Verify Manually)"
                        }
                    }
                } else {
                    # No SSL policy configured - uses Azure defaults
                    $minTlsVersion = "Not Configured"
                    $tlsVersionDisplay = "Not Configured (Azure Default - Likely TLS 1.0)"
                    $policyType = "Not Configured"
                    $policyName = "Not Configured"
                }
                
                # Create result object
                $result = [PSCustomObject]@{
                    SubscriptionName = $SubscriptionName
                    SubscriptionId = $SubscriptionId
                    ApplicationGatewayName = $appGw.Name
                    MinimumTLSVersion = $tlsVersionDisplay
                    TLSVersionRaw = $minTlsVersion
                    SSLPolicyType = $policyType
                    SSLPolicyName = $policyName
                    ProvisioningState = $appGw.ProvisioningState
                    SecurityStatus = switch -Regex ($tlsVersionDisplay) {
                        "TLS 1\.[0-1]|Default.*TLS 1\.0|Not Configured.*TLS 1\.0" { "⚠️ INSECURE" }
                        "TLS 1\.2" { "✅ SECURE" }
                        "TLS 1\.3" { "🔒 HIGHLY SECURE" }
                        "Custom Policy|Unknown" { "❓ REQUIRES MANUAL REVIEW" }
                        default { "❓ UNKNOWN" }
                    }
                }
                
                # Add detailed information if requested
                if ($IncludeDetails) {
                    $result | Add-Member -NotePropertyName ResourceGroupName -NotePropertyValue $appGw.ResourceGroupName
                    $result | Add-Member -NotePropertyName Location -NotePropertyValue $appGw.Location
                    $result | Add-Member -NotePropertyName SKUName -NotePropertyValue $appGw.Sku.Name
                    $result | Add-Member -NotePropertyName SKUTier -NotePropertyValue $appGw.Sku.Tier
                    $result | Add-Member -NotePropertyName SKUCapacity -NotePropertyValue $appGw.Sku.Capacity
                    $result | Add-Member -NotePropertyName BackendPoolCount -NotePropertyValue $appGw.BackendAddressPools.Count
                    $result | Add-Member -NotePropertyName ListenerCount -NotePropertyValue $appGw.HttpListeners.Count
                    $result | Add-Member -NotePropertyName RuleCount -NotePropertyValue $appGw.RequestRoutingRules.Count
                    
                    # Add SSL policy details for troubleshooting
                    if ($sslPolicy) {
                        $cipherSuites = if ($sslPolicy.CipherSuites) { $sslPolicy.CipherSuites -join ", " } else { "Default" }
                        $result | Add-Member -NotePropertyName CipherSuites -NotePropertyValue $cipherSuites
                        $result | Add-Member -NotePropertyName DisabledSslProtocols -NotePropertyValue ($sslPolicy.DisabledSslProtocols -join ", ")
                    }
                }
                
                $results += $result
                Write-Log "Processed: $($appGw.Name) - TLS: $tlsVersionDisplay" -Level DEBUG
            }
            catch {
                Write-Log "Error processing Application Gateway $($appGw.Name): $($_.Exception.Message)" -Level ERROR
                
                # Add error result
                $errorResult = [PSCustomObject]@{
                    SubscriptionName = $SubscriptionName
                    SubscriptionId = $SubscriptionId
                    ApplicationGatewayName = $appGw.Name
                    MinimumTLSVersion = "❌ ERROR"
                    TLSVersionRaw = "ERROR"
                    SSLPolicyType = "ERROR"
                    SSLPolicyName = $_.Exception.Message
                    ProvisioningState = "ERROR"
                    SecurityStatus = "❌ ERROR"
                }
                $results += $errorResult
            }
        }
    }
    catch {
        Write-Log "Error processing subscription $SubscriptionName : $($_.Exception.Message)" -Level ERROR
    }
    
    return $results
}

# Main execution block
try {
    Write-Log "Starting Azure Application Gateway TLS Version Check" -Level INFO
    Write-Log "Script Parameters: TenantId=$TenantId, SubscriptionCount=$($SubscriptionId.Count), Detailed=$Detailed" -Level DEBUG
    
    # Check required modules
    Test-RequiredModules
    
    # Connect to Azure
    if (!(Connect-ToAzure -TenantId $TenantId)) {
        throw "Failed to connect to Azure"
    }
    
    # Get subscriptions to process
    $subscriptions = Get-AccessibleSubscriptions -SpecificSubscriptions $SubscriptionId
    
    if ($subscriptions.Count -eq 0) {
        Write-Log "No accessible subscriptions found" -Level WARNING
        return
    }
    
    # Initialize results array
    $allResults = @()
    
    # Process each subscription
    foreach ($subscription in $subscriptions) {
        $subResults = Get-AppGatewayTLSConfig -SubscriptionId $subscription.Id -SubscriptionName $subscription.Name -IncludeDetails $Detailed
        $allResults += $subResults
    }
    
    # Display results
    if ($allResults.Count -eq 0) {
        Write-Log "No Application Gateways found in any subscription" -Level INFO
    } else {
        Write-Log "Found $($allResults.Count) Application Gateway(s) across $($subscriptions.Count) subscription(s)" -Level INFO
        Write-Log "`nResults Summary:" -Level INFO
        
        # Display formatted results
        $allResults | Format-Table -AutoSize
        
        # Show TLS version summary with security status
        $tlsSummary = $allResults | Where-Object { $_.MinimumTLSVersion -notlike "*ERROR*" } | 
                     Group-Object MinimumTLSVersion | 
                     Sort-Object Name
        
        Write-Log "`nTLS Version Summary:" -Level INFO
        foreach ($group in $tlsSummary) {
            Write-Log "  $($group.Name): $($group.Count) Application Gateway(s)" -Level INFO
        }
        
        # Security status summary
        $securitySummary = $allResults | Where-Object { $_.SecurityStatus -notlike "*ERROR*" } | 
                          Group-Object SecurityStatus | 
                          Sort-Object Name
        
        Write-Log "`nSecurity Status Summary:" -Level INFO
        foreach ($group in $securitySummary) {
            $level = if ($group.Name -like "*INSECURE*") { "WARNING" } else { "INFO" }
            Write-Log "  $($group.Name): $($group.Count) Application Gateway(s)" -Level $level
        }
        
        # Export to CSV if requested
        if ($OutputPath) {
            try {
                $allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
                Write-Log "Results exported to: $OutputPath" -Level INFO
            }
            catch {
                Write-Log "Failed to export results: $($_.Exception.Message)" -Level ERROR
            }
        }
        
        # Security recommendations with detailed TLS version analysis
        $insecureGateways = $allResults | Where-Object { 
            $_.TLSVersionRaw -in @("TLSv1_0", "TLSv1_1") -or 
            $_.MinimumTLSVersion -like "*TLS 1.0*" -or 
            $_.MinimumTLSVersion -like "*TLS 1.1*" -or
            $_.MinimumTLSVersion -like "*Not Configured*" -or
            $_.MinimumTLSVersion -like "*Default*TLS 1.0*"
        }
        
        $reviewRequired = $allResults | Where-Object { 
            $_.SecurityStatus -like "*REQUIRES MANUAL REVIEW*" -or 
            $_.SecurityStatus -like "*UNKNOWN*"
        }
        
        if ($insecureGateways.Count -gt 0) {
            Write-Log "`n🚨 CRITICAL SECURITY ALERT:" -Level ERROR
            Write-Log "The following Application Gateways are using INSECURE TLS versions:" -Level ERROR
            $insecureGateways | Select-Object SubscriptionName, ApplicationGatewayName, MinimumTLSVersion, SecurityStatus | Format-Table -AutoSize
            Write-Log "ACTION REQUIRED: Update these gateways to use TLS 1.2 or TLS 1.3 immediately!" -Level ERROR
        }
        
        if ($reviewRequired.Count -gt 0) {
            Write-Log "`n⚠️ MANUAL REVIEW REQUIRED:" -Level WARNING
            Write-Log "The following Application Gateways require manual verification:" -Level WARNING
            $reviewRequired | Select-Object SubscriptionName, ApplicationGatewayName, MinimumTLSVersion, SecurityStatus | Format-Table -AutoSize
            Write-Log "Please manually verify the TLS configuration for these gateways." -Level WARNING
        }
        
        $secureGateways = $allResults | Where-Object { 
            $_.SecurityStatus -like "*SECURE*"
        }
        
        if ($secureGateways.Count -gt 0) {
            Write-Log "`n✅ SECURE GATEWAYS:" -Level INFO
            Write-Log "$($secureGateways.Count) Application Gateway(s) are properly configured with secure TLS versions." -Level INFO
        }
    }
    
    Write-Log "Script execution completed successfully" -Level INFO
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level DEBUG
    exit 1
}
finally {
    Write-Log "Script finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
}