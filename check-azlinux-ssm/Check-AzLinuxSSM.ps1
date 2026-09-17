<#
.SYNOPSIS
    Checks whether the Amazon SSM Agent is installed on Linux Azure VMs across multiple subscriptions.

.DESCRIPTION
    This script accepts a list of VMs (via CSV file or inline array) spanning multiple Azure subscriptions.
    It uses the Azure VM Run Command feature to remotely verify whether the amazon-ssm-agent service
    or package is present on each Linux VM. It only reads status — it does not modify the system.

    The CSV file must contain the following columns:
        SubscriptionId, ResourceGroupName, VMName

.PARAMETER CsvPath
    Path to a CSV file containing the VM list. Columns: SubscriptionId, ResourceGroupName, VMName.

.PARAMETER VmList
    An array of hashtables as an alternative to CSV. Each entry must have keys:
    SubscriptionId, ResourceGroupName, VMName.

.EXAMPLE
    .\Check-AzLinuxSSM.ps1 -CsvPath ".\vm-list.csv"

.EXAMPLE
    $vms = @(
        @{ SubscriptionId = "aaaa-bbbb-cccc"; ResourceGroupName = "rg-prod"; VMName = "linux-vm-01" },
        @{ SubscriptionId = "dddd-eeee-ffff"; ResourceGroupName = "rg-dev";  VMName = "linux-vm-02" }
    )
    .\Check-AzLinuxSSM.ps1 -VmList $vms

.NOTES
    Prerequisites:
      - Azure PowerShell module (Az) installed
      - Authenticated session (Connect-AzAccount)
      - Reader + VM Run Command permissions on target subscriptions
#>

[CmdletBinding(DefaultParameterSetName = 'CsvInput')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'CsvInput',
        HelpMessage = "Path to CSV file with columns: SubscriptionId, ResourceGroupName, VMName")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'InlineInput',
        HelpMessage = "Array of hashtables with keys: SubscriptionId, ResourceGroupName, VMName")]
    [hashtable[]]$VmList
)

#region --- Configuration ---
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# The shell script executed on each Linux VM (read-only, no modifications)
$CheckScript = @'
#!/bin/bash
echo "=== SSM Agent Status Check ==="
echo "Hostname: $(hostname)"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

SSM_FOUND="false"

# Check systemd service
if systemctl list-units --type=service --all 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    STATUS=$(systemctl is-active amazon-ssm-agent 2>/dev/null || echo "inactive")
    ENABLED=$(systemctl is-enabled amazon-ssm-agent 2>/dev/null || echo "unknown")
    echo "SERVICE: amazon-ssm-agent found"
    echo "  Active: $STATUS"
    echo "  Enabled: $ENABLED"
    SSM_FOUND="true"
fi

# Check snap package
if command -v snap &>/dev/null && snap list 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    VERSION=$(snap list 2>/dev/null | grep 'amazon-ssm-agent' | awk '{print $2}')
    echo "SNAP PACKAGE: amazon-ssm-agent installed (Version: $VERSION)"
    SSM_FOUND="true"
fi

# Check deb package
if dpkg -l 2>/dev/null | grep -qi 'amazon-ssm-agent'; then
    VERSION=$(dpkg -l | grep -i 'amazon-ssm-agent' | awk '{print $3}')
    echo "DEB PACKAGE: amazon-ssm-agent installed (Version: $VERSION)"
    SSM_FOUND="true"
fi

# Check rpm package
if rpm -qa 2>/dev/null | grep -qi 'amazon-ssm-agent'; then
    PACKAGE=$(rpm -qa | grep -i 'amazon-ssm-agent')
    echo "RPM PACKAGE: $PACKAGE installed"
    SSM_FOUND="true"
fi

# Check binary existence
if [[ -f /usr/bin/amazon-ssm-agent ]]; then
    echo "BINARY: /usr/bin/amazon-ssm-agent exists"
    SSM_FOUND="true"
fi

echo ""
if [[ "$SSM_FOUND" == "true" ]]; then
    echo "RESULT: SSM_AGENT_PRESENT"
else
    echo "RESULT: SSM_AGENT_NOT_FOUND"
fi
'@
#endregion

#region --- Functions ---
function Write-Banner {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host " Azure Linux VM - Amazon SSM Agent Status Checker" -ForegroundColor Cyan
    Write-Host " Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-AzureSession {
    try {
        $null = Get-AzContext -ErrorAction Stop
    }
    catch {
        Write-Error "Not logged into Azure. Please run 'Connect-AzAccount' first."
        exit 1
    }
}

function Set-SubscriptionContext {
    param ([string]$SubscriptionId)

    $currentContext = Get-AzContext
    if ($currentContext.Subscription.Id -ne $SubscriptionId) {
        Write-Host "  Switching to subscription: $SubscriptionId" -ForegroundColor DarkGray
        $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
}

function Invoke-SSMCheck {
    param (
        [string]$ResourceGroupName,
        [string]$VMName
    )

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId 'RunShellScript' `
        -ScriptString $CheckScript `
        -ErrorAction Stop

    return $result.Value[0].Message
}
#endregion

#region --- Main Execution ---
Write-Banner
Test-AzureSession

# Build the target VM list from the chosen input method
if ($PSCmdlet.ParameterSetName -eq 'CsvInput') {
    Write-Host "Loading VM list from: $CsvPath"
    $targets = Import-Csv -Path $CsvPath

    # Validate CSV columns
    $requiredColumns = @('SubscriptionId', 'ResourceGroupName', 'VMName')
    $csvColumns = $targets[0].PSObject.Properties.Name
    foreach ($col in $requiredColumns) {
        if ($col -notin $csvColumns) {
            Write-Error "CSV is missing required column: '$col'. Expected columns: $($requiredColumns -join ', ')"
            exit 1
        }
    }
}
else {
    # Convert hashtable array to PSCustomObject array for uniform handling
    $targets = $VmList | ForEach-Object { [PSCustomObject]$_ }
}

$totalVMs = @($targets).Count
Write-Host "Total VMs to check: $totalVMs"
Write-Host "--------------------------------------------------------"

# Results collection
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$vmIndex = 0
foreach ($vm in $targets) {
    $vmIndex++
    $subscriptionId   = $vm.SubscriptionId.Trim()
    $resourceGroup    = $vm.ResourceGroupName.Trim()
    $vmName           = $vm.VMName.Trim()

    Write-Host ""
    Write-Host "[$vmIndex/$totalVMs] VM: $vmName | RG: $resourceGroup | Sub: $subscriptionId" -ForegroundColor Cyan

    $status = 'Error'
    $detail = ''

    try {
        Set-SubscriptionContext -SubscriptionId $subscriptionId

        $output = Invoke-SSMCheck -ResourceGroupName $resourceGroup -VMName $vmName
        $detail = $output

        if ($output -match 'SSM_AGENT_PRESENT') {
            $status = 'Present'
            Write-Host "  Result: SSM Agent PRESENT" -ForegroundColor Yellow
        }
        elseif ($output -match 'SSM_AGENT_NOT_FOUND') {
            $status = 'Not Found'
            Write-Host "  Result: SSM Agent NOT FOUND" -ForegroundColor Green
        }
        else {
            $status = 'Unknown'
            Write-Host "  Result: Could not determine status" -ForegroundColor DarkYellow
        }
    }
    catch {
        $detail = $_.Exception.Message
        Write-Host "  ERROR: $detail" -ForegroundColor Red
        Write-Host "  Tip: Ensure the VM is running and the Azure VM Agent is healthy." -ForegroundColor Yellow
    }

    $results.Add([PSCustomObject]@{
        VMName            = $vmName
        ResourceGroup     = $resourceGroup
        SubscriptionId    = $subscriptionId
        SSMAgentStatus    = $status
        Detail            = $detail
    })
}
#endregion

#region --- Summary ---
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$results | Format-Table -Property VMName, ResourceGroup, SSMAgentStatus -AutoSize

$presentCount  = ($results | Where-Object { $_.SSMAgentStatus -eq 'Present' }).Count
$notFoundCount = ($results | Where-Object { $_.SSMAgentStatus -eq 'Not Found' }).Count
$errorCount    = ($results | Where-Object { $_.SSMAgentStatus -eq 'Error' }).Count

Write-Host "  Present:   $presentCount" -ForegroundColor Yellow
Write-Host "  Not Found: $notFoundCount" -ForegroundColor Green
Write-Host "  Errors:    $errorCount" -ForegroundColor Red
Write-Host ""

# Export results to CSV alongside the script
$outputPath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath "SSMCheckResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Select-Object VMName, ResourceGroup, SubscriptionId, SSMAgentStatus | Export-Csv -Path $outputPath -NoTypeInformation
Write-Host "Results exported to: $outputPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "Completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
#endregion
