<#
.SYNOPSIS
    Lists all *.wav files across all storage accounts in a given Azure subscription.

.DESCRIPTION
    This script enumerates every blob container in every storage account within the specified
    subscription and lists all blobs with a .wav extension. It is strictly read-only and does
    NOT modify, delete, or create any resources in the Azure environment.

    The script handles:
      - Storage accounts with firewall restrictions (graceful skip with warning)
      - Containers with different access levels
      - Large containers with many blobs (streaming enumeration)

.PARAMETER SubscriptionId
    The Azure Subscription ID to search. If omitted, uses the current context subscription.

.PARAMETER ExportCsv
    If specified, exports results to a timestamped CSV file alongside the script.

.EXAMPLE
    .\Find-WavFiles.ps1 -SubscriptionId "aaaa-bbbb-cccc-dddd"

.EXAMPLE
    .\Find-WavFiles.ps1 -ExportCsv

.NOTES
    Prerequisites:
      - Az PowerShell module (Az.Storage, Az.Accounts)
      - Authenticated session (Connect-AzAccount)
      - Reader + Storage Blob Data Reader (or Storage Account Key access) on the subscription

    Safety:
      - This script performs ONLY read operations (Get-*, list)
      - No blobs, containers, or storage accounts are created, modified, or deleted
      - No access policies or configurations are changed
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false,
        HelpMessage = "Azure Subscription ID to search. Uses current context if omitted.")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false,
        HelpMessage = "Export results to a CSV file.")]
    [switch]$ExportCsv
)

#region --- Configuration ---
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
#endregion

#region --- Functions ---
function Write-Banner {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host " Azure Storage Account - WAV File Scanner" -ForegroundColor Cyan
    Write-Host " Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-AzureSession {
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context) { throw "No context" }
        Write-Host "Authenticated as: $($context.Account.Id)" -ForegroundColor Green
        return $context
    }
    catch {
        Write-Error "Not logged into Azure. Please run 'Connect-AzAccount' first."
        exit 1
    }
}
#endregion

#region --- Main Execution ---
Write-Banner
$context = Test-AzureSession

# Set subscription context if specified
if ($SubscriptionId) {
    Write-Host "Switching to subscription: $SubscriptionId"
    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    $context = Get-AzContext
}

$subscriptionName = $context.Subscription.Name
$subscriptionIdUsed = $context.Subscription.Id
Write-Host "Subscription: $subscriptionName ($subscriptionIdUsed)" -ForegroundColor Cyan
Write-Host ""

# Retrieve all storage accounts in the subscription
Write-Host "Enumerating storage accounts..."
try {
    $storageAccounts = Get-AzStorageAccount -ErrorAction Stop
}
catch {
    Write-Error "Failed to retrieve storage accounts: $($_.Exception.Message)"
    exit 1
}

$storageAccountsArray = @($storageAccounts)
if ($storageAccountsArray.Count -eq 0) {
    Write-Host "No storage accounts found in this subscription." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($storageAccountsArray.Count) storage account(s). Scanning for .wav files..."
Write-Host "--------------------------------------------------------"

# Results collection
$wavFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
$scannedAccounts = 0
$skippedAccounts = 0

foreach ($sa in $storageAccountsArray) {
    $saName = $sa.StorageAccountName
    $saRg = $sa.ResourceGroupName
    Write-Host ""
    Write-Host "Storage Account: $saName (RG: $saRg)" -ForegroundColor Cyan

    # Obtain storage context using account key (read-only operation)
    try {
        $saContext = (Get-AzStorageAccount -ResourceGroupName $saRg -Name $saName -ErrorAction Stop).Context
    }
    catch {
        Write-Host "  SKIPPED: Cannot access storage account. $($_.Exception.Message)" -ForegroundColor Yellow
        $skippedAccounts++
        continue
    }

    # List all containers
    try {
        $containers = Get-AzStorageContainer -Context $saContext -ErrorAction Stop
    }
    catch {
        Write-Host "  SKIPPED: Cannot list containers (possible firewall/network restriction)." -ForegroundColor Yellow
        Write-Host "  Detail: $($_.Exception.Message)" -ForegroundColor DarkGray
        $skippedAccounts++
        continue
    }

    $containersArray = @($containers)
    if ($containersArray.Count -eq 0) {
        Write-Host "  No containers found." -ForegroundColor DarkGray
        $scannedAccounts++
        continue
    }

    $accountWavCount = 0

    foreach ($container in $containersArray) {
        $containerName = $container.Name

        try {
            # Stream blobs to handle large containers; filter by .wav suffix
            $blobs = Get-AzStorageBlob -Container $containerName -Context $saContext -ErrorAction Stop |
                Where-Object { $_.Name -like '*.wav' }

            foreach ($blob in $blobs) {
                $accountWavCount++
                $wavFiles.Add([PSCustomObject]@{
                    StorageAccount = $saName
                    ResourceGroup  = $saRg
                    Container      = $containerName
                    BlobName       = $blob.Name
                    SizeBytes      = $blob.Length
                    SizeMB         = [math]::Round($blob.Length / 1MB, 2)
                    LastModified   = $blob.LastModified.ToString('yyyy-MM-dd HH:mm:ss')
                    ContentType    = $blob.ContentType
                })
            }
        }
        catch {
            Write-Host "  WARNING: Cannot read container '$containerName'. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($accountWavCount -gt 0) {
        Write-Host "  Found $accountWavCount .wav file(s)" -ForegroundColor White
    }
    else {
        Write-Host "  No .wav files found." -ForegroundColor DarkGray
    }

    $scannedAccounts++
}
#endregion

#region --- Summary ---
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Results Summary" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Storage accounts scanned:  $scannedAccounts" -ForegroundColor Green
Write-Host "  Storage accounts skipped:  $skippedAccounts" -ForegroundColor Yellow
Write-Host "  Total .wav files found:    $($wavFiles.Count)" -ForegroundColor White
Write-Host ""

if ($wavFiles.Count -gt 0) {
    $wavFiles | Format-Table -Property StorageAccount, Container, BlobName, SizeMB, LastModified -AutoSize
}
else {
    Write-Host "No .wav files found across all accessible storage accounts." -ForegroundColor DarkGray
}

# Export to CSV if requested
if ($ExportCsv -and $wavFiles.Count -gt 0) {
    $outputPath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
        -ChildPath "WavFiles_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $wavFiles | Export-Csv -Path $outputPath -NoTypeInformation
    Write-Host "Results exported to: $outputPath" -ForegroundColor Cyan
}
elseif ($ExportCsv -and $wavFiles.Count -eq 0) {
    Write-Host "No results to export." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
#endregion
