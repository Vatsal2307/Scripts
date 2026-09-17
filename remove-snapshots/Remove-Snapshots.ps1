<#
.SYNOPSIS
    Cleans up (deletes) Azure VM disk snapshots created by snapshot.ps1.

.DESCRIPTION
    This script connects to an Azure subscription and removes disk snapshots in a specified
    resource group. It is designed to complement snapshot.ps1 by targeting snapshots that follow
    the naming convention produced by that script ("{VMName}-OSDisk-Snapshot-{yyyyMMdd}" and
    "{VMName}-DataDisk-{Lun}-Snapshot-{yyyyMMdd}").

    Snapshots can be filtered by any combination of:
      - Resource group (required)
      - VM names (matches the "{VMName}-" prefix of the snapshot name)
      - A custom name pattern (wildcard)
      - Tags (key/value pairs that must all match, e.g. the Rax tags applied at creation)
      - Retention age (delete snapshots older than a given number of days)

    The script supports -WhatIf / -Confirm via SupportsShouldProcess and prints a summary of what
    was (or would be) deleted.

.PARAMETER ResourceGroupName
    The name of the Azure resource group containing the snapshots.

.PARAMETER VMNames
    Optional array of VM names. Only snapshots whose name begins with "{VMName}-" are considered.
    If omitted, all snapshots in the resource group (subject to other filters) are considered.

.PARAMETER NamePattern
    Optional wildcard pattern to match snapshot names. When omitted, ALL snapshots in the resource
    group are considered (equivalent to "*"). To restrict to the snapshot.ps1 naming convention,
    pass -NamePattern "*-Snapshot-*".

.PARAMETER Tags
    Optional hashtable of tag key/value pairs. A snapshot must have ALL of these tags (matching
    both key and value) to be considered for deletion. Useful for targeting snapshots created by a
    specific automation run (e.g. @{ "BuildTicket" = "INC12345" }).

.PARAMETER RetentionDays
    Optional. Only snapshots older than this many days (based on TimeCreated) are deleted.
    For example, -RetentionDays 7 deletes snapshots created more than 7 days ago.

.PARAMETER Force
    Skips the interactive confirmation prompt. Use with caution.

.EXAMPLE
    .\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup"

    Lists every snapshot in the resource group and interactively prompts you to delete all of them,
    a selected subset (by number), or none.

    To DELETE ALL snapshots after the list is displayed, respond to the "Your selection" prompt with:

        all

    then type 'yes' at the confirmation prompt. To delete a subset, enter the numbers shown in the
    list separated by commas (for example: 1,3,4).

.EXAMPLE
    .\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -Force

    Lists every snapshot in the resource group and deletes ALL of them without any prompt.
    (Non-interactive equivalent of typing 'all' + 'yes'. Use with caution.)

.EXAMPLE
    .\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -VMNames "VM-Web-01","VM-App-02" -WhatIf

    Shows which snapshots for the given VMs would be deleted without actually deleting them.

.EXAMPLE
    .\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -RetentionDays 7

    Deletes all snapshot.ps1-style snapshots older than 7 days.

.EXAMPLE
    .\Remove-Snapshots.ps1 -ResourceGroupName "MyResourceGroup" -Tags @{ "BuildTicket" = "INC12345" } -Force

    Deletes all snapshots tagged with BuildTicket=INC12345 without prompting.

.NOTES
    Version: 1.0
    Author: Vatsal Singh
    Creation Date: 2026-09-12
    Last Modified: 2026-09-12
#>

#Requires -Modules Az.Accounts, Az.Compute

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The name of the resource group containing the snapshots.")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "An array of VM names whose snapshots should be removed.")]
    [string[]]$VMNames,

    [Parameter(Mandatory = $false, HelpMessage = "Wildcard pattern to match snapshot names. Defaults to all snapshots.")]
    [ValidateNotNullOrEmpty()]
    [string]$NamePattern = "*",

    [Parameter(Mandatory = $false, HelpMessage = "Tags that a snapshot must all have to be removed.")]
    [hashtable]$Tags,

    [Parameter(Mandatory = $false, HelpMessage = "Only delete snapshots older than this many days.")]
    [ValidateRange(0, 3650)]
    [int]$RetentionDays,

    [Parameter(Mandatory = $false, HelpMessage = "Skip the interactive confirmation prompt.")]
    [switch]$Force
)

# Set common preferences
$ErrorActionPreference = 'Stop'

# Function to determine whether a snapshot matches all supplied filters
function Test-SnapshotMatch {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot,

        [string[]]$VMNames,
        [string]$NamePattern,
        [hashtable]$Tags,
        [Nullable[int]]$RetentionDays
    )

    # Name pattern filter
    if ($NamePattern -and ($Snapshot.Name -notlike $NamePattern)) {
        return $false
    }

    # VM name prefix filter (matches "{VMName}-...")
    if ($VMNames -and $VMNames.Count -gt 0) {
        $matchesVm = $false
        foreach ($vm in $VMNames) {
            if ($Snapshot.Name -like "$vm-*") {
                $matchesVm = $true
                break
            }
        }
        if (-not $matchesVm) {
            return $false
        }
    }

    # Tag filter - snapshot must contain ALL supplied tags
    if ($Tags -and $Tags.Count -gt 0) {
        if (-not $Snapshot.Tags) {
            return $false
        }
        foreach ($key in $Tags.Keys) {
            if (-not $Snapshot.Tags.ContainsKey($key)) {
                return $false
            }
            if ($Snapshot.Tags[$key] -ne $Tags[$key]) {
                return $false
            }
        }
    }

    # Age / retention filter
    if ($null -ne $RetentionDays) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        if ($null -eq $Snapshot.TimeCreated -or $Snapshot.TimeCreated -gt $cutoff) {
            return $false
        }
    }

    return $true
}

# Function to display a numbered inventory of snapshots.
function Show-SnapshotInventory {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Snapshots,

        [string]$Title = "Snapshots found in resource group '$ResourceGroupName':"
    )

    Write-Output "`n=========================================="
    Write-Output $Title
    Write-Output "=========================================="
    $index = 1
    foreach ($snap in $Snapshots) {
        $created = if ($snap.TimeCreated) { $snap.TimeCreated.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
        Write-Output ("  [{0}] {1}  (SizeGB: {2}, Sku: {3}, Created: {4})" -f $index, $snap.Name, $snap.DiskSizeGB, $snap.Sku.Name, $created)
        $index++
    }
    Write-Output "=========================================="
}

# Function to interactively let the user choose which snapshots to delete.
# Returns the selected snapshot objects, or $null if the user cancels.
function Select-SnapshotsInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Snapshots
    )

    # The inventory has already been displayed by the caller; just show the prompt options.
    # ---------------------------------------------------------------------------------------
    # HOW TO DELETE ALL SNAPSHOTS AFTER THE LIST IS DISPLAYED:
    #   When this prompt appears, type:  all   then press Enter.
    #   You will then be asked to type 'yes' to confirm the deletion of every snapshot listed.
    # To delete only some, type their numbers separated by commas, e.g.:  1,3,4
    # To cancel, type 'none' or just press Enter.
    # ---------------------------------------------------------------------------------------
    Write-Output "Enter 'all' to delete every snapshot listed above,"
    Write-Output "or a comma-separated list of numbers to delete a subset (e.g. 1,3,4),"
    Write-Output "or 'none'/blank to cancel."

    $choice = Read-Host "Your selection"

    if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().ToLower() -eq 'none') {
        return $null
    }

    if ($choice.Trim().ToLower() -eq 'all') {
        return $Snapshots
    }

    # Parse comma-separated numbers
    $selected = New-Object System.Collections.Generic.List[object]
    $invalid = @()
    foreach ($token in ($choice -split ',')) {
        $trimmed = $token.Trim()
        if ($trimmed -eq '') { continue }
        $num = 0
        if ([int]::TryParse($trimmed, [ref]$num) -and $num -ge 1 -and $num -le $Snapshots.Count) {
            $item = $Snapshots[$num - 1]
            if (-not $selected.Contains($item)) {
                $selected.Add($item)
            }
        }
        else {
            $invalid += $trimmed
        }
    }

    if ($invalid.Count -gt 0) {
        Write-Warning "Ignoring invalid selection(s): $($invalid -join ', ')"
    }

    if ($selected.Count -eq 0) {
        return $null
    }

    return $selected.ToArray()
}

# Main execution logic
try {
    # Validate Azure account connection
    Write-Output "Validating Azure account connection..."
    if (-not (Get-AzContext).Subscription) {
        throw "Not connected to an Azure account. Please run 'Connect-AzAccount' first."
    }

    Write-Output "`nRetrieving snapshots from resource group '$ResourceGroupName'..."
    $AllSnapshots = Get-AzSnapshot -ResourceGroupName $ResourceGroupName

    if (-not $AllSnapshots) {
        Write-Output "No snapshots found in resource group '$ResourceGroupName'. Nothing to do."
        exit 0
    }

    # Always list the full snapshot inventory of the resource group before doing anything else.
    $AllSnapshots = @($AllSnapshots)
    Show-SnapshotInventory -Snapshots $AllSnapshots -Title "All $($AllSnapshots.Count) snapshot(s) in resource group '$ResourceGroupName':"

    # Determine whether the user supplied any explicit filtering criteria.
    # If they only passed -ResourceGroupName, we treat the whole group as the candidate set
    # and let them interactively choose which snapshots to delete.
    $explicitFilters = $PSBoundParameters.ContainsKey('VMNames') -or
                       $PSBoundParameters.ContainsKey('NamePattern') -or
                       $PSBoundParameters.ContainsKey('Tags') -or
                       $PSBoundParameters.ContainsKey('RetentionDays')

    if (-not $explicitFilters) {
        # Interactive mode: only when running against a real terminal and not in -WhatIf/-Force bulk mode
        Write-Output "`nNo filters specified - all $($AllSnapshots.Count) snapshot(s) in the resource group are candidates for deletion."

        if ($WhatIfPreference -or $Force) {
            # Non-interactive bulk: target everything (WhatIf will only report, Force will delete all)
            $TargetSnapshots = @($AllSnapshots)
        }
        else {
            $TargetSnapshots = Select-SnapshotsInteractive -Snapshots @($AllSnapshots)
            if (-not $TargetSnapshots) {
                Write-Output "No snapshots selected. Nothing was deleted."
                exit 0
            }
        }
    }
    else {
        # Normalize RetentionDays into a nullable value so the filter can tell "not supplied" from 0
        $RetentionDaysValue = if ($PSBoundParameters.ContainsKey('RetentionDays')) { [Nullable[int]]$RetentionDays } else { $null }

        # Apply filters
        $TargetSnapshots = @($AllSnapshots | Where-Object {
            Test-SnapshotMatch -Snapshot $_ -VMNames $VMNames -NamePattern $NamePattern -Tags $Tags -RetentionDays $RetentionDaysValue
        })

        if (-not $TargetSnapshots) {
            Write-Output "No snapshots matched the specified filters. Nothing to delete."
            exit 0
        }
    }

    # Report what will be affected
    Write-Output "`n=========================================="
    Write-Output "The following $($TargetSnapshots.Count) snapshot(s) are targeted for deletion:"
    Write-Output "=========================================="
    $TargetSnapshots |
        Select-Object Name,
            @{ Name = 'SizeGB'; Expression = { $_.DiskSizeGB } },
            @{ Name = 'Sku'; Expression = { $_.Sku.Name } },
            @{ Name = 'Incremental'; Expression = { $_.Incremental } },
            TimeCreated |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    # Final confirmation.
    # In interactive selection mode the user already chose specific items, so we still confirm the
    # destructive action unless -Force is used. Skipped for -WhatIf (nothing is deleted anyway).
    if (-not $Force -and -not $WhatIfPreference) {
        $response = Read-Host "Are you sure you want to delete these $($TargetSnapshots.Count) snapshot(s)? Type 'yes' to continue"
        if ($response -ne 'yes') {
            Write-Output "Deletion cancelled by user. No snapshots were removed."
            exit 0
        }
    }

    # Delete snapshots
    $deleted = 0
    $failed = 0
    $skipped = 0
    foreach ($Snapshot in $TargetSnapshots) {
        # Resolve the snapshot name defensively. Depending on how the object was produced,
        # the name may live on .Name or need to be parsed from the resource .Id.
        $snapshotName = $Snapshot.Name
        if ([string]::IsNullOrWhiteSpace($snapshotName) -and $Snapshot.Id) {
            $snapshotName = ($Snapshot.Id -split '/')[-1]
        }

        if ([string]::IsNullOrWhiteSpace($snapshotName)) {
            Write-Warning "Skipping a snapshot entry with no resolvable name (Id: '$($Snapshot.Id)')."
            $skipped++
            continue
        }

        if ($PSCmdlet.ShouldProcess($snapshotName, "Remove snapshot")) {
            try {
                Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Force -Confirm:$false | Out-Null
                Write-Output "[OK] Deleted snapshot '$snapshotName'"
                $deleted++
            }
            catch {
                Write-Error "Failed to delete snapshot '$snapshotName': $($_.Exception.Message)"
                $failed++
            }
        }
    }

    Write-Output "`n=========================================="
    if ($WhatIfPreference) {
        Write-Output "WhatIf: $($TargetSnapshots.Count) snapshot(s) would have been deleted."
    }
    else {
        Write-Output "Snapshot cleanup completed. Deleted: $deleted, Failed: $failed, Skipped: $skipped."
    }
    Write-Output "=========================================="

    if ($failed -gt 0) {
        exit 1
    }
    exit 0
}
catch {
    Write-Error "Script failed: $($_.Exception.Message)"
    exit 1
}
