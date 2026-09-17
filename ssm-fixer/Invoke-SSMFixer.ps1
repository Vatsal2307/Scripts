<#
.SYNOPSIS
    Auto-remediates AWS SSM Agent failures on Azure VMs via Azure Run Command.

.DESCRIPTION
    Progressively diagnoses and fixes SSM Agent issues on hybrid-registered Azure VMs.
    Uses Set-AzVMRunCommand (managed Run Command) to execute remediation steps remotely - no RDP or SSH needed.

    Supports both Windows and Linux VMs. The OS is auto-detected from the Azure VM metadata
    and the appropriate Run Command type (RunPowerShellScript / RunShellScript) and
    OS-specific scripts are used automatically.

    Works alongside the existing bootstrap scripts:
      - Windows: bootstrap.ps1 (Rackspace Platform Services SSM bootstrap)
      - Linux:   bootstrap.py  (Rackspace Platform Services SSM bootstrap)

    Escalates through diagnostic and remediation steps, stopping when the agent is healthy.

    Steps:
      1. Diagnose    - Service status, agent version, registration, connectivity, logs, ssm-cli diagnostics
      2. Restart     - Restart the SSM Agent service
      3. Reregister  - Clear registration and re-register via bootstrap
      4. Reinstall   - Full uninstall + install via bootstrap

.PARAMETER ResourceGroupName
    Azure Resource Group containing the target VM.

.PARAMETER VMName
    Name of the Azure VM to remediate.

.PARAMETER Region
    AWS region override for SSM endpoints (e.g., us-east-1). Optional - auto-detected
    from the VM's existing SSM registration.

.PARAMETER Platform
    Platform identifier for bootstrap scripts. Default: Azure.

.PARAMETER HttpProxy
    Proxy URL if the VM uses one (e.g., http://10.22.33.44:4242).

.PARAMETER DiagnoseOnly
    Run diagnostic steps only (Step 1) without making changes.

.PARAMETER MaxStep
    Maximum remediation step to attempt (1-4). Default: 4.

.PARAMETER SkipToStep
    Skip directly to a specific step (1-4). Default: 1.

.PARAMETER TimeoutSeconds
    Timeout in seconds for each Azure Run Command invocation. Default: 300 (5 minutes).

.PARAMETER Json
    Output results as a single JSON object to stdout instead of interactive console
    formatting. Designed for headless/automated environments where a frontend or
    pipeline will consume the structured output. All Write-Host display is suppressed.

.PARAMETER Auto
    Run without interactive prompts - the script decides and executes actions
    automatically based on diagnosis. Intended for headless / scripted use.
    `-Json` implies `-Auto`. Default behaviour (without this switch) is to
    diagnose, present a menu of suggested actions, and wait for user choice
    before making any changes.

.EXAMPLE
    .\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01"

.EXAMPLE
    .\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -DiagnoseOnly

.EXAMPLE
    .\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Json

.EXAMPLE
    # Headless / scripted: diagnose and auto-apply best guess remediation
    .\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Auto

.EXAMPLE
    .\Invoke-SSMFixer.ps1 -ResourceGroupName "prod-rg" -VMName "web-01" -Region "us-east-1" -SkipToStep 3
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$Region,

    [ValidateSet("Azure", "Dedicated", "VMWare", "GCP", "OpenStack")]
    [string]$Platform = "Azure",

    [string]$HttpProxy,

    [switch]$DiagnoseOnly,

    [ValidateRange(1, 4)]
    [int]$MaxStep = 4,

    [ValidateRange(1, 4)]
    [int]$SkipToStep = 1,

    [int]$TimeoutSeconds = 300,

    [switch]$Json,

    [switch]$Auto
)

$ErrorActionPreference = 'Stop'

# Suppress Az cmdlet progress bars globally. Set-AzVMRunCommand and
# Get-AzVMRunCommand emit "Checking operation status" Write-Progress that
# spews repeated lines. Setting both script-scope and global ensures the
# suppression works even in child scopes and module-internal calls.
$ProgressPreference = 'SilentlyContinue'
$global:ProgressPreference = 'SilentlyContinue'

# --- Load core module (schema + workflow engine) ---
. (Join-Path $PSScriptRoot 'SSMFixer.Core.ps1')

# -Json implies -Auto (can't prompt in headless mode).
# When either is explicitly set by the caller, we keep the existing -SkipToStep
# semantics; otherwise we force $SkipToStep back to 1 so the menu has full
# diagnostic data before presenting options.
if ($Json.IsPresent) { $Auto = [switch]::Present }
$script:Interactive = -not ($Auto.IsPresent -or $DiagnoseOnly.IsPresent)

# When -Json is active, suppress all interactive console output.
# Write-Host goes to the host UI (not stdout), so it won't pollute the JSON,
# but we still suppress it to avoid noise in headless terminals.
$script:SuppressConsole = $Json.IsPresent

#region --- Display Helpers ---

function Write-Banner {
    param([string]$Text)
    if ($script:SuppressConsole) { return }
    $line = "=" * 72
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-Step {
    param([int]$Number, [string]$Title, [string]$Risk)
    if ($script:SuppressConsole) { return }
    $riskColor = switch ($Risk) { 'No' { 'Green' } 'Low' { 'Yellow' } 'Medium' { 'DarkYellow' } 'High' { 'Red' } default { 'Gray' } }
    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host -NoNewline "  STEP $Number " -ForegroundColor White
    Write-Host -NoNewline "$Title " -ForegroundColor Cyan
    Write-Host "[$Risk risk]" -ForegroundColor $riskColor
    Write-Host ("-" * 72) -ForegroundColor DarkGray
}

function Write-Field {
    param([string]$Label, [string]$Value, [string]$ValueColor = 'White')
    if ($script:SuppressConsole) { return }
    $padded = $Label.PadRight(22)
    Write-Host -NoNewline "  $padded" -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-StatusField {
    param([string]$Label, [string]$Value, [string]$GoodValues = 'Running,True,Present,Yes,Success,OK,active')
    if ($script:SuppressConsole) { return }
    $goodList = $GoodValues -split ','
    $isGood = $false
    foreach ($g in $goodList) {
        if ($Value -like "*$g*") { $isGood = $true; break }
    }
    $color = if ($isGood) { 'Green' } elseif ($Value -in @('N/A','Skipped','')) { 'DarkGray' } else { 'Red' }
    Write-Field -Label $Label -Value $Value -ValueColor $color
}

function Write-Ok    { param([string]$Msg) if (-not $script:SuppressConsole) { Write-Host "  [OK] $Msg" -ForegroundColor Green } }
function Write-Fail  { param([string]$Msg) if (-not $script:SuppressConsole) { Write-Host "  [FAIL] $Msg" -ForegroundColor Red } }
function Write-Warn  { param([string]$Msg) if (-not $script:SuppressConsole) { Write-Host "  [!] $Msg" -ForegroundColor Yellow } }
function Write-Info  { param([string]$Msg) if (-not $script:SuppressConsole) { Write-Host "  $Msg" -ForegroundColor DarkGray } }
function Write-Action { param([string]$Msg) if (-not $script:SuppressConsole) { Write-Host "  >> $Msg" -ForegroundColor Yellow } }

# Whether stdout is going to an interactive TTY. Used by the Run Command
# heartbeat to decide between an in-place updating line (interactive) and a
# fresh line every N seconds (CI / file redirect). Lazily resolved once.
$script:IsTty = $null
function Test-Interactive {
    if ($null -eq $script:IsTty) {
        try   { $script:IsTty = -not [Console]::IsOutputRedirected }
        catch { $script:IsTty = $true }
    }
    return $script:IsTty
}

function Write-Heartbeat {
    <#
    .SYNOPSIS
        Emits a progress heartbeat for a long-running Run Command.
    .DESCRIPTION
        In interactive hosts: rewrites a single line in place using `r so the
        terminal shows a live "elapsed / timeout" counter that doesn't scroll.
        In non-interactive output (CI logs, redirected files, tee): prints a
        fresh line periodically so progress is captured without flooding.
        The caller chooses cadence by deciding when to call this.
    #>
    param(
        [string]$Label,
        [int]$ElapsedSec,
        [int]$TimeoutSec,
        [switch]$Final
    )
    if ($script:SuppressConsole) { return }

    $bar = '{0,-32} {1,4}s / {2}s' -f $Label, $ElapsedSec, $TimeoutSec

    if (Test-Interactive) {
        # In-place update: pad to a fixed width so partial lines from previous
        # iterations don't bleed through, then return to start of line.
        $padded = $bar.PadRight(72)
        Write-Host -NoNewline ("`r  ... " + $padded) -ForegroundColor DarkGray
        if ($Final) { Write-Host '' }    # newline so subsequent output starts clean
    } else {
        # Non-interactive: one line per call. Caller controls cadence.
        Write-Host ("  ... " + $bar) -ForegroundColor DarkGray
    }
}

function Wait-WithHeartbeat {
    <#
    .SYNOPSIS
        Sleep for $Seconds while emitting a progress heartbeat. Replaces a
        bare Start-Sleep so the user can see we're waiting on purpose, not
        hung. Cadence matches Write-Heartbeat: 1s in interactive hosts (in
        place), 5s in non-interactive captures.
    #>
    param(
        [int]$Seconds,
        [string]$Label = 'Waiting'
    )
    if ($script:SuppressConsole -or $Seconds -le 0) {
        if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds }
        return
    }
    $tickInterval = if (Test-Interactive) { 1 } else { 5 }
    $nextTick = 0
    for ($elapsed = 0; $elapsed -lt $Seconds; $elapsed++) {
        if ($elapsed -ge $nextTick) {
            Write-Heartbeat -Label $Label -ElapsedSec $elapsed -TimeoutSec $Seconds
            $nextTick = $elapsed + $tickInterval
        }
        Start-Sleep -Seconds 1
    }
    Write-Heartbeat -Label $Label -ElapsedSec $Seconds -TimeoutSec $Seconds -Final
}

function Invoke-ActionMenu {
    <#
    .SYNOPSIS
        Interactive prompt that lets the user choose how to proceed after Step 1.
    .DESCRIPTION
        Called after diagnostics complete when the script is running in interactive
        mode (neither -Auto, -Json nor -DiagnoseOnly). The recommended option is
        computed in Step 1 and surfaced as the default at the `>` prompt.

        Returns a hashtable describing what the caller should do:
            Action        - one of: FixStartup, Restart, Reregister, Reinstall,
                            DiagnoseOnly, Quit
            SkipToStep    - the step number to jump to (if applicable)
            MaxStep       - cap applied to prevent fall-through to higher-risk steps
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Diagnosis,
        [string]$Recommended
    )

    $options = [ordered]@{
        '1' = @{ Label = 'Restart SSM Agent service only (Step 2, Low risk)';                     Action = 'Restart';      SkipToStep = 2; MaxStep = 2 }
        '2' = @{ Label = 'Clear registration and Re-register (Step 3, Medium risk)';              Action = 'Reregister';   SkipToStep = 3; MaxStep = 3 }
        '3' = @{ Label = 'Full uninstall and reinstall (Step 4, High risk)';                      Action = 'Reinstall';    SkipToStep = 4; MaxStep = 4 }
        '4' = @{ Label = 'Progressive: Restart -> Re-register -> Reinstall (Steps 2-4)';          Action = 'Progressive';  SkipToStep = 2; MaxStep = 4 }
        '5' = @{ Label = "Fix service startup type only (set to Automatic, no restart)";          Action = 'FixStartup';   SkipToStep = 0; MaxStep = 0 }
        '6' = @{ Label = 'Exit without making changes (diagnostics only)';                        Action = 'DiagnoseOnly'; SkipToStep = 0; MaxStep = 0 }
        'Q' = @{ Label = 'Quit';                                                                  Action = 'Quit';         SkipToStep = 0; MaxStep = 0 }
    }

    # Only surface "Fresh Install" when the agent isn't present - otherwise it's
    # strictly worse than Reinstall.
    if ($Diagnosis.ServiceStatus -eq 'NOT_INSTALLED') {
        $options = [ordered]@{
            '1' = @{ Label = 'Fresh install (no existing agent detected)';             Action = 'Install';     SkipToStep = 1; MaxStep = 4 }
            '2' = @{ Label = 'Exit without making changes (diagnostics only)';         Action = 'DiagnoseOnly'; SkipToStep = 0; MaxStep = 0 }
            'Q' = @{ Label = 'Quit';                                                   Action = 'Quit';        SkipToStep = 0; MaxStep = 0 }
        }
    }

    # Pick the default based on the Step 1 recommendation
    $default = $null
    foreach ($k in $options.Keys) {
        if ($options[$k].Action -eq $Recommended) { $default = $k; break }
    }
    if (-not $default) { $default = ($options.Keys | Select-Object -First 1) }

    Write-Host ""
    Write-Host "  +==================================================================+" -ForegroundColor Cyan
    Write-Host "  |  Choose an action                                                |" -ForegroundColor Cyan
    Write-Host "  +==================================================================+" -ForegroundColor Cyan
    foreach ($k in $options.Keys) {
        $marker = if ($k -eq $default) { ' (recommended)' } else { '' }
        $color  = if ($k -eq $default) { 'Yellow' } else { 'Gray' }
        Write-Host ("   {0}) {1}{2}" -f $k, $options[$k].Label, $marker) -ForegroundColor $color
    }
    Write-Host ""

    do {
        $raw = Read-Host ("  Selection [{0}]" -f $default)
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $default }
        $raw = $raw.Trim().ToUpper()
    } while (-not $options.Contains($raw))

    return $options[$raw]
}

function Write-EscalationBanner {
    <#
    .SYNOPSIS  Prints a highly-visible banner when the failure is off-VM (e.g. Platform Services).
    #>
    param(
        [string]$Reason,
        [PSCustomObject]$BootstrapResult
    )
    if ($script:SuppressConsole) { return }
    Write-Host ""
    Write-Host "  +==================================================================+" -ForegroundColor Magenta
    Write-Host "  |                      ESCALATION REQUIRED                         |" -ForegroundColor Magenta
    Write-Host "  +==================================================================+" -ForegroundColor Magenta
    Write-Host "  Reason: $Reason" -ForegroundColor Yellow
    if ($BootstrapResult) {
        if ($null -ne $BootstrapResult.ExitCode) {
            Write-Host ("  Bootstrap exit: {0} - {1}" -f $BootstrapResult.ExitCode, $BootstrapResult.ExitCodeMessage) -ForegroundColor Yellow
        }
        if ($BootstrapResult.ActivationHttpStatus) {
            Write-Host ("  Activation HTTP: {0} at {1}" -f $BootstrapResult.ActivationHttpStatus, $BootstrapResult.ActivationUrl) -ForegroundColor Yellow
        }
    }
    Write-Host "  The VM side looks healthy. This failure is outside the fixer's control." -ForegroundColor Yellow
    Write-Host "  Escalate to #passport-escalations with the data above." -ForegroundColor Yellow
    Write-Host ""
}

function Write-ChangesSummary {
    param([System.Collections.ArrayList]$Changes)
    if ($script:SuppressConsole) { return }
    if ($Changes.Count -gt 0) {
        Write-Host ""
        Write-Host "  Changes Made:" -ForegroundColor Green
        foreach ($change in $Changes) {
            Write-Host "    + $change" -ForegroundColor Green
        }
    }
}

#endregion

#region --- VM Health Diagnosis ---

function Write-RunCommandFailureDiagnosis {
    <#
    .SYNOPSIS
        When Run Command fails (timeout, no response), queries Azure VM metadata
        to diagnose the root cause. In DiagnoseOnly mode, reports findings and
        lists remediation options. In remediation mode, presents options and lets
        the user choose which to execute.
    .OUTPUTS
        Returns a New-SSMRunCommandFailure object for schema population.
    #>
    param(
        [string]$RG,
        [string]$VM,
        [string]$OsType,
        [switch]$DiagnoseOnly
    )

    if (-not $script:SuppressConsole) {
        Write-Host ""
        Write-Host "  Run Command Failure Diagnosis:" -ForegroundColor Cyan
        Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  This is NOT an SSM agent issue. The Azure Run Command could not" -ForegroundColor Yellow
        Write-Host "  reach the VM, which means the Azure VM agent is unresponsive" -ForegroundColor Yellow
        Write-Host "  or the VM itself has a problem." -ForegroundColor Yellow
        Write-Host ""
    }

    $issues = @()
    $remediations = [System.Collections.ArrayList]::new()
    $stuckCmds = @()
    $rcfPowerState = 'Unknown'
    $rcfProvState = $null
    $rcfAgentVer = $null
    $rcfAgentStatus = $null

    try {
        $vmStatus = Get-AzVM -ResourceGroupName $RG -Name $VM -Status -ErrorAction Stop
        $rcfPowerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
        $rcfProvState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' }).DisplayStatus

        Write-Field "VM Power State" $rcfPowerState $(if ($rcfPowerState -eq 'VM running') { 'Green' } else { 'Red' })
        if ($rcfProvState) {
            Write-Field "Provisioning" $rcfProvState $(if ($rcfProvState -like '*succeeded*') { 'Green' } else { 'Yellow' })
        }

        if ($rcfPowerState -ne 'VM running') {
            $issues += "VM is not running (state: $rcfPowerState)"
            $remediations.Add(@{
                Label  = "Start the VM"
                Detail = "Start-AzVM -ResourceGroupName '$RG' -Name '$VM'"
                Action = { Start-AzVM -ResourceGroupName $RG -Name $VM }
            }) | Out-Null
        }

        if ($vmStatus.VMAgent) {
            $rcfAgentVer = $vmStatus.VMAgent.VMAgentVersion
            Write-Field "Azure VM Agent" $rcfAgentVer 'White'

            $agentStatus = $vmStatus.VMAgent.Statuses | Select-Object -First 1
            if ($agentStatus) {
                $rcfAgentStatus = $agentStatus.DisplayStatus
                $agentTime = $agentStatus.Time
                Write-StatusField "Agent Status" $rcfAgentStatus

                if ($rcfAgentStatus -ne 'Ready') {
                    $issues += "Azure VM agent status is '$rcfAgentStatus' (expected: Ready)"
                    if ($agentTime) {
                        $agentAge = (Get-Date) - [DateTime]$agentTime
                        if ($agentAge.TotalHours -gt 1) {
                            Write-Field "Last Heartbeat" "$([math]::Round($agentAge.TotalHours, 1)) hours ago" 'Red'
                            $issues += "Agent last reported $([math]::Round($agentAge.TotalHours, 1)) hours ago"
                        }
                    }
                }
            }

            if ($OsType -eq 'Linux' -and $rcfAgentVer -and $rcfAgentVer -ne 'Unknown') {
                try {
                    $verParts = $rcfAgentVer -split '\.'
                    $verNum = [int]$verParts[0] * 1000000 + [int]$verParts[1] * 10000 + [int]$verParts[2] * 100 + [int]$verParts[3]
                    $minNum = 2 * 1000000 + 4 * 10000 + 0 * 100 + 2  # 2.4.0.2
                    if ($verNum -lt $minNum) {
                        $issues += "Azure VM agent version $rcfAgentVer is below minimum 2.4.0.2 for managed Run Command"
                        $issues += "Upgrade required via Serial Console or direct access"
                    }
                } catch {
                    Write-Verbose "Could not parse agent version: $rcfAgentVer"
                }
            }

            $extensions = $vmStatus.Extensions
            if ($extensions) {
                foreach ($ext in $extensions) {
                    $extStatus = ($ext.Statuses | Select-Object -First 1)
                    $extState = if ($extStatus) { $extStatus.DisplayStatus } else { 'Unknown' }
                    $extLevel = if ($extStatus) { $extStatus.Level } else { 'Unknown' }

                    if ($ext.Name -like '*RunCommand*' -or $ext.Type -like '*RunCommand*') {
                        Write-Field "Run Cmd Extension" "$($ext.Name): $extState" $(if ($extState -like '*success*') { 'Green' } else { 'Yellow' })
                        if ($extState -notlike '*success*') {
                            $issues += "Run Command extension '$($ext.Name)' status: $extState"
                        }
                    }
                    if ($extLevel -eq 'Error' -or $extState -like '*failed*' -or $extState -like '*transitioning*') {
                        $issues += "Extension '$($ext.Name)' is in state: $extState"
                    }
                }
            }
        } else {
            Write-StatusField "Azure VM Agent" "NOT REPORTING"
            $issues += "Azure VM agent is not reporting any status to Azure"
        }

        if (-not $script:SuppressConsole) { Write-Host "" }
        Write-Info "Checking for stuck Run Command resources..."
        try {
            $existingCmds = Get-AzVMRunCommand -ResourceGroupName $RG -VMName $VM -ErrorAction Stop
            if ($existingCmds -and $existingCmds.Count -gt 0) {
                foreach ($cmd in $existingCmds) {
                    try {
                        $cmdDetail = Get-AzVMRunCommand -ResourceGroupName $RG -VMName $VM -RunCommandName $cmd.Name -Expand InstanceView -ErrorAction Stop
                        $state = $cmdDetail.InstanceView.ExecutionState
                        $cmdAge = if ($cmdDetail.InstanceView.StartTime) { (Get-Date) - [DateTime]$cmdDetail.InstanceView.StartTime } else { $null }

                        if ($state -in @('Running', 'Pending') -and $cmdAge -and $cmdAge.TotalMinutes -gt 30) {
                            $stuckCmds += @{ Name = $cmd.Name; State = $state; Age = "$([math]::Round($cmdAge.TotalMinutes)) min" }
                        } elseif ($state -eq 'Deleting') {
                            # Run Commands stuck in Deleting never complete - always flag them
                            $stuckCmds += @{ Name = $cmd.Name; State = $state; Age = if ($cmdAge) { "$([math]::Round($cmdAge.TotalMinutes)) min" } else { "unknown" } }
                        } elseif ($state -notin @('Succeeded', 'Failed') -and -not $cmdAge) {
                            $stuckCmds += @{ Name = $cmd.Name; State = $state; Age = "unknown" }
                        }
                    } catch {
                        $stuckCmds += @{ Name = $cmd.Name; State = "unknown"; Age = "unknown" }
                    }
                }

                Write-Field "Run Commands Found" "$($existingCmds.Count) total" 'White'

                if ($stuckCmds.Count -gt 0) {
                    $issues += "$($stuckCmds.Count) stuck/stale Run Command(s) found"
                    if (-not $script:SuppressConsole) {
                        Write-Host ""
                        Write-Host "  Stuck Run Commands:" -ForegroundColor Yellow
                        foreach ($sc in $stuckCmds) {
                            Write-Host "    - $($sc.Name) (state: $($sc.State), age: $($sc.Age))" -ForegroundColor Yellow
                        }
                    }

                    $remediations.Add(@{
                        Label  = "Remove $($stuckCmds.Count) stuck Run Command resource(s)"
                        Detail = "Remove-AzVMRunCommand for each stuck command"
                        Action = {
                            $cleaned = 0
                            foreach ($sc in $stuckCmds) {
                                try {
                                    Remove-AzVMRunCommand -ResourceGroupName $RG -VMName $VM -RunCommandName $sc.Name -NoWait -ErrorAction Stop | Out-Null
                                    $cleaned++
                                } catch {
                                    Write-Warn "Could not remove '$($sc.Name)': $($_.Exception.Message)"
                                }
                            }
                            if ($cleaned -gt 0) { Write-Ok "Removed $cleaned stuck Run Command resource(s)" }
                        }
                    }) | Out-Null
                } else {
                    Write-Ok "No stuck Run Commands found"
                }
            } else {
                Write-Ok "No Run Command resources on this VM"
            }
        } catch {
            Write-Warn "Could not list Run Commands: $($_.Exception.Message)"
        }

    } catch {
        Write-Warn "Could not query VM status: $($_.Exception.Message)"
        $issues += "Failed to query Azure VM metadata"
    }

    # --- Build remaining remediation options ---
    if ($issues.Count -eq 0) {
        $issues += "VM appears healthy from Azure's perspective but Run Command still failed"
    }

    $restartCmd = if ($OsType -eq 'Linux') { 'sudo systemctl restart walinuxagent' } else { 'Restart-Service WindowsAzureGuestAgent' }
    $logPath = if ($OsType -eq 'Linux') { '/var/log/waagent.log' } else { 'C:\WindowsAzure\Logs\WaAppAgent.log' }

    $remediations.Add(@{
        Label  = "Restart the VM (restarts Azure VM agent and clears stuck state)"
        Detail = "Restart-AzVM -ResourceGroupName '$RG' -Name '$VM'"
        Action = { Restart-AzVM -ResourceGroupName $RG -Name $VM }
    }) | Out-Null

    # --- Display issues ---
    if (-not $script:SuppressConsole) {
        Write-Host ""
        Write-Host "  Issues Detected:" -ForegroundColor Red
        foreach ($issue in $issues) {
            Write-Host "    - $issue" -ForegroundColor Red
        }

        # --- Display remediation options ---
        Write-Host ""
        Write-Host "  Remediation Options:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $remediations.Count; $i++) {
            $r = $remediations[$i]
            Write-Host "    $($i + 1). $($r.Label)" -ForegroundColor White
            Write-Host "       $($r.Detail)" -ForegroundColor DarkGray
        }

        # Manual-only suggestions (always shown, never automated)
        Write-Host ""
        Write-Host "  Manual Steps (require console/portal access):" -ForegroundColor DarkGray
        Write-Host "    - Restart Azure VM agent via Serial Console: $restartCmd" -ForegroundColor DarkGray
        Write-Host "    - Check Serial Console: Azure Portal > VM > Help > Serial Console" -ForegroundColor DarkGray
        Write-Host "    - Review VM agent logs: $logPath" -ForegroundColor DarkGray
    }

    # --- Interactive remediation (only when not DiagnoseOnly and not Json) ---
    if (-not $DiagnoseOnly -and -not $script:SuppressConsole -and $remediations.Count -gt 0) {
        Write-Host ""
        Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
        $prompt = "  Select a remediation option (1-$($remediations.Count)), or 0 to skip: "
        Write-Host -NoNewline $prompt -ForegroundColor Cyan
        $choice = Read-Host

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $remediations.Count) {
            $selected = $remediations[[int]$choice - 1]
            Write-Host ""
            Write-Action "Running: $($selected.Label)..."
            try {
                & $selected.Action
                Write-Ok "Completed: $($selected.Label)"
            } catch {
                Write-Fail "Failed: $($_.Exception.Message)"
            }
        } else {
            Write-Info "Skipped - no remediation selected"
        }
    } elseif ($DiagnoseOnly -and -not $script:SuppressConsole -and $remediations.Count -gt 0) {
        Write-Host ""
        Write-Info "Run without -DiagnoseOnly to execute remediation options interactively."
    }

    if (-not $script:SuppressConsole) { Write-Host "" }

    # --- Return structured data for schema ---
    $remLabels = @($remediations | ForEach-Object { [PSCustomObject]@{ Label = $_.Label; Detail = $_.Detail } })
    $stuckData = @($stuckCmds | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; State = $_.State; Age = $_.Age } })

    return (New-SSMRunCommandFailure `
        -PowerState $rcfPowerState `
        -ProvisioningState $rcfProvState `
        -AzureAgentVersion $rcfAgentVer `
        -AzureAgentStatus $rcfAgentStatus `
        -Issues $issues `
        -StuckRunCommands $stuckData `
        -RemediationOptions $remLabels)
}

#endregion

#region --- OS Detection ---

function Get-VMOsType {
    <#
    .SYNOPSIS
        Detects the OS type and location of an Azure VM using the Azure Resource Manager API.
    .OUTPUTS
        Hashtable with OsType ('Windows' or 'Linux') and Location
    #>
    param(
        [Parameter(Mandatory)][string]$RG,
        [Parameter(Mandatory)][string]$VM
    )

    Write-Verbose "Detecting VM operating system..."
    try {
        $vmObj = Get-AzVM -ResourceGroupName $RG -Name $VM -ErrorAction Stop
        $location = $vmObj.Location
        $osType = $vmObj.StorageProfile.OsDisk.OsType.ToString()
        if ($osType -notin @('Windows', 'Linux')) {
            # Fallback: check the OS profile
            if ($vmObj.OSProfile.WindowsConfiguration) { $osType = 'Windows' }
            elseif ($vmObj.OSProfile.LinuxConfiguration) { $osType = 'Linux' }
            else { throw "Could not determine OS type from VM metadata." }
        }
        return @{ OsType = $osType; Location = $location }
    } catch {
        Write-Fail "Failed to detect OS: $($_.Exception.Message)"
        throw
    }
}

#endregion

#region --- Core Functions ---

function Invoke-RemoteScript {
    <#
    .SYNOPSIS
        Executes a script on the target VM via Azure Managed Run Command (Set-AzVMRunCommand).
        Supports parallel execution (no 409 conflicts), built-in timeout, and clean output.
        Auto-cleans up the Run Command resource after execution.
    .DESCRIPTION
        Returns the stdout string from the remote script, or $null when the Run Command
        submission itself failed (e.g. Azure API error).

        On timeout: waits a short grace period, then reads whatever InstanceView.Output
        has so far, returns it (usually partial), and emits a warning. This is important
        because bootstrap runs can legitimately exceed the timeout while still producing
        useful log output we'd otherwise discard.

        While the job runs, we poll every second and emit a Write-Heartbeat update
        showing elapsed seconds vs timeout. This replaces the noisy "Checking operation
        status" Write-Progress from Set-AzVMRunCommand (suppressed via
        $ProgressPreference) with concise, contextual feedback that's useful in both
        interactive terminals and CI logs.
    #>
    param(
        [string]$RG,
        [string]$VM,
        [string]$Location,
        [string]$Script,
        [string]$OsType,
        [int]$Timeout = 300,
        [string]$Label = 'Run Command'    # shown in the heartbeat line
    )

    $runCommandName = "ssmfixer-$(Get-Date -Format 'HHmmss')-$([System.IO.Path]::GetRandomFileName().Substring(0,4))"

    $setParams = @{
        ResourceGroupName = $RG
        VMName            = $VM
        Location          = $Location
        RunCommandName    = $runCommandName
        SourceScript      = if ($OsType -eq 'Linux') { $Script -replace "`r", "" } else { $Script }
        TimeoutInSecond   = $Timeout
        AsJob             = $true
    }

    Write-Verbose "Executing managed Run Command '$runCommandName' on $VM (timeout: ${Timeout}s)..."

    $timedOut = $false
    $job      = $null
    try {
        $job = Set-AzVMRunCommand @setParams -ErrorAction Stop -WarningAction SilentlyContinue

        # Poll instead of Wait-Job -Timeout so we can emit our own heartbeat.
        # In interactive hosts the heartbeat updates one line in place; in
        # non-interactive captures it prints fresh every $tickInterval seconds.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tickInterval = if (Test-Interactive) { 1 } else { 15 }
        $nextTick = 0
        while ($job.State -eq 'Running') {
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            if ($elapsed -ge $Timeout) { $timedOut = $true; break }
            if ($elapsed -ge $nextTick) {
                Write-Heartbeat -Label $Label -ElapsedSec $elapsed -TimeoutSec $Timeout
                $nextTick = $elapsed + $tickInterval
            }
            Start-Sleep -Milliseconds 1000
        }
        # Final heartbeat clears the in-place line and prints elapsed
        Write-Heartbeat -Label $Label -ElapsedSec ([int]$sw.Elapsed.TotalSeconds) -TimeoutSec $Timeout -Final

        if ($timedOut) {
            Write-Warn "Run Command did not finish within ${Timeout}s - will attempt to read partial output"
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        } else {
            $job | Receive-Job -ErrorAction Stop | Out-Null
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    } catch {
        if ($job) { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
        Write-Fail "Run Command failed: $($_.Exception.Message)"
        return $null
    }

    # Always try to fetch InstanceView, even on timeout - the remote script may
    # have produced useful output we'd otherwise throw away.
    $stdout = $null
    try {
        $cmdResult = Get-AzVMRunCommand -ResourceGroupName $RG -VMName $VM -RunCommandName $runCommandName -Expand InstanceView -ErrorAction Stop -InformationAction SilentlyContinue
        $iv = $cmdResult.InstanceView

        if ($iv.Error) { Write-Verbose "Remote stderr: $($iv.Error)" }

        if (-not $timedOut -and $iv.ExecutionState -ne 'Succeeded') {
            Write-Fail "Run Command execution state: $($iv.ExecutionState)"
            if ($iv.Error) { Write-Warn "Remote error: $($iv.Error.Substring(0, [Math]::Min(200, $iv.Error.Length)))" }
            if ($iv.ExecutionMessage) { Write-Verbose "Message: $($iv.ExecutionMessage)" }
        } elseif ($timedOut) {
            if ($iv.Output) {
                Write-Warn "Captured partial output from the timed-out Run Command (see below)"
            } else {
                Write-Fail "Run Command timed out after ${Timeout}s and produced no output"
            }
        }

        $stdout = $iv.Output
    } catch {
        Write-Fail "Failed to retrieve Run Command results: $($_.Exception.Message)"
    }

    # Cleanup - remove the Run Command resource (fire and forget)
    try { Remove-AzVMRunCommand -ResourceGroupName $RG -VMName $VM -RunCommandName $runCommandName -NoWait -ErrorAction SilentlyContinue | Out-Null } catch {}

    if ($stdout) {
        # Managed Run Command may encode newlines as literal \n
        $stdout = $stdout -replace '\\n$', '' -replace '\\n', "`n"
        $stdout = $stdout.Trim()
    }

    return $stdout
}

function Test-SSMHealthy {
    <#
    .SYNOPSIS
        Verifies agent health (service running + registered with instance ID).
        Retries up to $MaxAttempts times with $RetryDelaySec gaps to handle
        the window after registration where the agent hasn't fully phoned home.
    #>
    param(
        [string]$RG,
        [string]$VM,
        [string]$Location,
        [string]$OsType,
        [int]$Timeout = 300,
        [int]$MaxAttempts = 3,
        [int]$RetryDelaySec = 15
    )

    if ($OsType -eq 'Linux') {
        $script = @'
#!/bin/bash
running=false
registered=false
if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    running=true
elif service amazon-ssm-agent status 2>/dev/null | grep -q "running"; then
    running=true
fi
if command -v ssm-cli &>/dev/null; then
    info=$(ssm-cli get-instance-information 2>&1)
    if echo "$info" | grep -qE '"instance-id"|"InstanceId"'; then
        registered=true
    fi
elif [ -x /usr/bin/ssm-cli ]; then
    info=$(/usr/bin/ssm-cli get-instance-information 2>&1)
    if echo "$info" | grep -qE '"instance-id"|"InstanceId"'; then
        registered=true
    fi
fi
if [ "$running" = true ] && [ "$registered" = true ]; then
    echo "HEALTHY"
else
    echo "UNHEALTHY|Svc=$running|Reg=$registered"
fi
'@
    } else {
        $script = @'
$svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
$running = $svc -and $svc.Status -eq 'Running'
$registered = $false
$ssmCli = "C:\Program Files\Amazon\SSM\ssm-cli.exe"
if (Test-Path $ssmCli) {
    try {
        $info = & $ssmCli get-instance-information 2>&1 | Out-String
        if ($info -match '"instance-id"' -or $info -match '"InstanceId"') { $registered = $true }
    } catch {}
}
if ($running -and $registered) { Write-Output 'HEALTHY' }
else { Write-Output "UNHEALTHY|Svc=$running|Reg=$registered" }
'@
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $label = if ($MaxAttempts -gt 1) { "Health check ($attempt/$MaxAttempts)" } else { 'Health check' }
        $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Location -Script $script -OsType $OsType -Timeout $Timeout -Label $label
        if ($out -and $out.Trim().StartsWith('HEALTHY')) { return $true }

        if ($attempt -lt $MaxAttempts) {
            Write-Info "Health check attempt ${attempt}/${MaxAttempts}: not yet healthy. Retrying in ${RetryDelaySec}s..."
            Wait-WithHeartbeat -Seconds $RetryDelaySec -Label "Waiting before retry (${attempt}/${MaxAttempts})"
        }
    }
    return $false
}

#endregion

#region --- Remote Script Blocks ---

function Get-WindowsBootstrapDownloadFragment {
    <#
    .SYNOPSIS
        Returns a PowerShell fragment (to be embedded in a remote script here-string)
        that downloads bootstrap.ps1 to `$bootstrapPath using a tiered strategy:
          1. curl.exe (ships with Windows 10 1803+ / Server 2019+)
          2. Invoke-WebRequest -UseBasicParsing
          3. System.Net.WebClient (bypasses the IE engine entirely)
        The caller supplies `$dlDir and `$bootstrapPath. On return, `$dlSuccess is $true
        if any method produced a non-empty file. The caller decides what to do on failure.

        Rationale: on fresh Windows Server 2025 VMs running as NT AUTHORITY\SYSTEM,
        Invoke-WebRequest can fail with "Internet Explorer engine is not available"
        even with -UseBasicParsing set, because its redirect handling touches the IE
        profile. curl.exe and WebClient do not.
    #>
    return @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dlUrl = 'https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.ps1'
$dlSuccess = $false
Remove-Item $bootstrapPath -Force -ErrorAction SilentlyContinue

# 1. curl.exe
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not $dlSuccess -and (Test-Path $curl)) {
    Write-Output 'ACTION:Downloading bootstrap.ps1 via curl.exe'
    & $curl -sSfL --max-time 60 -o $bootstrapPath $dlUrl 2>&1 | Out-Null
    if ((Test-Path $bootstrapPath) -and (Get-Item $bootstrapPath).Length -gt 0) {
        $dlSuccess = $true
        Write-Output "OK:Downloaded bootstrap.ps1 via curl ($((Get-Item $bootstrapPath).Length) bytes)"
    } else {
        Write-Output 'WARN:curl.exe download produced no file - falling through'
    }
}

# 2. Invoke-WebRequest
if (-not $dlSuccess) {
    for ($i = 1; $i -le 2; $i++) {
        try {
            Write-Output "ACTION:Downloading bootstrap.ps1 via Invoke-WebRequest (attempt $i)"
            Invoke-WebRequest -Uri $dlUrl -OutFile $bootstrapPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if ((Test-Path $bootstrapPath) -and (Get-Item $bootstrapPath).Length -gt 0) {
                $dlSuccess = $true
                Write-Output "OK:Downloaded bootstrap.ps1 via Invoke-WebRequest ($((Get-Item $bootstrapPath).Length) bytes)"
                break
            }
        } catch {
            Write-Output "WARN:Invoke-WebRequest attempt $i failed - $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

# 3. System.Net.WebClient
if (-not $dlSuccess) {
    for ($i = 1; $i -le 2; $i++) {
        try {
            Write-Output "ACTION:Downloading bootstrap.ps1 via WebClient (attempt $i)"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($dlUrl, $bootstrapPath)
            $wc.Dispose()
            if ((Test-Path $bootstrapPath) -and (Get-Item $bootstrapPath).Length -gt 0) {
                $dlSuccess = $true
                Write-Output "OK:Downloaded bootstrap.ps1 via WebClient ($((Get-Item $bootstrapPath).Length) bytes)"
                break
            }
        } catch {
            Write-Output "WARN:WebClient attempt $i failed - $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $i)
        }
    }
}
'@
}

function Get-WindowsBootstrapWrapper {
    <#
    .SYNOPSIS
        Returns a complete Windows PowerShell remote-script that downloads bootstrap.ps1
        (via the tiered download fragment), runs a given bootstrap command in a child
        process with stdout/stderr captured to files, and emits structured sentinels
        for the caller to parse.

        Emits (in order, designed to fit under Azure Run Command's ~4KB stdout cap):
          - Download ACTION / OK / WARN lines
          - BOOTSTRAP_EXITCODE:<int>
          - BOOTSTRAP_DURATION:<seconds>
          - BOOTSTRAP_STDOUT_TAIL_START ... BOOTSTRAP_STDOUT_TAIL_END   (last 40 lines)
          - BOOTSTRAP_STDERR_START     ... BOOTSTRAP_STDERR_END         (last 20 lines, only if stderr present)
          - BOOTSTRAP_LOG_START        ... BOOTSTRAP_LOG_END             (full agent_bootstrap.log)

    .PARAMETER Command
        Bootstrap's -Command value: 'Install', 'Reregister', or 'Uninstall'.
    .PARAMETER PlatformName
        Platform passed to bootstrap -Platform (e.g. 'Azure', 'VMWare').
    .PARAMETER ProxyUrl
        Optional proxy URL, passed as -HttpProxy to bootstrap.
    .PARAMETER UseLocalFallback
        When set, the wrapper will look for a local copy of bootstrap.ps1 if the
        download fails (used by Reregister/Reinstall, not fresh Install).
    .PARAMETER PreBootstrap
        Optional PowerShell fragment (remote-side) to run after download but before
        bootstrap is invoked. Used by Reinstall to stop the service and clean
        %ProgramData%\Amazon\SSM.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Install','Reregister','Uninstall')][string]$Command,
        [Parameter(Mandatory)][string]$PlatformName,
        [string]$ProxyUrl,
        [switch]$UseLocalFallback,
        [string]$PreBootstrap = ''
    )

    # Build the bootstrap argument list as a remote-side array literal.
    # The placeholder __BOOTSTRAPPATH__ is substituted after string interpolation
    # so the outer here-string doesn't try to resolve $bootstrapPath here.
    $bsArgs = @()
    $bsArgs += "'-NoProfile'","'-ExecutionPolicy'","'Bypass'","'-File'",'__BOOTSTRAPPATH__'
    if ($Command -eq 'Uninstall') {
        $bsArgs += "'-Command'","'Uninstall'"
    } else {
        $bsArgs += "'-Command'","'$Command'","'-Platform'","'$PlatformName'"
    }
    if ($ProxyUrl) { $bsArgs += "'-HttpProxy'","'$ProxyUrl'" }
    $bsArgsLiteral = ('@(' + ($bsArgs -join ',') + ')') -replace '__BOOTSTRAPPATH__', '$bootstrapPath'

    $dlFragment = Get-WindowsBootstrapDownloadFragment

    $localFallbackBlock = if ($UseLocalFallback) { @'

    if (-not $dlSuccess) {
        foreach ($p in @('C:\rs-pkgs\ssm_install.ps1','C:\ProgramData\Amazon\SSM\bootstrap.ps1','C:\Program Files\Amazon\SSM\bootstrap.ps1','C:\Temp\bootstrap.ps1')) {
            if (Test-Path $p) { $bootstrapPath = $p; $dlSuccess = $true; Write-Output "WARN:Using local fallback $p"; break }
        }
    }
'@ } else { '' }

    return @"
`$ErrorActionPreference = 'Continue'
try {
    `$dlDir = 'C:\rs-pkgs'
    New-Item -Path `$dlDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    `$bootstrapPath = Join-Path `$dlDir 'ssm_install.ps1'
    `$bootstrapLog  = Join-Path `$dlDir 'agent_bootstrap.log'
    `$bsStdout      = Join-Path `$dlDir 'bootstrap-stdout.log'
    `$bsStderr      = Join-Path `$dlDir 'bootstrap-stderr.log'
    Remove-Item `$bootstrapLog, `$bsStdout, `$bsStderr -Force -ErrorAction SilentlyContinue

$dlFragment
$localFallbackBlock

    if (-not `$dlSuccess) {
        Write-Output 'ERROR:No bootstrap.ps1 available'
        Write-Output 'ERROR:Ensure VM can reach https://add-ons.manage.rackspace.com'
        Write-Output 'BOOTSTRAP_EXITCODE:126'
        return
    }

$PreBootstrap

    Write-Output 'ACTION:Running bootstrap.ps1 -Command $Command'
    Set-Location `$dlDir
    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Run bootstrap in a child powershell.exe process. This isolates bootstrap's
    # `$ErrorActionPreference = 'Stop' from our wrapper, and lets us capture its
    # verbose DEBUG output to a file (rather than flooding Run Command stdout,
    # which is capped at ~4KB and would otherwise evict our sentinels below).
    `$p = Start-Process powershell.exe -ArgumentList $bsArgsLiteral ``
        -WorkingDirectory `$dlDir ``
        -RedirectStandardOutput `$bsStdout -RedirectStandardError `$bsStderr ``
        -NoNewWindow -Wait -PassThru
    `$sw.Stop()

    # Emit the long-form content FIRST (log, stdout/stderr tails) and the
    # critical sentinels LAST. Azure Run Command stdout is capped at ~4KB and
    # truncates from the FRONT of the buffer when the cap is hit, so the
    # exit-code marker must be one of the final lines we write.
    if (Test-Path `$bootstrapLog) {
        Write-Output 'BOOTSTRAP_LOG_START'
        Get-Content `$bootstrapLog -Raw | Write-Output
        Write-Output 'BOOTSTRAP_LOG_END'
    }
    if ((Test-Path `$bsStderr) -and (Get-Item `$bsStderr).Length -gt 0) {
        Write-Output 'BOOTSTRAP_STDERR_START'
        Get-Content `$bsStderr -Tail 20 | Write-Output
        Write-Output 'BOOTSTRAP_STDERR_END'
    }
    if (Test-Path `$bsStdout) {
        Write-Output 'BOOTSTRAP_STDOUT_TAIL_START'
        Get-Content `$bsStdout -Tail 20 | Write-Output
        Write-Output 'BOOTSTRAP_STDOUT_TAIL_END'
    }
    Write-Output "BOOTSTRAP_DURATION:`$([math]::Round(`$sw.Elapsed.TotalSeconds,1))"
    Write-Output "BOOTSTRAP_EXITCODE:`$(`$p.ExitCode)"

    # --- Path workaround: if bootstrap exit 100 (Failed to install 'Amazon SSM
    # Agent'), the bootstrap likely ran AmazonSSMAgentSetup.exe from the deep
    # SYSTEM temp path (%SYSTEMPROFILE%\AppData\Local\Temp\ssm\). On Windows
    # Server 2025 this path causes the NSIS self-extracting stub to abort with
    # 0x80004005. Running the same .exe from a shorter path (C:\rs-pkgs) works.
    # Copy the already-downloaded .exe there and run with /S directly.
    if (`$p.ExitCode -eq 100 -and '$Command' -in @('Install','Reinstall')) {
        `$tempExe = Join-Path ([System.Environment]::GetEnvironmentVariable('TEMP','User')) 'ssm\AmazonSSMAgentSetup.exe'
        `$localExe = Join-Path `$dlDir 'AmazonSSMAgentSetup.exe'
        if ((Test-Path `$tempExe) -and (Get-Item `$tempExe).Length -gt 1000000) {
            Write-Output 'ACTION:Bootstrap exit 100 - running installer directly from C:\rs-pkgs'
            Copy-Item `$tempExe `$localExe -Force
            `$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            `$p2 = Start-Process -FilePath `$localExe -ArgumentList '/S' -WorkingDirectory `$dlDir -Wait -PassThru -NoNewWindow
            `$sw2.Stop()
            Write-Output "ACTION:Direct installer exit: `$(`$p2.ExitCode) (duration: `$([math]::Round(`$sw2.Elapsed.TotalSeconds,1))s)"
            if (`$p2.ExitCode -eq 0) {
                Write-Output 'OK:SSM Agent installed directly from C:\rs-pkgs'
                # Override the bootstrap exit code so the caller sees success
                Write-Output 'BOOTSTRAP_EXITCODE_OVERRIDE:0'
            } else {
                Write-Output "WARN:Direct installer also failed (exit `$(`$p2.ExitCode))"
            }
        }
    }
} catch {
    Write-Output "ERROR:`$(`$_.Exception.Message)"
    Write-Output 'BOOTSTRAP_EXITCODE:144'
}
"@
}

function Parse-BootstrapOutput {
    <#
    .SYNOPSIS
        Parses the output of a wrapped bootstrap.ps1 / bootstrap.py invocation and
        returns a New-SSMBootstrapResult populated with exit code, activation HTTP
        status (when present), and key log lines.
    .DESCRIPTION
        Looks for the following markers (all optional):
            BOOTSTRAP_EXITCODE:<int>
            BOOTSTRAP_LOG_START          ...  BOOTSTRAP_LOG_END           (full agent_bootstrap.log)
            BOOTSTRAP_STDOUT_TAIL_START  ...  BOOTSTRAP_STDOUT_TAIL_END   (last 40 lines)
            BOOTSTRAP_STDERR_START       ...  BOOTSTRAP_STDERR_END        (last 20 lines)
            POST request to activation url <URL> failed: The remote server returned an error: (NNN)
        Works on both Windows (here-string) and Linux (bash) wrappers because
        the marker strings are identical.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter()][string]$Output,
        [Parameter()][string]$DurationSeconds
    )

    if (-not $Output) {
        return New-SSMBootstrapResult -Command $Command -DurationSeconds $DurationSeconds
    }

    $exit = $null
    if ($Output -match 'BOOTSTRAP_EXITCODE:\s*(-?\d+)') {
        $exit = [int]$Matches[1]
    }

    # If the HVCI workaround succeeded, the wrapper emits an override sentinel.
    # Use it instead of the original bootstrap exit code.
    if ($Output -match 'BOOTSTRAP_EXITCODE_OVERRIDE:\s*(-?\d+)') {
        $exit = [int]$Matches[1]
    }

    $actUrl = $null
    $actStatus = $null
    if ($Output -match 'POST request to activation url\s+(\S+)\s+failed:.*\((\d{3})\)') {
        $actUrl    = $Matches[1].TrimEnd('.')
        $actStatus = [int]$Matches[2]
    }

    # Extract content inside each marker pair. When Azure Run Command truncates
    # stdout from the front (~4KB cap), the *_START marker may be missing while
    # the *_END marker still exists. Handle both.
    $logLines = @()
    if ($Output -match '(?s)BOOTSTRAP_LOG_START\s*\n(.+?)\n\s*BOOTSTRAP_LOG_END') {
        $logLines = ($Matches[1] -split "`r?`n") | Where-Object { $_ -and $_.Trim() }
    } elseif ($Output -match '(?s)(.+?)\n\s*BOOTSTRAP_LOG_END') {
        # No START marker (truncated). Take everything above END back to the
        # previous known sentinel boundary.
        $tail = $Matches[1]
        if ($tail -match '(?s)(BOOTSTRAP_STDERR_END|BOOTSTRAP_STDOUT_TAIL_END)\s*\n(.+)$') {
            $tail = $Matches[2]
        }
        $logLines = ($tail -split "`r?`n") | Where-Object { $_ -and $_.Trim() }
    }
    $stdoutTail = @()
    if ($Output -match '(?s)BOOTSTRAP_STDOUT_TAIL_START\s*\n(.+?)\n\s*BOOTSTRAP_STDOUT_TAIL_END') {
        $stdoutTail = ($Matches[1] -split "`r?`n") | Where-Object { $_ -and $_.Trim() }
    }
    $stderrLines = @()
    if ($Output -match '(?s)BOOTSTRAP_STDERR_START\s*\n(.+?)\n\s*BOOTSTRAP_STDERR_END') {
        $stderrLines = ($Matches[1] -split "`r?`n") | Where-Object { $_ -and $_.Trim() }
    }

    # If we didn't find the activation-failure line in the main output, also
    # check the bootstrap log (more reliable since the log isn't subject to
    # Run Command's stdout truncation path in the same way).
    if (-not $actStatus -and $logLines.Count -gt 0) {
        $logJoined = $logLines -join "`n"
        if ($logJoined -match 'POST request to activation url\s+(\S+)\s+failed:.*\((\d{3})\)') {
            $actUrl    = $Matches[1].TrimEnd('.')
            $actStatus = [int]$Matches[2]
        }
    }

    $result = New-SSMBootstrapResult `
        -Command $Command `
        -ExitCode $exit `
        -ActivationUrl $actUrl `
        -ActivationHttpStatus $actStatus `
        -LogLines $logLines `
        -DurationSeconds $DurationSeconds

    # Attach non-schema extras for callers that want them
    $result | Add-Member -NotePropertyName StdoutTail -NotePropertyValue $stdoutTail -Force
    $result | Add-Member -NotePropertyName StderrLines -NotePropertyValue $stderrLines -Force
    return $result
}

function Write-BootstrapResult {
    <#
    .SYNOPSIS  Pretty-prints a New-SSMBootstrapResult to the console (skipped in JSON mode).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result
    )
    if ($script:SuppressConsole) { return }
    if ($null -ne $Result.ExitCode) {
        $color = if ($Result.ExitCode -eq 0) { 'Green' } else { 'Red' }
        Write-Host "  Bootstrap exit code : $($Result.ExitCode) ($($Result.ExitCodeMessage))" -ForegroundColor $color
    }
    if ($Result.ActivationHttpStatus) {
        Write-Host "  Activation HTTP     : $($Result.ActivationHttpStatus) at $($Result.ActivationUrl)" -ForegroundColor Yellow
    }
    if ($Result.DurationSeconds) {
        Write-Host "  Bootstrap elapsed   : $($Result.DurationSeconds)s" -ForegroundColor DarkGray
    }

    # Show bootstrap log lines in Verbose mode
    if ($VerbosePreference -ne 'SilentlyContinue' -and $Result.LogLines -and $Result.LogLines.Count -gt 0) {
        Write-Host ""
        Write-Host "  Bootstrap Log (Verbose):" -ForegroundColor DarkGray
        Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
        foreach ($line in $Result.LogLines) {
            $color = 'DarkGray'
            if ($line -match 'ERROR|FAIL|WARN') { $color = 'Yellow' }
            if ($line -match 'registered successfully|SUCCEEDED') { $color = 'Green' }
            Write-Host "  $line" -ForegroundColor $color
        }
        Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
    }
}

function Get-DiagScript {
    param([string]$OsType)

    if ($OsType -eq 'Linux') {
        return @'
#!/bin/bash
# Output JSON diagnostics for the SSM agent on Linux
svc_status="unknown"
start_type="unknown"
agent_ver="NOT_FOUND"
reg_exists="false"
reg_age="-1"
detected_region=""
fp_exists="false"
cli_exists="false"
instance_id="N/A"

# Service status
if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    svc_status="Running"
    start_type=$(systemctl is-enabled amazon-ssm-agent 2>/dev/null || echo "unknown")
elif service amazon-ssm-agent status 2>/dev/null | grep -q "running"; then
    svc_status="Running"
    start_type="unknown"
elif command -v amazon-ssm-agent &>/dev/null || [ -f /usr/bin/amazon-ssm-agent ] || dpkg -l amazon-ssm-agent 2>/dev/null | grep -q '^ii' || rpm -q amazon-ssm-agent &>/dev/null; then
    svc_status=$(systemctl is-active amazon-ssm-agent 2>/dev/null || echo "inactive")
    start_type=$(systemctl is-enabled amazon-ssm-agent 2>/dev/null || echo "unknown")
else
    svc_status="NOT_INSTALLED"
    start_type="N/A"
fi

# Agent version
if command -v amazon-ssm-agent &>/dev/null; then
    agent_ver=$(amazon-ssm-agent --version 2>/dev/null | head -1)
    agent_ver="${agent_ver:-unknown}"
elif [ -f /usr/bin/amazon-ssm-agent ]; then
    agent_ver=$(/usr/bin/amazon-ssm-agent --version 2>/dev/null | head -1)
    agent_ver="${agent_ver:-unknown}"
fi

# Registration file
reg_file="/var/lib/amazon/ssm/registration"
if [ -f "$reg_file" ]; then
    reg_exists="true"
    reg_age=$(( ($(date +%s) - $(stat -c %Y "$reg_file" 2>/dev/null || echo 0)) / 86400 ))
    detected_region=$(grep -oP '"[Rr]egion"\s*:\s*"\K[a-z]{2}-[a-z]+-[0-9]+' "$reg_file" 2>/dev/null | head -1)
fi

# Fingerprint
fp_file="/var/lib/amazon/ssm/Vault/Store/RegistrationKey"
[ -f "$fp_file" ] && fp_exists="true"

# ssm-cli instance info
ssm_cli=""
command -v ssm-cli &>/dev/null && ssm_cli="ssm-cli"
[ -z "$ssm_cli" ] && [ -x /usr/bin/ssm-cli ] && ssm_cli="/usr/bin/ssm-cli"

if [ -n "$ssm_cli" ]; then
    cli_exists="true"
    info_raw=$($ssm_cli get-instance-information 2>&1)
    instance_id=$(echo "$info_raw" | grep -oP '"instance-id"\s*:\s*"\K(mi-[a-f0-9]+)' | head -1)
    [ -z "$instance_id" ] && instance_id=$(echo "$info_raw" | grep -oP '"InstanceId"\s*:\s*"\K(mi-[a-f0-9]+)' | head -1)
    [ -z "$instance_id" ] && instance_id="MISSING"
    av=$(echo "$info_raw" | grep -oP '"agent-version"\s*:\s*"\K[^"]+' | head -1)
    [ -z "$av" ] && av=$(echo "$info_raw" | grep -oP '"release-version"\s*:\s*"\K[^"]+' | head -1)
    [ -n "$av" ] && agent_ver="$av"
fi

cat <<EOF
{
  "ServiceStatus": "$svc_status",
  "StartType": "$start_type",
  "AgentVersion": "$agent_ver",
  "RegistrationExists": $reg_exists,
  "RegistrationAgeDays": $reg_age,
  "DetectedRegion": "$detected_region",
  "FingerprintExists": $fp_exists,
  "SsmCliExists": $cli_exists,
  "InstanceId": "$instance_id"
}
EOF
'@
    } else {
        return @'
$out = @{}
$svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
if ($svc) {
    $out['ServiceStatus'] = $svc.Status.ToString()
    $out['StartType'] = $svc.StartType.ToString()
} else {
    $out['ServiceStatus'] = 'NOT_INSTALLED'
    $out['StartType'] = 'N/A'
}

# AgentVersion resolution: AWS's installer populates FileVersion but not always
# ProductVersion, and ssm-cli get-instance-information returns nothing when the
# agent can't assume an identity. Try multiple sources in order of reliability:
#   1. Version string inside agent_bootstrap.log (if bootstrap ran here)
#   2. ssm-cli get-instance-information (works only when registered)
#   3. amazon-ssm-agent.log "OS:Windows AmazonSSM/<version>" banner line
#   4. File ProductVersion then FileVersion
#   5. Registry uninstall key
$out['AgentVersion'] = $null
$agentExe = "C:\Program Files\Amazon\SSM\amazon-ssm-agent.exe"
$out['AgentExeExists'] = Test-Path $agentExe

if ($out['AgentExeExists']) {
    try {
        $vi = (Get-Item $agentExe).VersionInfo
        if ($vi.ProductVersion) { $out['AgentVersion'] = $vi.ProductVersion.Trim() }
        elseif ($vi.FileVersion) { $out['AgentVersion'] = $vi.FileVersion.Trim() }
    } catch {}
}

if (-not $out['AgentVersion']) {
    # Try to parse from the agent's own log (startup banner includes version)
    $log = "$env:ProgramData\Amazon\SSM\Logs\amazon-ssm-agent.log"
    if (Test-Path $log) {
        $match = Select-String -Path $log -Pattern 'amazon-ssm-agent\s+v([\d.]+)' -AllMatches -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($match) { $out['AgentVersion'] = $match.Matches[0].Groups[1].Value }
    }
}

if (-not $out['AgentVersion']) {
    # Last resort: registry uninstall key
    $uninstall = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -eq 'Amazon SSM Agent' } | Select-Object -First 1
    if ($uninstall -and $uninstall.DisplayVersion) { $out['AgentVersion'] = $uninstall.DisplayVersion }
}

if (-not $out['AgentVersion']) { $out['AgentVersion'] = 'NOT_FOUND' }

$regFile = "$env:ProgramData\Amazon\SSM\InstanceData\registration"
if (Test-Path $regFile) {
    $out['RegistrationExists'] = $true
    $regAge = (Get-Date) - (Get-Item $regFile).LastWriteTime
    $out['RegistrationAgeDays'] = [math]::Round($regAge.TotalDays, 1)
    try {
        $regJson = Get-Content $regFile -Raw | ConvertFrom-Json
        if ($regJson.Region) { $out['DetectedRegion'] = $regJson.Region }
    } catch {
        $regContent = Get-Content $regFile -Raw
        if ($regContent -match '"[Rr]egion"\s*:\s*"([a-z]{2}-[a-z]+-\d+)"') {
            $out['DetectedRegion'] = $Matches[1]
        }
    }
} else {
    $out['RegistrationExists'] = $false
    $out['RegistrationAgeDays'] = -1
}
$fpFile = "$env:ProgramData\Amazon\SSM\InstanceData\Vault\Store\RegistrationKey"
$out['FingerprintExists'] = Test-Path $fpFile
$ssmCli = "C:\Program Files\Amazon\SSM\ssm-cli.exe"
if (Test-Path $ssmCli) {
    $out['SsmCliExists'] = $true
    try {
        $infoRaw = & $ssmCli get-instance-information 2>&1 | Out-String
        if ($infoRaw -match '"instance-id"\s*:\s*"(mi-[a-f0-9]+)"') { $out['InstanceId'] = $Matches[1] }
        elseif ($infoRaw -match '"InstanceId"\s*:\s*"(mi-[a-f0-9]+)"') { $out['InstanceId'] = $Matches[1] }
        else { $out['InstanceId'] = 'MISSING' }
        # If ssm-cli returns a version and we don't have one yet, use it
        if ($infoRaw -match '"release-version"\s*:\s*"([^"]+)"' -and $out['AgentVersion'] -eq 'NOT_FOUND') { $out['AgentVersion'] = $Matches[1] }
        elseif ($infoRaw -match '"agent-version"\s*:\s*"([^"]+)"' -and $out['AgentVersion'] -eq 'NOT_FOUND') { $out['AgentVersion'] = $Matches[1] }
    } catch { $out['InstanceId'] = 'ERROR' }
} else {
    $out['SsmCliExists'] = $false
    $out['InstanceId'] = 'N/A'
}
$out | ConvertTo-Json -Depth 2
'@
    }
}

function Get-PreflightScript {
    <#
    .SYNOPSIS
        Returns an OS-specific script that probes Run Command responsiveness
        and detects pending-reboot conditions in a single round trip.
    .DESCRIPTION
        Two preflight signals are surfaced:
          1. RC_OK — proves the Azure VM agent and Run Command pipeline are
             alive end-to-end. If we can't get this back inside a short
             timeout, no later remediation step has a chance.
          2. PENDING_REBOOT — flags conditions that wedge MSI (Windows) or
             require a reboot to apply (Linux). These are common causes of
             SSM Agent install failures: the Windows Installer engine can
             hang or fail with E_FAIL when CBS/Windows Update has a reboot
             pending, and a stale PendingFileRenameOperations queue can
             produce 0x80004005 with no MSI log.

        Output is line-prefixed sentinels ("RC_OK:", "PENDING_REBOOT:",
        "REBOOT_REASON:") so the caller can parse without depending on
        formatting.
    #>
    param([string]$OsType)

    if ($OsType -eq 'Linux') {
        return @'
#!/bin/bash
echo "RC_OK:$(hostname)"

pending=false
reasons=""

# /var/run/reboot-required (Debian/Ubuntu)
if [ -f /var/run/reboot-required ]; then
    pending=true
    reasons="$reasons reboot-required-flag"
fi

# needs-restarting (RHEL/CentOS via yum-utils)
if command -v needs-restarting &>/dev/null; then
    if needs-restarting -r 2>&1 | grep -qi "Reboot is required"; then
        pending=true
        reasons="$reasons dnf-needs-restarting"
    fi
fi

# Kernel mismatch (running kernel != newest installed kernel)
running_kernel=$(uname -r)
if command -v rpm &>/dev/null; then
    newest_kernel=$(rpm -q --last kernel 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-//')
    if [ -n "$newest_kernel" ] && [ "$running_kernel" != "$newest_kernel" ]; then
        pending=true
        reasons="$reasons kernel-mismatch($running_kernel<$newest_kernel)"
    fi
elif command -v dpkg &>/dev/null; then
    newest_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ && $2 ~ /linux-image-[0-9]/ {print $2}' | sed 's/linux-image-//' | sort -V | tail -1)
    if [ -n "$newest_kernel" ] && [ "$running_kernel" != "$newest_kernel" ]; then
        pending=true
        reasons="$reasons kernel-mismatch($running_kernel<$newest_kernel)"
    fi
fi

if [ "$pending" = true ]; then
    echo "PENDING_REBOOT:true"
    for r in $reasons; do echo "REBOOT_REASON:$r"; done
else
    echo "PENDING_REBOOT:false"
fi
'@
    } else {
        return @'
Write-Output "RC_OK:$env:COMPUTERNAME"

$reasons = @()

# Component Based Servicing - servicing stack pending
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $reasons += 'CBS-RebootPending'
}

# Windows Update pending
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $reasons += 'WindowsUpdate-RebootRequired'
}

# PendingFileRenameOperations - blocks MSI installs of files that are queued for rename
$pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pfro) {
    $reasons += "PendingFileRenameOperations($($pfro.Count))"
}

# Pending computer rename
$active  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'  -ErrorAction SilentlyContinue).ComputerName
$pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'        -ErrorAction SilentlyContinue).ComputerName
if ($active -and $pending -and ($active -ne $pending)) {
    $reasons += "ComputerRename($active->$pending)"
}

# An "InProgress" install lock from a previously interrupted install also wedges MSI
if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress' -ErrorAction SilentlyContinue) {
    $reasons += 'MSI-InstallInProgress'
}

# SCCM Configuration Manager client (if present) reboot pending
$sccm = $null
try {
    $sccm = ([wmiclass]'\\.\root\ccm\ClientSDK:CCM_ClientUtilities').DetermineIfRebootPending()
} catch {}
if ($sccm -and $sccm.RebootPending) {
    $reasons += 'SCCM-RebootPending'
}

if ($reasons.Count -gt 0) {
    Write-Output "PENDING_REBOOT:true"
    foreach ($r in $reasons) { Write-Output "REBOOT_REASON:$r" }
} else {
    Write-Output "PENDING_REBOOT:false"
}
'@
    }
}

function Invoke-SSMPreflight {
    <#
    .SYNOPSIS
        Runs the preflight probe and returns a New-SSMPreflightResult.
    .DESCRIPTION
        Single round-trip Run Command that:
          - Confirms Run Command + Azure VM agent are alive and producing output
          - Reports the VM hostname (proves we reached the right VM)
          - Surfaces any pending-reboot conditions on the VM

        Uses a deliberately short Run Command timeout (60s default) so that an
        unresponsive Azure VM agent fails fast here rather than burning the
        full remediation timeout later.
    #>
    param(
        [string]$RG,
        [string]$VM,
        [string]$Location,
        [string]$OsType,
        [int]$Timeout = 60
    )

    $script = Get-PreflightScript -OsType $OsType

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Location -Script $script -OsType $OsType -Timeout $Timeout -Label 'Preflight (Run Command + reboot probe)'
    $sw.Stop()
    $duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($null -eq $out -or [string]::IsNullOrWhiteSpace($out)) {
        return (New-SSMPreflightResult -Status 'RUN_COMMAND_FAILED' -DurationSeconds $duration `
            -Message "Preflight Run Command did not return output within ${Timeout}s. The Azure VM agent or Run Command extension is unresponsive.")
    }

    $hostname = $null
    $pending  = $false
    $reasons  = @()
    foreach ($line in ($out -split "`r?`n")) {
        $line = $line.Trim()
        if     ($line -match '^RC_OK:(.+)$')          { $hostname = $Matches[1].Trim() }
        elseif ($line -match '^PENDING_REBOOT:true$') { $pending  = $true }
        elseif ($line -match '^REBOOT_REASON:(.+)$')  { $reasons += $Matches[1].Trim() }
    }

    if (-not $hostname) {
        return (New-SSMPreflightResult -Status 'RUN_COMMAND_FAILED' -DurationSeconds $duration `
            -Message "Preflight Run Command returned output but no RC_OK sentinel - the VM may be in a degraded state.")
    }

    return (New-SSMPreflightResult -Status 'OK' -Hostname $hostname -DurationSeconds $duration `
        -PendingReboot $pending -PendingRebootReasons $reasons `
        -Message $(if ($pending) { "Pending reboot detected: $($reasons -join ', ')" } else { "Run Command healthy; no pending reboot" }))
}

function Get-LogScript {
    param([string]$OsType)

    if ($OsType -eq 'Linux') {
        return @'
#!/bin/bash
# Rackspace endpoint connectivity
echo ">>> Rackspace Endpoint Connectivity:"
for ep in add-ons.api.manage.rackspace.com add-ons.manage.rackspace.com; do
    dns_ok=false
    port_ok=false
    if host "$ep" &>/dev/null || getent hosts "$ep" &>/dev/null; then
        dns_ok=true
    fi
    if timeout 5 bash -c "echo >/dev/tcp/$ep/443" 2>/dev/null; then
        port_ok=true
    elif nc -z -w5 "$ep" 443 2>/dev/null; then
        port_ok=true
    fi
    if [ "$dns_ok" = true ] && [ "$port_ok" = true ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    echo "ENDPOINT:${ep}|${status}|DNS=${dns_ok}|443=${port_ok}"
done

# Proxy configuration
for f in /etc/environment /etc/profile.d/proxy.sh; do
    if [ -f "$f" ]; then
        proxy_lines=$(grep -iE 'http_proxy|https_proxy|no_proxy' "$f" 2>/dev/null)
        if [ -n "$proxy_lines" ]; then
            echo "PROXY:$f: $proxy_lines"
        fi
    fi
done
# SSM agent environment override
ssm_env=$(systemctl show amazon-ssm-agent --property=Environment 2>/dev/null)
if [ -n "$ssm_env" ] && [ "$ssm_env" != "Environment=" ]; then
    echo "PROXY:systemd env: $ssm_env"
fi

# Error log
err_log="/var/log/amazon/ssm/errors.log"
if [ -f "$err_log" ]; then
    echo ">>> errors.log (last 15 lines):"
    tail -15 "$err_log"
fi

# Agent log
main_log="/var/log/amazon/ssm/amazon-ssm-agent.log"
if [ -f "$main_log" ]; then
    echo ">>> amazon-ssm-agent.log (last 15 lines):"
    tail -15 "$main_log"
fi

# SSM CLI diagnostics
ssm_cli=""
if command -v ssm-cli &>/dev/null; then
    ssm_cli="ssm-cli"
elif [ -x /usr/bin/ssm-cli ]; then
    ssm_cli="/usr/bin/ssm-cli"
fi
if [ -n "$ssm_cli" ]; then
    echo ">>> ssm-cli get-diagnostics:"
    $ssm_cli get-diagnostics --output json 2>/dev/null || echo "ERROR: ssm-cli diagnostics failed"
fi
'@
    } else {
        return @'
$lines = @()

# Rackspace endpoint connectivity (not covered by ssm-cli diagnostics)
$raxEndpoints = @('add-ons.api.manage.rackspace.com', 'add-ons.manage.rackspace.com')
$lines += '>>> Rackspace Endpoint Connectivity:'
foreach ($ep in $raxEndpoints) {
    $dnsOk = $false; $portOk = $false
    try { [System.Net.Dns]::GetHostAddresses($ep) | Out-Null; $dnsOk = $true } catch {}
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.ConnectAsync($ep, 443)
        if ($async.Wait(5000)) { $portOk = $tcp.Connected }
        $tcp.Dispose()
    } catch {}
    $status = if ($dnsOk -and $portOk) { 'PASS' } else { 'FAIL' }
    $lines += "ENDPOINT:$ep|$status|DNS=$dnsOk|443=$portOk"
}

# Proxy configuration
$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\AmazonSSMAgent'
if (Test-Path $svcKey) {
    $envVars = (Get-Item -Path $svcKey -ErrorAction SilentlyContinue).GetValue('Environment')
    if ($envVars) { $lines += "PROXY:SSM Service Env: $($envVars -join '; ')" }
}

# Error log
$errLog = "$env:ProgramData\Amazon\SSM\Logs\errors.log"
if (Test-Path $errLog) {
    $lines += '>>> errors.log (last 15 lines):'
    Get-Content $errLog -Tail 15 | ForEach-Object { $lines += $_ }
}

# Agent log
$mainLog = "$env:ProgramData\Amazon\SSM\Logs\amazon-ssm-agent.log"
if (Test-Path $mainLog) {
    $lines += '>>> amazon-ssm-agent.log (last 15 lines):'
    Get-Content $mainLog -Tail 15 | ForEach-Object { $lines += $_ }
}

# SSM CLI diagnostics
$ssmCli = "C:\Program Files\Amazon\SSM\ssm-cli.exe"
if (Test-Path $ssmCli) {
    $lines += '>>> ssm-cli get-diagnostics:'
    try {
        $diagOut = & $ssmCli get-diagnostics --output json 2>$null | Out-String
        $lines += $diagOut
    } catch {
        $lines += "ERROR: $($_.Exception.Message)"
    }
}
$lines -join "`n"
'@
    }
}

function Get-FixStartupScript {
    param([string]$OsType)

    if ($OsType -eq 'Linux') {
        return @'
#!/bin/bash
if systemctl is-enabled amazon-ssm-agent 2>/dev/null | grep -qv "enabled"; then
    systemctl enable amazon-ssm-agent 2>/dev/null && echo "FIXED" || echo "FAILED"
else
    echo "FIXED"
fi
'@
    } else {
        return 'Set-Service -Name "AmazonSSMAgent" -StartupType Automatic; Write-Output "FIXED"'
    }
}

function Get-RestartScript {
    param([string]$OsType)

    if ($OsType -eq 'Linux') {
        return @'
#!/bin/bash
# Enable on boot if not already
if ! systemctl is-enabled amazon-ssm-agent &>/dev/null; then
    systemctl enable amazon-ssm-agent 2>/dev/null
    echo "FIX:Enabled amazon-ssm-agent on boot"
fi

status=$(systemctl is-active amazon-ssm-agent 2>/dev/null || echo "inactive")

if [ "$status" = "activating" ]; then
    echo "STATUS:Service stuck in activating state - force killing"
    pids=$(pgrep -f 'amazon-ssm-agent' 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    sleep 3
fi

if [ "$status" = "active" ]; then
    systemctl restart amazon-ssm-agent 2>/dev/null
else
    systemctl start amazon-ssm-agent 2>/dev/null
fi

sleep 10
new_status=$(systemctl is-active amazon-ssm-agent 2>/dev/null || echo "unknown")
echo "RESULT:${new_status}"
'@
    } else {
        return @'
try {
    $svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction Stop

    # Fix startup type if Manual
    if ($svc.StartType -ne 'Automatic') {
        Set-Service -Name 'AmazonSSMAgent' -StartupType Automatic
        Write-Output "FIX:Changed startup type from $($svc.StartType) to Automatic"
    }

    if ($svc.Status -eq 'StartPending') {
        Write-Output 'STATUS:StartPending - killing stuck process'
        Set-Service -Name 'AmazonSSMAgent' -StartupType Manual
        Get-Process -Name 'amazon-ssm-agent' -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Get-Process -Name 'ssm-agent-worker' -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
    }
    if ($svc.Status -eq 'Running') {
        Restart-Service -Name 'AmazonSSMAgent' -Force -ErrorAction Stop
    } else {
        Set-Service -Name 'AmazonSSMAgent' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'AmazonSSMAgent' -ErrorAction Stop
    }
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name 'AmazonSSMAgent'
    Write-Output "RESULT:$($svc.Status)"
} catch {
    Write-Output "ERROR:$($_.Exception.Message)"
}
'@
    }
}

function Get-ReregisterScript {
    param(
        [string]$OsType,
        [string]$PlatformName,
        [string]$ProxyUrl
    )

    if ($OsType -eq 'Linux') {
        $proxyEnv = if ($ProxyUrl) { "export http_proxy='$ProxyUrl'; export https_proxy='$ProxyUrl'; " } else { "" }
        $proxyArg = if ($ProxyUrl) { " --http-proxy '$ProxyUrl'" } else { "" }
        $platformLower = $PlatformName.ToLower()

        return @"
#!/bin/bash
set -e
trap 'echo "ERROR:`$BASH_COMMAND failed"' ERR

bootstrap_path=""
dl_path="/tmp/bootstrap.py"

echo "ACTION:Downloading fresh bootstrap.py"
dl_success=false
for attempt in 1 2 3; do
    ${proxyEnv}wget -q -O "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || curl -sfSL -o "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || true
    if [ -s "`$dl_path" ]; then
        dl_success=true
        break
    fi
    echo "WARN:Download attempt `$attempt failed"
    [ "`$attempt" -lt 3 ] && sleep `$((5 * attempt))
done

if [ "`$dl_success" = true ]; then
    bootstrap_path="`$dl_path"
    echo "OK:Downloaded bootstrap.py"
else
    for p in /tmp/bootstrap.py /opt/rackspace/bootstrap.py; do
        if [ -s "`$p" ]; then
            bootstrap_path="`$p"
            echo "WARN:Using local fallback `$p"
            break
        fi
    done
fi

if [ -z "`$bootstrap_path" ]; then
    echo "ERROR:No bootstrap.py available - cannot re-register"
    echo "ERROR:Without bootstrap.py, re-activation through Platform Services API is not possible"
    echo "ERROR:Ensure VM can reach https://add-ons.manage.rackspace.com or escalate to #passport-escalations"
    exit 1
fi

echo "ACTION:Running bootstrap.py reregister"
python3 "`$bootstrap_path" reregister -p ${platformLower}${proxyArg} 2>&1 || \
    python "`$bootstrap_path" reregister -p ${platformLower}${proxyArg} 2>&1 || \
    echo "ERROR:bootstrap.py reregister failed"
"@
    } else {
        return Get-WindowsBootstrapWrapper -Command 'Reregister' -PlatformName $PlatformName -ProxyUrl $ProxyUrl -UseLocalFallback
    }
}

function Get-InstallScript {
    <#
    .SYNOPSIS
        Returns an OS-specific script that performs a clean install of the SSM agent.
    .DESCRIPTION
        Windows: Downloads AmazonSSMAgentSetup.exe directly to C:\rs-pkgs and runs
        it with /S from there (avoids the known Server 2025 issue where running from
        the deep SYSTEM temp path causes the NSIS stub to abort with 0x80004005).
        Then downloads and runs the Rackspace bootstrap with -Command Install which
        detects the agent is already present, writes the config, registers with
        Platform Services, and starts the service.

        Linux: Downloads and runs bootstrap.py install directly (no path issues).
    #>
    param(
        [string]$OsType,
        [string]$PlatformName,
        [string]$ProxyUrl
    )

    if ($OsType -eq 'Linux') {
        $proxyEnv = if ($ProxyUrl) { "export http_proxy='$ProxyUrl'; export https_proxy='$ProxyUrl'; " } else { "" }
        $proxyArg = if ($ProxyUrl) { " --http-proxy '$ProxyUrl'" } else { "" }
        $platformLower = $PlatformName.ToLower()

        return @"
#!/bin/bash
set -e
trap 'echo "ERROR:`$BASH_COMMAND failed"' ERR

dl_path="/tmp/bootstrap.py"

echo "ACTION:Downloading bootstrap.py"
dl_success=false
for attempt in 1 2 3; do
    ${proxyEnv}wget -q -O "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || curl -sfSL -o "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || true
    if [ -s "`$dl_path" ]; then
        dl_success=true
        break
    fi
    echo "WARN:Download attempt `$attempt failed"
    [ "`$attempt" -lt 3 ] && sleep `$((5 * attempt))
done

if [ "`$dl_success" != true ]; then
    echo "ERROR:Failed to download bootstrap.py"
    echo "ERROR:Ensure VM can reach https://add-ons.manage.rackspace.com"
    exit 1
fi

echo "OK:Downloaded bootstrap.py"
echo "ACTION:Running bootstrap.py install"
python3 "`$dl_path" install -p ${platformLower}${proxyArg} 2>&1 || \
    python "`$dl_path" install -p ${platformLower}${proxyArg} 2>&1 || \
    echo "ERROR:bootstrap.py install failed"
"@
    } else {
        # Windows: direct install + bootstrap registration in one script.
        $proxyArg = if ($ProxyUrl) { " -HttpProxy '$ProxyUrl'" } else { "" }
        return @"
`$ErrorActionPreference = 'Continue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    `$dlDir = 'C:\rs-pkgs'
    New-Item -Path `$dlDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    `$setupExe      = Join-Path `$dlDir 'AmazonSSMAgentSetup.exe'
    `$bootstrapPath = Join-Path `$dlDir 'ssm_install.ps1'
    `$bootstrapLog  = Join-Path `$dlDir 'agent_bootstrap.log'
    Remove-Item `$bootstrapLog -Force -ErrorAction SilentlyContinue

    # --- Step 1: Download the installer ---
    `$setupUrl = 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe'
    Write-Output "ACTION:Downloading AmazonSSMAgentSetup.exe to `$dlDir"
    `$dlSuccess = `$false

    # Try curl.exe first (most reliable on Server 2025)
    `$curl = Join-Path `$env:SystemRoot 'System32\curl.exe'
    if (Test-Path `$curl) {
        & `$curl -sSfL --max-time 120 -o `$setupExe `$setupUrl 2>&1 | Out-Null
        if ((Test-Path `$setupExe) -and (Get-Item `$setupExe).Length -gt 1000000) {
            `$dlSuccess = `$true
            Write-Output "OK:Downloaded via curl (`$((Get-Item `$setupExe).Length) bytes)"
        }
    }

    if (-not `$dlSuccess) {
        try {
            Invoke-WebRequest -Uri `$setupUrl -OutFile `$setupExe -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            if ((Test-Path `$setupExe) -and (Get-Item `$setupExe).Length -gt 1000000) {
                `$dlSuccess = `$true
                Write-Output "OK:Downloaded via Invoke-WebRequest (`$((Get-Item `$setupExe).Length) bytes)"
            }
        } catch {
            Write-Output "WARN:Invoke-WebRequest failed - `$(`$_.Exception.Message)"
        }
    }

    if (-not `$dlSuccess) {
        try {
            `$wc = New-Object System.Net.WebClient
            `$wc.DownloadFile(`$setupUrl, `$setupExe)
            `$wc.Dispose()
            if ((Test-Path `$setupExe) -and (Get-Item `$setupExe).Length -gt 1000000) {
                `$dlSuccess = `$true
                Write-Output "OK:Downloaded via WebClient (`$((Get-Item `$setupExe).Length) bytes)"
            }
        } catch {
            Write-Output "WARN:WebClient failed - `$(`$_.Exception.Message)"
        }
    }

    if (-not `$dlSuccess) {
        Write-Output 'ERROR:Failed to download AmazonSSMAgentSetup.exe'
        Write-Output 'ERROR:Ensure VM can reach https://s3.amazonaws.com'
        Write-Output 'BOOTSTRAP_EXITCODE:126'
        return
    }

    # --- Step 2: Run the installer from C:\rs-pkgs with /S ---
    Write-Output 'ACTION:Installing SSM Agent from C:\rs-pkgs'
    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    `$p = Start-Process -FilePath `$setupExe -ArgumentList '/S' -WorkingDirectory `$dlDir -Wait -PassThru -NoNewWindow
    `$sw.Stop()
    Write-Output "ACTION:Installer exit: `$(`$p.ExitCode) (duration: `$([math]::Round(`$sw.Elapsed.TotalSeconds,1))s)"

    if (`$p.ExitCode -ne 0) {
        Write-Output "ERROR:AmazonSSMAgentSetup.exe failed with exit `$(`$p.ExitCode)"
        Write-Output "BOOTSTRAP_EXITCODE:100"
        return
    }
    Write-Output 'OK:SSM Agent binary installed'

    # --- Step 3: Download and run bootstrap for registration ---
    `$bsUrl = 'https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.ps1'
    Write-Output 'ACTION:Downloading bootstrap.ps1 for registration'
    Remove-Item `$bootstrapPath -Force -ErrorAction SilentlyContinue
    `$bsDl = `$false

    if (Test-Path `$curl) {
        & `$curl -sSfL --max-time 60 -o `$bootstrapPath `$bsUrl 2>&1 | Out-Null
        if ((Test-Path `$bootstrapPath) -and (Get-Item `$bootstrapPath).Length -gt 0) { `$bsDl = `$true }
    }
    if (-not `$bsDl) {
        try { Invoke-WebRequest -Uri `$bsUrl -OutFile `$bootstrapPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop; `$bsDl = `$true } catch {}
    }
    if (-not `$bsDl) {
        try { (New-Object System.Net.WebClient).DownloadFile(`$bsUrl, `$bootstrapPath); `$bsDl = `$true } catch {}
    }

    if (-not `$bsDl) {
        Write-Output 'ERROR:Failed to download bootstrap.ps1'
        Write-Output 'BOOTSTRAP_EXITCODE:126'
        return
    }
    Write-Output "OK:Downloaded bootstrap.ps1 (`$((Get-Item `$bootstrapPath).Length) bytes)"

    # Run bootstrap - it will see the agent is installed, write config, register
    Write-Output 'ACTION:Running bootstrap.ps1 -Command Install -Platform $PlatformName (registration)'
    `$bsStdout = Join-Path `$dlDir 'bootstrap-stdout.log'
    `$bsStderr = Join-Path `$dlDir 'bootstrap-stderr.log'
    Remove-Item `$bsStdout, `$bsStderr -Force -ErrorAction SilentlyContinue

    `$sw = [System.Diagnostics.Stopwatch]::StartNew()
    `$p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',`$bootstrapPath,'-Command','Install','-Platform','$PlatformName'$proxyArg) ``
        -WorkingDirectory `$dlDir ``
        -RedirectStandardOutput `$bsStdout -RedirectStandardError `$bsStderr ``
        -NoNewWindow -Wait -PassThru
    `$sw.Stop()

    # Emit bootstrap log
    if (Test-Path `$bootstrapLog) {
        Write-Output 'BOOTSTRAP_LOG_START'
        Get-Content `$bootstrapLog -Raw | Write-Output
        Write-Output 'BOOTSTRAP_LOG_END'
    }
    if ((Test-Path `$bsStdout) -and (Get-Item `$bsStdout).Length -gt 0) {
        Write-Output 'BOOTSTRAP_STDOUT_TAIL_START'
        Get-Content `$bsStdout -Tail 20 | Write-Output
        Write-Output 'BOOTSTRAP_STDOUT_TAIL_END'
    }
    Write-Output "BOOTSTRAP_DURATION:`$([math]::Round(`$sw.Elapsed.TotalSeconds,1))"
    Write-Output "BOOTSTRAP_EXITCODE:`$(`$p.ExitCode)"
} catch {
    Write-Output "ERROR:`$(`$_.Exception.Message)"
    Write-Output 'BOOTSTRAP_EXITCODE:144'
}
"@
    }
}

function Get-ReinstallScript {
    param(
        [string]$OsType,
        [string]$PlatformName,
        [string]$ProxyUrl
    )

    if ($OsType -eq 'Linux') {
        $proxyEnv = if ($ProxyUrl) { "export http_proxy='$ProxyUrl'; export https_proxy='$ProxyUrl'; " } else { "" }
        $proxyArg = if ($ProxyUrl) { " --http-proxy '$ProxyUrl'" } else { "" }
        $platformLower = $PlatformName.ToLower()

        return @"
#!/bin/bash
set -e
trap 'echo "ERROR:`$BASH_COMMAND failed"' ERR

bootstrap_path=""
dl_path="/tmp/bootstrap.py"

echo "ACTION:Downloading fresh bootstrap.py"
dl_success=false
for attempt in 1 2 3; do
    ${proxyEnv}wget -q -O "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || curl -sfSL -o "`$dl_path" "https://add-ons.manage.rackspace.com/scripts/v2/agent/bootstrap.py" 2>/dev/null \
        || true
    if [ -s "`$dl_path" ]; then
        dl_success=true
        break
    fi
    echo "WARN:Download attempt `$attempt failed"
    [ "`$attempt" -lt 3 ] && sleep `$((5 * attempt))
done

if [ "`$dl_success" = true ]; then
    bootstrap_path="`$dl_path"
    echo "OK:Downloaded bootstrap.py"
else
    for p in /tmp/bootstrap.py /opt/rackspace/bootstrap.py; do
        if [ -s "`$p" ]; then
            bootstrap_path="`$p"
            echo "WARN:Using local fallback `$p"
            break
        fi
    done
fi

if [ -z "`$bootstrap_path" ]; then
    echo "ERROR:Cannot reinstall - no bootstrap.py available"
    echo "ERROR:Ensure VM can reach https://add-ons.manage.rackspace.com"
    exit 1
fi

# Uninstall
echo "ACTION:Stopping service and cleaning up"
systemctl stop amazon-ssm-agent 2>/dev/null || service amazon-ssm-agent stop 2>/dev/null || true
sleep 2

# Kill any remaining processes
pkill -9 -f amazon-ssm-agent 2>/dev/null || true
pkill -9 -f ssm-agent-worker 2>/dev/null || true
sleep 2

# Clear registration if agent binary exists
if command -v amazon-ssm-agent &>/dev/null; then
    amazon-ssm-agent -register -clear 2>/dev/null || true
fi

echo "ACTION:Running bootstrap.py uninstall"
python3 "`$bootstrap_path" uninstall 2>&1 || \
    python "`$bootstrap_path" uninstall 2>&1 || \
    echo "WARN:bootstrap uninstall returned non-zero"

# Nuke SSM data
rm -rf /var/lib/amazon/ssm 2>/dev/null || true
rm -rf /etc/amazon/ssm 2>/dev/null || true
echo "OK:Cleaned SSM data directories"

sleep 5

# Install
echo "ACTION:Running bootstrap.py install"
python3 "`$bootstrap_path" install -p ${platformLower}${proxyArg} 2>&1 || \
    python "`$bootstrap_path" install -p ${platformLower}${proxyArg} 2>&1 || \
    echo "ERROR:bootstrap.py install failed"
"@
    } else {
        # Reinstall is a two-phase operation on Windows:
        #   Phase 1 (-PreBootstrap): stop service, clear registration, bootstrap Uninstall,
        #                            remove %ProgramData%\Amazon\SSM.
        #   Phase 2 (built-in):      bootstrap -Command Install - captured with full
        #                            sentinels by Get-WindowsBootstrapWrapper.
        $proxyArgLiteral = if ($ProxyUrl) { " -HttpProxy '$ProxyUrl'" } else { "" }
        $pre = @"
# --- Reinstall prelude: uninstall previous install cleanly ---
Write-Output 'ACTION:Stopping service and cleaning up'
try {
    `$svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
    if (`$svc -and `$svc.Status -eq 'StartPending') {
        Set-Service -Name 'AmazonSSMAgent' -StartupType Manual
        Get-Process -Name 'amazon-ssm-agent' -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id `$_.Id -Force }
        Start-Sleep -Seconds 3
    }
    if (`$svc -and `$svc.Status -eq 'Running') {
        & 'C:\Program Files\Amazon\SSM\amazon-ssm-agent.exe' -register -clear 2>&1 | Out-Null
    }
    Write-Output 'ACTION:Running bootstrap.ps1 -Command Uninstall'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$bootstrapPath -Command Uninstall$proxyArgLiteral 2>&1 | Out-String | Write-Output
} catch {
    Write-Output "WARN:Uninstall issue - `$(`$_.Exception.Message)"
    Stop-Service -Name 'AmazonSSMAgent' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'amazon-ssm-agent' -Force -ErrorAction SilentlyContinue
}

Remove-Item 'C:\ProgramData\Amazon\SSM' -Force -Recurse -ErrorAction SilentlyContinue
Write-Output 'OK:Cleaned SSM data directory'
Start-Sleep -Seconds 5
"@
        return Get-WindowsBootstrapWrapper -Command 'Install' -PlatformName $PlatformName -ProxyUrl $ProxyUrl -UseLocalFallback -PreBootstrap $pre
    }
}

#endregion

#region --- Action Runners (workflow engine) ---

# Each action runner takes the inputs it needs, executes a single remediation
# action via Run Command, and returns a New-SSMActionResult with a clear code
# (OK / FAIL_NETWORK / FAIL_PLATFORM_SERVICES / etc.) that the planner uses to
# decide what to do next. The runners do NOT decide whether to escalate or
# continue - that is the planner's job. They focus on running one action and
# classifying its result.

function Invoke-SSMAction-FixStartupType {
    param([string]$RG, [string]$VM, [string]$Loc, [string]$OsType, [int]$Timeout)
    Write-Step -Number 0 -Title 'Fix Service Startup Type' -Risk 'No'

    $script = Get-FixStartupScript -OsType $OsType
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Loc -Script $script -OsType $OsType -Timeout $Timeout -Label 'Fix startup type'

    if ($null -eq $out) {
        Write-Fail "Run Command did not return output"
        return (New-SSMActionResult -Action 'FixStartupType' -Code 'FAIL_RUN_COMMAND' -Message 'Run Command failed to return output' -RawOutput '')
    }

    if ($out.Trim() -eq 'FIXED') {
        Write-Ok "Changed startup type to Automatic/enabled"
        return (New-SSMActionResult -Action 'FixStartupType' -Code 'OK' `
            -Message 'Startup type set to Automatic/enabled' `
            -Changes @('Set startup type to Automatic/enabled') `
            -RawOutput $out)
    }

    Write-Fail "Could not change startup type"
    return (New-SSMActionResult -Action 'FixStartupType' -Code 'FAIL_UNKNOWN' `
        -Message "Startup-type fix did not return FIXED" -RawOutput $out)
}

function Invoke-SSMAction-Restart {
    param([string]$RG, [string]$VM, [string]$Loc, [string]$OsType, [int]$Timeout)
    Write-Step -Number 2 -Title 'Restart Service' -Risk 'Low'

    $script = Get-RestartScript -OsType $OsType
    Write-Info "Restarting SSM Agent service..."
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Loc -Script $script -OsType $OsType -Timeout $Timeout -Label 'Restart SSM agent'

    if ($null -eq $out) {
        Write-Fail "Run Command failed during restart"
        return (New-SSMActionResult -Action 'Restart' -Code 'FAIL_RUN_COMMAND' -Message 'Run Command failed to return output')
    }

    $changes = @()
    $resultLine = $null
    $out -split "`r?`n" | ForEach-Object {
        if ($_ -match '^FIX:(.+)') { Write-Ok $Matches[1]; $changes += $Matches[1] }
        elseif ($_ -match '^STATUS:(.+)') { Write-Warn $Matches[1] }
        elseif ($_ -match '^RESULT:(Running|active)') { Write-Ok "Service is now $($Matches[1])"; $resultLine = $Matches[1] }
        elseif ($_ -match '^RESULT:(.+)') { Write-Fail "Service status: $($Matches[1])"; $resultLine = $Matches[1] }
        elseif ($_ -match '^ERROR:(.+)') { Write-Fail $Matches[1] }
    }

    Write-Info "Waiting 15s for agent to phone home..."
    Wait-WithHeartbeat -Seconds 15 -Label 'Waiting for agent to phone home'

    if (Test-SSMHealthy -RG $RG -VM $VM -Location $Loc -OsType $OsType -Timeout $Timeout) {
        Write-Ok "Agent is healthy after restart"
        $changes += 'Restarted SSM Agent service'
        return (New-SSMActionResult -Action 'Restart' -Code 'OK' `
            -Message "Service restarted; agent healthy" -Changes $changes -RawOutput $out)
    }

    Write-Fail "Restart alone didn't resolve the issue"
    return (New-SSMActionResult -Action 'Restart' -Code 'FAIL_UNHEALTHY_AFTER' `
        -Message "Service status: $resultLine; agent still unhealthy" -Changes $changes -RawOutput $out)
}

function Invoke-SSMAction-Reregister {
    param([string]$RG, [string]$VM, [string]$Loc, [string]$OsType, [string]$PlatformName, [string]$ProxyUrl, [int]$Timeout)
    Write-Step -Number 3 -Title 'Clear Registration & Re-register' -Risk 'Medium'

    $script = Get-ReregisterScript -OsType $OsType -PlatformName $PlatformName -ProxyUrl $ProxyUrl
    Write-Info "Clearing registration and re-registering..."
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Loc -Script $script -OsType $OsType -Timeout $Timeout -Label 'Re-register agent (bootstrap)'

    if ($null -eq $out) {
        Write-Fail "Run Command failed during re-register"
        return (New-SSMActionResult -Action 'Reregister' -Code 'FAIL_RUN_COMMAND' -Message 'Run Command failed to return output')
    }

    $out -split "`r?`n" | ForEach-Object {
        if ($_ -match '^ACTION:(.+)') { Write-Info $Matches[1] }
        elseif ($_ -match '^OK:(.+)') { Write-Ok $Matches[1] }
        elseif ($_ -match '^WARN:(.+)') { Write-Warn $Matches[1] }
        elseif ($_ -match '^ERROR:(.+)') { Write-Fail $Matches[1] }
        elseif ($_ -match 'RESULT:(Running|active)') { Write-Ok "Service is $($Matches[1])" }
        elseif ($_ -match 'registered successfully') { Write-Ok $_ }
        elseif ($_ -match 'ManagedInstanceID|ssm_instance_id') { Write-Ok $_.Trim() }
    }

    $bsResult = Parse-BootstrapOutput -Command 'Reregister' -Output $out
    Write-BootstrapResult -Result $bsResult

    # Map bootstrap exit code to an action result code first.
    $bootCode = Get-SSMActionCodeFromBootstrap -BootstrapResult $bsResult
    if ($bootCode -in @('FAIL_PLATFORM_SERVICES','FAIL_NETWORK','FAIL_UNSUPPORTED_OS')) {
        if ($bootCode -eq 'FAIL_PLATFORM_SERVICES') {
            Write-Fail "Re-registration blocked by Rackspace Platform Services"
            $msg = "Bootstrap Reregister failed: $($bsResult.ExitCodeMessage). Activation HTTP $($bsResult.ActivationHttpStatus) at $($bsResult.ActivationUrl)."
            Write-EscalationBanner -Reason $msg -BootstrapResult $bsResult
        } else {
            Write-Fail "Re-registration failed: $($bsResult.ExitCodeMessage)"
        }
        return (New-SSMActionResult -Action 'Reregister' -Code $bootCode `
            -Message $bsResult.ExitCodeMessage -BootstrapResult $bsResult -RawOutput $out)
    }

    Write-Info "Waiting 45s for agent to register..."
    Wait-WithHeartbeat -Seconds 45 -Label 'Waiting for agent to register'

    if (Test-SSMHealthy -RG $RG -VM $VM -Location $Loc -OsType $OsType -Timeout $Timeout) {
        Write-Ok "Agent is healthy after re-registration"
        return (New-SSMActionResult -Action 'Reregister' -Code 'OK' `
            -Message 'Cleared registration and re-registered' `
            -Changes @('Cleared registration and re-registered via bootstrap') `
            -BootstrapResult $bsResult -RawOutput $out)
    }

    Write-Fail "Re-registration didn't resolve the issue"
    $code = if ($bootCode -eq 'OK_NO_VERIFY') { 'FAIL_UNHEALTHY_AFTER' } else { $bootCode }
    return (New-SSMActionResult -Action 'Reregister' -Code $code `
        -Message 'Re-registered but agent still unhealthy' `
        -BootstrapResult $bsResult -RawOutput $out)
}

function Invoke-SSMAction-Install {
    param([string]$RG, [string]$VM, [string]$Loc, [string]$OsType, [string]$PlatformName, [string]$ProxyUrl, [int]$Timeout)
    Write-Step -Number 1 -Title 'Fresh Install (agent not present)' -Risk 'Low'

    $script = Get-InstallScript -OsType $OsType -PlatformName $PlatformName -ProxyUrl $ProxyUrl
    Write-Info "Installing SSM agent..."
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Loc -Script $script -OsType $OsType -Timeout $Timeout -Label 'Install agent (bootstrap)'

    if ($null -eq $out) {
        Write-Fail "Run Command failed during install"
        return (New-SSMActionResult -Action 'Install' -Code 'FAIL_RUN_COMMAND' -Message 'Run Command failed to return output')
    }

    $out -split "`r?`n" | ForEach-Object {
        if ($_ -match '^ACTION:(.+)') { Write-Info $Matches[1] }
        elseif ($_ -match '^OK:(.+)') { Write-Ok $Matches[1] }
        elseif ($_ -match '^WARN:(.+)') { Write-Warn $Matches[1] }
        elseif ($_ -match '^ERROR:(.+)') { Write-Fail $Matches[1] }
        elseif ($_ -match 'registered successfully') { Write-Ok $_ }
        elseif ($_ -match 'ManagedInstanceID|ssm_instance_id') { Write-Ok $_.Trim() }
    }

    Write-Info "Waiting 30s for agent to register..."
    Wait-WithHeartbeat -Seconds 30 -Label 'Waiting for agent to register'

    $bsResult = Parse-BootstrapOutput -Command 'Install' -Output $out
    Write-BootstrapResult -Result $bsResult
    $bootCode = Get-SSMActionCodeFromBootstrap -BootstrapResult $bsResult

    if ($bootCode -in @('FAIL_PLATFORM_SERVICES','FAIL_NETWORK','FAIL_UNSUPPORTED_OS')) {
        if ($bootCode -eq 'FAIL_PLATFORM_SERVICES') {
            Write-Fail "Fresh install blocked by Rackspace Platform Services"
            $msg = "Bootstrap Install failed: $($bsResult.ExitCodeMessage). Activation HTTP $($bsResult.ActivationHttpStatus) at $($bsResult.ActivationUrl)."
            Write-EscalationBanner -Reason $msg -BootstrapResult $bsResult
        } elseif ($bootCode -eq 'FAIL_NETWORK') {
            Write-Fail "Install failed at download stage: $($bsResult.ExitCodeMessage)"
            if (-not $script:SuppressConsole) {
                Write-Host ""
                Write-Host "  Likely causes:" -ForegroundColor Yellow
                Write-Host "    - NSG / Azure Firewall blocking outbound 443" -ForegroundColor DarkGray
                Write-Host "    - Proxy not configured (re-run with -HttpProxy)" -ForegroundColor DarkGray
                Write-Host "    - DNS failure for s3.<region>.amazonaws.com or add-ons.manage.rackspace.com" -ForegroundColor DarkGray
            }
        } else {
            Write-Fail "Install rejected: $($bsResult.ExitCodeMessage)"
        }
        return (New-SSMActionResult -Action 'Install' -Code $bootCode `
            -Message $bsResult.ExitCodeMessage -BootstrapResult $bsResult -RawOutput $out)
    }

    if (Test-SSMHealthy -RG $RG -VM $VM -Location $Loc -OsType $OsType -Timeout $Timeout) {
        Write-Ok "Agent is healthy after fresh install"
        return (New-SSMActionResult -Action 'Install' -Code 'OK' `
            -Message 'Fresh install via bootstrap succeeded' `
            -Changes @('Fresh install via bootstrap (agent was not present)') `
            -BootstrapResult $bsResult -RawOutput $out)
    }

    Write-Fail "Fresh install did not result in a healthy agent"
    $code = if ($bootCode -eq 'OK_NO_VERIFY') { 'FAIL_UNHEALTHY_AFTER' } else { $bootCode }
    return (New-SSMActionResult -Action 'Install' -Code $code `
        -Message 'Install ran but agent still unhealthy' `
        -BootstrapResult $bsResult -RawOutput $out)
}

function Invoke-SSMAction-Reinstall {
    param([string]$RG, [string]$VM, [string]$Loc, [string]$OsType, [string]$PlatformName, [string]$ProxyUrl, [int]$Timeout)
    Write-Step -Number 4 -Title 'Full Reinstall' -Risk 'High'

    $script = Get-ReinstallScript -OsType $OsType -PlatformName $PlatformName -ProxyUrl $ProxyUrl
    Write-Info "Performing full uninstall and reinstall..."
    $out = Invoke-RemoteScript -RG $RG -VM $VM -Location $Loc -Script $script -OsType $OsType -Timeout $Timeout -Label 'Reinstall agent (uninstall + install)'

    if ($null -eq $out) {
        Write-Fail "Run Command failed during reinstall"
        return (New-SSMActionResult -Action 'Reinstall' -Code 'FAIL_RUN_COMMAND' -Message 'Run Command failed to return output')
    }

    $out -split "`r?`n" | ForEach-Object {
        if ($_ -match '^ACTION:(.+)') { Write-Info $Matches[1] }
        elseif ($_ -match '^OK:(.+)') { Write-Ok $Matches[1] }
        elseif ($_ -match '^WARN:(.+)') { Write-Warn $Matches[1] }
        elseif ($_ -match '^ERROR:(.+)') { Write-Fail $Matches[1] }
        elseif ($_ -match 'registered successfully') { Write-Ok $_ }
        elseif ($_ -match 'ManagedInstanceID|ssm_instance_id') { Write-Ok $_.Trim() }
    }

    $bsResult = Parse-BootstrapOutput -Command 'Install' -Output $out
    Write-BootstrapResult -Result $bsResult
    $bootCode = Get-SSMActionCodeFromBootstrap -BootstrapResult $bsResult

    if ($bootCode -in @('FAIL_PLATFORM_SERVICES','FAIL_NETWORK','FAIL_UNSUPPORTED_OS')) {
        if ($bootCode -eq 'FAIL_PLATFORM_SERVICES') {
            Write-Fail "Reinstall blocked by Rackspace Platform Services"
            $msg = "Bootstrap Install failed: $($bsResult.ExitCodeMessage). Activation HTTP $($bsResult.ActivationHttpStatus) at $($bsResult.ActivationUrl)."
            Write-EscalationBanner -Reason $msg -BootstrapResult $bsResult
        } else {
            Write-Fail "Reinstall failed: $($bsResult.ExitCodeMessage)"
        }
        return (New-SSMActionResult -Action 'Reinstall' -Code $bootCode `
            -Message $bsResult.ExitCodeMessage -BootstrapResult $bsResult -RawOutput $out)
    }

    Write-Info "Waiting 30s for fresh agent to register..."
    Wait-WithHeartbeat -Seconds 30 -Label 'Waiting for fresh agent to register'

    if (Test-SSMHealthy -RG $RG -VM $VM -Location $Loc -OsType $OsType -Timeout $Timeout) {
        Write-Ok "Agent is healthy after reinstall"
        return (New-SSMActionResult -Action 'Reinstall' -Code 'OK' `
            -Message 'Full uninstall and reinstall succeeded' `
            -Changes @('Full uninstall and reinstall via bootstrap') `
            -BootstrapResult $bsResult -RawOutput $out)
    }

    Write-Fail "Reinstall did not resolve the issue"
    $code = if ($bootCode -eq 'OK_NO_VERIFY') { 'FAIL_UNHEALTHY_AFTER' } else { $bootCode }
    return (New-SSMActionResult -Action 'Reinstall' -Code $code `
        -Message 'Reinstall ran but agent still unhealthy' `
        -BootstrapResult $bsResult -RawOutput $out)
}

#endregion

#region --- Main ---

# Detect OS and Location
$vmInfo = Get-VMOsType -RG $ResourceGroupName -VM $VMName
$VmOsType = $vmInfo.OsType
$VmLocation = $vmInfo.Location

# --- Initialise structured result ---
$result = New-SSMFixerResult `
    -VMName $VMName `
    -ResourceGroupName $ResourceGroupName `
    -OsType $VmOsType `
    -Region $(if ($Region) { $Region } else { '' }) `
    -Platform $Platform `
    -DiagnoseOnly $DiagnoseOnly.IsPresent `
    -TimeoutSeconds $TimeoutSeconds `
    -MaxStep $MaxStep `
    -SkipToStep $SkipToStep

# Helper: finalise and emit the result (called at every exit point)
function Write-Result {
    param([PSCustomObject]$R, [System.Collections.ArrayList]$Changes)
    $R.Changes = @($Changes)
    $R = Complete-SSMFixerResult -Result $R
    if ($script:SuppressConsole) {
        # JSON mode - emit structured output for pipeline/automation consumers.
        # Interactive callers get the Write-Host summary banner only.
        $R | ConvertTo-Json -Depth 10
    }
}

# Banner
if (-not $script:SuppressConsole) {
    Write-Host ""
    $boxW = 66
    $border = "=" * $boxW
    Write-Host "  +${border}+" -ForegroundColor DarkCyan
    $t1 = "SSM FIXER"; $p1 = [int](($boxW - $t1.Length) / 2); $l1 = $t1.PadLeft($p1 + $t1.Length).PadRight($boxW)
    Write-Host -NoNewline "  |" -ForegroundColor DarkCyan; Write-Host -NoNewline $l1 -ForegroundColor Cyan; Write-Host "|" -ForegroundColor DarkCyan
    $t2 = "Automated SSM Agent Remediation for Azure VMs"; $p2 = [int](($boxW - $t2.Length) / 2); $l2 = $t2.PadLeft($p2 + $t2.Length).PadRight($boxW)
    Write-Host -NoNewline "  |" -ForegroundColor DarkCyan; Write-Host -NoNewline $l2 -ForegroundColor DarkCyan; Write-Host "|" -ForegroundColor DarkCyan
    Write-Host "  +${border}+" -ForegroundColor DarkCyan
    Write-Host ""
}
Write-Field "VM" $VMName 'White'
Write-Field "Resource Group" $ResourceGroupName 'White'
Write-Field "OS Type" $VmOsType $(if ($VmOsType -eq 'Linux') { 'Yellow' } else { 'Cyan' })
Write-Field "Platform" $Platform 'White'
if ($Region) { Write-Field "SSM Region" "$Region (override)" 'Cyan' }
$modeText = if ($DiagnoseOnly) { 'DIAGNOSE ONLY (read-only)' } else { "REMEDIATE (Steps $SkipToStep-$MaxStep)" }
$modeColor = if ($DiagnoseOnly) { 'Cyan' } else { 'Yellow' }
Write-Field "Mode" $modeText $modeColor
Write-Field "Timeout" "${TimeoutSeconds}s per command" 'DarkGray'
Write-Field "Started" (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 'DarkGray'

if ($DiagnoseOnly) { $MaxStep = [Math]::Min($MaxStep, 1) }
$changesMade = [System.Collections.ArrayList]::new()
$script:RouteToInstall = $false


# ---------------------------------------------
# PREFLIGHT - Run Command responsiveness + pending reboot
# ---------------------------------------------
# Cheap probes that catch failure modes which would otherwise burn 5+ minutes
# of Run Command timeouts in later steps:
#   - If Run Command can't get a hostname back in 60s, the VM agent is wedged
#     and no remediation has a chance. Stop and escalate.
#   - If Windows has a pending reboot (CBS / Windows Update / Pending File
#     Rename / MSI InstallInProgress), the MSI engine routinely fails install
#     attempts with 0x80004005 and no log. Surface this prominently so the
#     user reboots first instead of chasing phantom install errors.
$preflightTimeout = [Math]::Min(75, $TimeoutSeconds)
Write-Step -Number 0 -Title "Preflight" -Risk "No"
Write-Info "Probing Run Command responsiveness and pending-reboot state ($VmOsType, ${preflightTimeout}s)..."
$preflight = Invoke-SSMPreflight -RG $ResourceGroupName -VM $VMName -Location $VmLocation `
    -OsType $VmOsType -Timeout $preflightTimeout
$result.Preflight = $preflight

if ($preflight.Status -eq 'OK') {
    Write-Ok "Run Command healthy ($($preflight.Hostname), $($preflight.DurationSeconds)s)"
    if ($preflight.PendingReboot) {
        if (-not $script:SuppressConsole) {
            Write-Host ""
            Write-Host "  +==================================================================+" -ForegroundColor Yellow
            Write-Host "  |                       PENDING REBOOT DETECTED                    |" -ForegroundColor Yellow
            Write-Host "  +==================================================================+" -ForegroundColor Yellow
            Write-Host "  Reasons: $($preflight.PendingRebootReasons -join ', ')" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  A pending reboot is the most common cause of install failures with" -ForegroundColor DarkGray
            Write-Host "  exit code 100 / 0x80004005 from AmazonSSMAgentSetup.exe (the MSI" -ForegroundColor DarkGray
            Write-Host "  engine wedges and the installer aborts before logging starts)." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Recommended: reboot the VM and re-run the fixer. If you want to" -ForegroundColor Yellow
            Write-Host "  proceed anyway, the fixer will continue but expect failures." -ForegroundColor Yellow
            Write-Host ""
        }
    }
} else {
    # Run Command itself failed - no point continuing.
    Write-Fail "Preflight failed: $($preflight.Message)"
    $result.RunCommandFailure = Write-RunCommandFailureDiagnosis -RG $ResourceGroupName -VM $VMName -OsType $VmOsType -DiagnoseOnly:$DiagnoseOnly
    $result.Outcome = 'RUN_COMMAND_FAILED'
    $result.EscalationRequired = $true
    $result.EscalationReason = $preflight.Message
    $result.Steps['preflight'] = New-SSMStepResult -StepNumber 0 -Title 'Preflight' -Risk 'No' -Status 'RUN_COMMAND_FAILED'
    $planLog = @(New-SSMPlanDecision -Action 'Stop' `
        -Reason $preflight.Message `
        -Terminal $true -Outcome 'RUN_COMMAND_FAILED')
    $result.PlanLog = $planLog
    return (Write-Result -R $result -Changes $changesMade)
}


# ---------------------------------------------
# STEP 1 - Service Status & Diagnostics
# ---------------------------------------------
if ($SkipToStep -le 1 -and $MaxStep -ge 1) {
    Write-Step -Number 1 -Title "Agent Diagnostics" -Risk "No"

    $diagScript = Get-DiagScript -OsType $VmOsType

    Write-Info "Querying agent status via Run Command ($VmOsType)..."
    $rawOutput = Invoke-RemoteScript -RG $ResourceGroupName -VM $VMName -Location $VmLocation -Script $diagScript -OsType $VmOsType -Timeout $TimeoutSeconds -Label 'Agent diagnostics'

    $diag = $null
    if ($rawOutput) {
        try { $diag = $rawOutput.Trim() | ConvertFrom-Json } catch {
            Write-Fail "Could not parse diagnostics: $($_.Exception.Message)"
        }
    }

    if ($diag) {
        if (-not $script:SuppressConsole) { Write-Host "" }
        # Service status with color logic
        Write-StatusField "Service" $diag.ServiceStatus
        $startTypeColor = if ($diag.StartType -in @('Automatic','enabled')) { 'Green' } elseif ($diag.StartType -in @('Manual','disabled')) { 'Yellow' } else { 'Red' }
        Write-Field "Startup Type" $diag.StartType $startTypeColor
        Write-Field "Agent Version" $(if ($diag.AgentVersion) { $diag.AgentVersion } else { 'Unknown (ssm-cli unavailable)' }) $(if ($diag.AgentVersion) { 'White' } else { 'Yellow' })

        # Registration
        if ($diag.RegistrationExists -eq $true -or $diag.RegistrationExists -eq 'true') {
            Write-StatusField "Registration" "Active ($($diag.RegistrationAgeDays) days old)"
        } else {
            Write-StatusField "Registration" "MISSING"
        }
        $fpExists = $diag.FingerprintExists -eq $true -or $diag.FingerprintExists -eq 'true'
        Write-StatusField "Fingerprint Key" $(if ($fpExists) { 'Present' } else { 'MISSING' })

        # Instance ID
        $idColor = switch ($diag.InstanceId) {
            'MISSING' { 'Red' }
            'ERROR'   { 'Red' }
            'N/A'     { 'DarkGray' }
            default   { 'Green' }
        }
        Write-Field "Instance ID" $diag.InstanceId $idColor

        # Region
        if ($diag.DetectedRegion) {
            Write-Field "SSM Region" $diag.DetectedRegion 'Cyan'
            if (-not $Region) {
                $Region = $diag.DetectedRegion
                $result.Region = $Region
            }
        }

        # Overall health verdict
        if (-not $script:SuppressConsole) { Write-Host "" }
        $issues = @()
        $svcRunning = $diag.ServiceStatus -in @('Running', 'active')
        $startTypeGood = $diag.StartType -in @('Automatic', 'enabled')
        $regExists = $diag.RegistrationExists -eq $true -or $diag.RegistrationExists -eq 'true'

        if (-not $svcRunning) { $issues += "Service is $($diag.ServiceStatus)" }
        if (-not $startTypeGood -and $diag.StartType -ne 'N/A') { $issues += "Startup type is $($diag.StartType) (should be Automatic/enabled)" }
        if (-not $regExists) { $issues += "No registration file found" }
        if (-not $fpExists) { $issues += "No fingerprint key found" }
        if ($diag.InstanceId -in @('MISSING','ERROR')) { $issues += "Instance ID is $($diag.InstanceId)" }

        if ($issues.Count -eq 0) {
            Write-Ok "Agent appears healthy - no issues detected"
        } else {
            Write-Fail "Issues found:"
            if (-not $script:SuppressConsole) {
                foreach ($issue in $issues) {
                    Write-Host "     - $issue" -ForegroundColor Red
                }
            }
        }

        # --- Populate schema: Diagnosis ---
        $result.Diagnosis = New-SSMDiagnosis `
            -ServiceStatus $diag.ServiceStatus `
            -StartType $diag.StartType `
            -AgentVersion $diag.AgentVersion `
            -RegistrationExists $diag.RegistrationExists `
            -RegistrationAgeDays $diag.RegistrationAgeDays `
            -DetectedRegion $diag.DetectedRegion `
            -FingerprintExists $diag.FingerprintExists `
            -SsmCliExists $diag.SsmCliExists `
            -AgentExeExists $diag.AgentExeExists `
            -InstanceId $diag.InstanceId
        $result.Diagnosis.Issues = $issues
        $result.Diagnosis.Healthy = ($issues.Count -eq 0)

        # Fetch and display logs
        if (-not $script:SuppressConsole) { Write-Host "" }
        Write-Info "Fetching agent logs and connectivity info..."
        $logScript = Get-LogScript -OsType $VmOsType
        $logOutput = Invoke-RemoteScript -RG $ResourceGroupName -VM $VMName -Location $VmLocation -Script $logScript -OsType $VmOsType -Timeout $TimeoutSeconds -Label 'Logs + connectivity'

        if ($logOutput) {
            $logLines = $logOutput.Trim() -split "`r?`n"

            # Parse structured output
            $inDiag = $false
            $diagJson = ''
            $otherLines = @()
            $endpointLines = @()
            $proxyLines = @()
            foreach ($line in $logLines) {
                if ($line -match '>>> ssm-cli get-diagnostics') { $inDiag = $true; continue }
                if ($inDiag) { $diagJson += $line + "`n" }
                elseif ($line -match '^ENDPOINT:(.+)') { $endpointLines += $Matches[1] }
                elseif ($line -match '^PROXY:(.+)') { $proxyLines += $Matches[1] }
                elseif ($line -match '>>> Rackspace') { <# skip header #> }
                else { $otherLines += $line }
            }

            # Show ssm-cli diagnostics as a clean table
            if ($diagJson.Trim()) {
                try {
                    $diagData = $diagJson.Trim() | ConvertFrom-Json
                    if ($diagData.DiagnosticsOutput) {
                        if (-not $script:SuppressConsole) {
                            Write-Host ""
                            Write-Host "  SSM Agent Self-Diagnostics:" -ForegroundColor Cyan
                            Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
                        }
                        foreach ($check in $diagData.DiagnosticsOutput) {
                            # Populate schema
                            $result.SsmCliDiagnostics += New-SSMCliCheck -Check $check.Check -Status $check.Status -Note $check.Note

                            if (-not $script:SuppressConsole) {
                                $icon = switch ($check.Status) {
                                    'Success' { 'Green' }
                                    'Failed'  { 'Red' }
                                    'Skipped' { 'DarkGray' }
                                    default   { 'Yellow' }
                                }
                                $symbol = switch ($check.Status) {
                                    'Success' { '[PASS]' }
                                    'Failed'  { '[FAIL]' }
                                    'Skipped' { '[SKIP]' }
                                    default   { '[????]' }
                                }
                                Write-Host -NoNewline "  $symbol " -ForegroundColor $icon
                                Write-Host -NoNewline "$($check.Check.PadRight(38))" -ForegroundColor White
                                Write-Host $check.Note -ForegroundColor DarkGray
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Could not parse ssm-cli diagnostics JSON"
                }
            }

            # Show Rackspace endpoint results
            if ($endpointLines) {
                if (-not $script:SuppressConsole) {
                    Write-Host ""
                    Write-Host "  Rackspace Platform Services Connectivity:" -ForegroundColor Cyan
                    Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
                }
                foreach ($ep in $endpointLines) {
                    $parts = $ep -split '\|'
                    $name = $parts[0]
                    $status = $parts[1]
                    $dnsVal = if ($parts.Count -gt 2) { ($parts[2] -replace 'DNS=','') } else { '' }
                    $portVal = if ($parts.Count -gt 3) { ($parts[3] -replace '443=','') } else { '' }

                    # Populate schema
                    $result.Connectivity += New-SSMEndpointResult -Endpoint $name -Status $status -DnsOk $dnsVal -PortOk $portVal

                    if (-not $script:SuppressConsole) {
                        $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
                        $symbol = if ($status -eq 'PASS') { '[PASS]' } else { '[FAIL]' }
                        Write-Host -NoNewline "  $symbol " -ForegroundColor $color
                        Write-Host "$name" -ForegroundColor White
                    }
                }
            }

            # Show proxy config if present
            if ($proxyLines) {
                $result.Proxy = @($proxyLines)
                if (-not $script:SuppressConsole) {
                    Write-Host ""
                    Write-Host "  Proxy Configuration:" -ForegroundColor Cyan
                    foreach ($p in $proxyLines) {
                        Write-Field "Proxy" $p 'White'
                    }
                }
            }

            # Show error log lines (only ERROR lines, not info)
            $errorLines = $otherLines | Where-Object { $_ -match 'ERROR' }
            if ($errorLines) {
                $uniqueErrors = @($errorLines | Select-Object -Unique | Select-Object -Last 5)
                $result.LogErrors = $uniqueErrors
                # Mirror onto Diagnosis so the planner can route on log signals
                # (e.g. MachineFingerprintDoesNotMatch -> Reregister) in -Auto.
                if ($result.Diagnosis) { $result.Diagnosis.LogErrors = $uniqueErrors }

                if (-not $script:SuppressConsole) {
                    Write-Host ""
                    Write-Host "  Recent Errors (from agent logs):" -ForegroundColor Yellow
                    Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
                    foreach ($err in $uniqueErrors) {
                        $display = if ($err.Length -gt 120) { $err.Substring(0, 117) + '...' } else { $err }
                        Write-Host "  $display" -ForegroundColor DarkYellow
                    }
                }
            }
        }

        $result.Steps['1'] = New-SSMStepResult -StepNumber 1 -Title 'Agent Diagnostics' -Risk 'No' -Status $(if ($issues.Count -eq 0) { 'SUCCESS' } else { 'ISSUES_FOUND' })

        # Auto-routing decisions - these set $script:RecommendedAction so both the
        # interactive menu (default) and -Auto mode can use the same heuristic.
        $script:RecommendedAction = $null
        if ($diag.ServiceStatus -eq 'NOT_INSTALLED') {
            $script:RecommendedAction = 'Install'
            if (-not $script:SuppressConsole) { Write-Host "" }
            Write-Action "Recommendation: fresh install (agent not present)."
            if ($Auto.IsPresent -and -not $DiagnoseOnly) { $script:RouteToInstall = $true }
        }
        if ($diag.InstanceId -eq 'MISSING' -and $diag.ServiceStatus -ne 'NOT_INSTALLED') {
            if (-not $script:SuppressConsole) { Write-Host "" }
            $exeHealthy = ($diag.AgentExeExists -eq $true -or $diag.AgentExeExists -eq 'true')
            $cliHealthy = ($diag.SsmCliExists -eq $true -or $diag.SsmCliExists -eq 'true')
            $binariesHealthy = $exeHealthy -or $cliHealthy
            if ($binariesHealthy) {
                Write-Action "Recommendation: Re-register (Step 3) - binaries present, identity missing."
                $script:RecommendedAction = 'Reregister'
                if ($Auto.IsPresent -and -not $DiagnoseOnly -and $MaxStep -ge 3) {
                    $SkipToStep = [Math]::Max($SkipToStep, 3)
                }
            } else {
                Write-Action "Recommendation: Full Reinstall (Step 4) - binaries missing and no identity."
                $script:RecommendedAction = 'Reinstall'
                if ($Auto.IsPresent -and -not $DiagnoseOnly -and $MaxStep -ge 4) {
                    $SkipToStep = [Math]::Max($SkipToStep, 4)
                }
            }
        }
        if (-not $script:RecommendedAction -and $result.LogErrors) {
            # MachineFingerprintDoesNotMatch - typical after VM clone, snapshot
            # restore, or any change to host identifiers. Agent is running and
            # registered, but credential refresh fails because the fingerprint
            # AWS has on record no longer matches the host. Re-register (Step 3)
            # generates a fresh fingerprint and resolves it - no MSI work needed.
            $fpMismatch = $result.LogErrors | Where-Object { $_ -match 'MachineFingerprintDoesNotMatch' } | Select-Object -First 1
            if ($fpMismatch) {
                if (-not $script:SuppressConsole) { Write-Host "" }
                Write-Action "Recommendation: Re-register (Step 3) - MachineFingerprintDoesNotMatch in agent log (VM cloned/restored)."
                $script:RecommendedAction = 'Reregister'
                if ($Auto.IsPresent -and -not $DiagnoseOnly -and $MaxStep -ge 3) {
                    $SkipToStep = [Math]::Max($SkipToStep, 3)
                }
            }
        }
        if (-not $script:RecommendedAction -and $issues.Count -gt 0) {
            # Service unhealthy but binaries/registration present - try a restart first
            $script:RecommendedAction = 'Restart'
        }
    } else {
        $result.RunCommandFailure = Write-RunCommandFailureDiagnosis -RG $ResourceGroupName -VM $VMName -OsType $VmOsType -DiagnoseOnly:$DiagnoseOnly
        $result.Steps['1'] = New-SSMStepResult -StepNumber 1 -Title 'Agent Diagnostics' -Risk 'No' -Status 'RUN_COMMAND_FAILED'
    }
}

# ---------------------------------------------
# WORKFLOW LOOP - planner-driven remediation
# ---------------------------------------------
# The planner (Get-NextSSMAction in SSMFixerWorkflow.ps1) decides what to do
# next based on:
#   - the current diagnosis,
#   - the history of actions already attempted on this run,
#   - the user-supplied -MaxStep cap.
#
# Each action returns a structured result code (OK / FAIL_NETWORK /
# FAIL_PLATFORM_SERVICES / FAIL_UNHEALTHY_AFTER / ...) which the planner
# inspects on the next iteration. Terminal codes (Platform Services failure,
# network failure at download, unsupported OS) cause the planner to Stop
# immediately rather than blindly cascade through more steps.
#
# Interactive mode: after Step 1 we offer the user a menu. Their choice
# becomes the first planned action; if they pick something the planner thinks
# is a poor fit (e.g. Restart on a NOT_INSTALLED agent) the planner will
# re-route on the next iteration based on the action result.

# Convert -MaxStep (1..4) to internal risk cap for the planner
$maxRisk = Convert-SSMMaxStepToRisk -MaxStep $MaxStep

# Optional first-action override (interactive menu, or legacy -SkipToStep)
$pendingAction = $null
$pendingReason = $null

if ($script:Interactive -and -not $DiagnoseOnly -and $result.Diagnosis -and -not $result.Diagnosis.Healthy) {
    $choice = Invoke-ActionMenu -Diagnosis $result.Diagnosis -Recommended $script:RecommendedAction
    switch ($choice.Action) {
        'Quit'         {
            Write-Host "  Exiting without changes." -ForegroundColor DarkGray
            return (Write-Result -R $result -Changes $changesMade)
        }
        'DiagnoseOnly' { $DiagnoseOnly = [switch]::Present }
        'FixStartup'   { $pendingAction = 'FixStartupType'; $pendingReason = 'User chose: Fix startup type only' }
        'Install'      { $pendingAction = 'Install';        $pendingReason = 'User chose: Fresh install' }
        'Restart'      { $pendingAction = 'Restart';        $pendingReason = 'User chose: Restart service' }
        'Reregister'   { $pendingAction = 'Reregister';     $pendingReason = 'User chose: Re-register' }
        'Reinstall'    { $pendingAction = 'Reinstall';      $pendingReason = 'User chose: Full reinstall' }
        'Progressive'  { $pendingAction = $null;            $pendingReason = $null }  # let planner decide
    }
} elseif (-not $DiagnoseOnly -and $SkipToStep -gt 1) {
    # Legacy -SkipToStep support: map to a pending action for the planner
    switch ($SkipToStep) {
        2 { $pendingAction = 'Restart';    $pendingReason = "-SkipToStep 2 from caller" }
        3 { $pendingAction = 'Reregister'; $pendingReason = "-SkipToStep 3 from caller" }
        4 { $pendingAction = 'Reinstall';  $pendingReason = "-SkipToStep 4 from caller" }
    }
}

# Track ActionResults and PlanDecisions in arrays the schema understands
$actionHistory = @()
$planLog       = @()

if (-not $DiagnoseOnly -and ($result.Diagnosis -or $pendingAction)) {
    $maxIterations = 6   # safety cap - planner ensures each action runs at most once
    for ($iter = 0; $iter -lt $maxIterations; $iter++) {

        # --- Choose next action ---
        $isUserChoice = $false
        if ($pendingAction) {
            $decision = New-SSMPlanDecision -Action $pendingAction -Reason $pendingReason `
                -Risk $script:SSMActionRisk[$pendingAction]
            $isUserChoice = $true
            $pendingAction = $null
            $pendingReason = $null
        } else {
            $decision = Get-NextSSMAction -Diagnosis $result.Diagnosis -History $actionHistory `
                -MaxRisk $maxRisk -DiagnoseOnly:$DiagnoseOnly.IsPresent
        }

        $planLog += $decision

        if ($decision.Action -eq 'Stop' -or $decision.Terminal) {
            # Surface the planner's outcome (overrides only when not already set)
            if ($decision.Outcome -and -not $result.Outcome) {
                $result.Outcome = $decision.Outcome
            }
            if ($decision.Outcome -in @('PLATFORM_SERVICES_UNAVAILABLE','PLATFORM_SERVICES_REJECTED','INSTALL_FAILED_NETWORK','INSTALL_FAILED_UNSUPPORTED_OS','RUN_COMMAND_FAILED')) {
                $result.EscalationRequired = $true
                if (-not $result.EscalationReason) { $result.EscalationReason = $decision.Reason }
            }
            if (-not $script:SuppressConsole) {
                Write-Host ""
                Write-Host "  Planner: " -NoNewline -ForegroundColor Cyan
                Write-Host $decision.Reason -ForegroundColor DarkGray
            }
            break
        }

        # --- Confirm with -WhatIf gate ---
        $whatIfTarget = "$($decision.Action) (planner: $($decision.Reason))"
        if (-not $PSCmdlet.ShouldProcess($VMName, $whatIfTarget)) { break }

        # --- Interactive confirmation for High/Medium-risk escalation ---
        # Only prompt when the PLANNER is escalating beyond what the user chose.
        # The user's own menu selection runs without re-confirmation.
        if ($script:Interactive -and $decision.Risk -ge 2 -and -not $isUserChoice) {
            if (-not $script:SuppressConsole) {
                Write-Host ""
                Write-Host "  +------------------------------------------------------------------+" -ForegroundColor Yellow
                Write-Host "  |  The planner wants to escalate to a higher-risk action:          |" -ForegroundColor Yellow
                Write-Host "  +------------------------------------------------------------------+" -ForegroundColor Yellow
                Write-Host "  Action : $($decision.Action) ($($decision.RiskLabel) risk)" -ForegroundColor Yellow
                Write-Host "  Reason : $($decision.Reason)" -ForegroundColor DarkGray
                Write-Host ""
            }
            $confirm = Read-Host "  Proceed? [Y/n]"
            if ($confirm -and $confirm.Trim().ToUpper() -notin @('Y','YES','')) {
                Write-Info "Skipped by user. Stopping."
                break
            }
        }

        if (-not $script:SuppressConsole) {
            Write-Host ""
            Write-Host "  Planner -> " -NoNewline -ForegroundColor Cyan
            Write-Host "$($decision.Action)" -NoNewline -ForegroundColor Yellow
            Write-Host "  ($($decision.RiskLabel) risk)" -ForegroundColor DarkGray
            Write-Host "  Reason: " -NoNewline -ForegroundColor Cyan
            Write-Host $decision.Reason -ForegroundColor DarkGray
        }

        # --- Run the chosen action ---
        $actionResult = $null
        switch ($decision.Action) {
            'FixStartupType' { $actionResult = Invoke-SSMAction-FixStartupType -RG $ResourceGroupName -VM $VMName -Loc $VmLocation -OsType $VmOsType -Timeout $TimeoutSeconds }
            'Restart'        { $actionResult = Invoke-SSMAction-Restart        -RG $ResourceGroupName -VM $VMName -Loc $VmLocation -OsType $VmOsType -Timeout $TimeoutSeconds }
            'Reregister'     { $actionResult = Invoke-SSMAction-Reregister     -RG $ResourceGroupName -VM $VMName -Loc $VmLocation -OsType $VmOsType -PlatformName $Platform -ProxyUrl $HttpProxy -Timeout $TimeoutSeconds }
            'Install'        { $actionResult = Invoke-SSMAction-Install        -RG $ResourceGroupName -VM $VMName -Loc $VmLocation -OsType $VmOsType -PlatformName $Platform -ProxyUrl $HttpProxy -Timeout $TimeoutSeconds }
            'Reinstall'      { $actionResult = Invoke-SSMAction-Reinstall      -RG $ResourceGroupName -VM $VMName -Loc $VmLocation -OsType $VmOsType -PlatformName $Platform -ProxyUrl $HttpProxy -Timeout $TimeoutSeconds }
            default          { Write-Fail "Unknown action: $($decision.Action)"; break }
        }

        if (-not $actionResult) { break }
        $actionHistory += $actionResult

        # --- Record changes & legacy step keys ---
        foreach ($ch in $actionResult.Changes) { [void]$changesMade.Add($ch) }

        # Legacy "Steps" map and BootstrapResults: keep populating so existing
        # consumers (bulk runner, README schema) continue to work.
        $stepKey = switch ($actionResult.Action) {
            'FixStartupType' { 'fixstartup' }
            'Install'        { 'install' }
            'Restart'        { '2' }
            'Reregister'     { '3' }
            'Reinstall'      { '4' }
        }
        $stepNumber = switch ($actionResult.Action) {
            'FixStartupType' { 0 }
            'Install'        { 1 }
            'Restart'        { 2 }
            'Reregister'     { 3 }
            'Reinstall'      { 4 }
        }
        $stepStatus = if ($actionResult.Code -in $script:SSMSuccessCodes) { 'SUCCESS' }
                      elseif ($actionResult.Code -eq 'FAIL_PLATFORM_SERVICES') { 'PLATFORM_SERVICES_FAILED' }
                      elseif ($actionResult.Code -eq 'FAIL_RUN_COMMAND') { 'RUN_COMMAND_FAILED' }
                      else { 'FAILED' }
        $result.Steps[$stepKey] = New-SSMStepResult -StepNumber $stepNumber `
            -Title $actionResult.Action -Risk $script:SSMRiskLabels[$actionResult.Risk] `
            -Status $stepStatus -Messages @($actionResult.Message)

        if ($actionResult.BootstrapResult) {
            $bsKey = switch ($actionResult.Action) {
                'Install'    { 'Install' }
                'Reregister' { 'Step3' }
                'Reinstall'  { 'Step4' }
                default      { $actionResult.Action }
            }
            $result.BootstrapResults[$bsKey] = $actionResult.BootstrapResult
        }

        # --- Success short-circuit ---
        if ($actionResult.Code -in $script:SSMSuccessCodes) {
            $result.FixedAtStep   = $stepNumber
            $result.FixedByAction = $actionResult.Action
            $result.Outcome       = 'RESOLVED'
            break
        }

        # Otherwise, loop back and let the planner pick the next action.
    }
}

# Persist workflow telemetry on the result
$result.ActionHistory = $actionHistory
$result.PlanLog       = $planLog

#endregion

# ---------------------------------------------
# Final Summary
# ---------------------------------------------
if (-not $script:SuppressConsole) {
    # Try to extract agent version and instance ID from bootstrap results or diagnosis
    $summaryVersion    = $null
    $summaryInstanceId = $null
    $summaryRegion     = $result.Region

    # From diagnosis (if agent was already present)
    if ($result.Diagnosis) {
        if ($result.Diagnosis.AgentVersion -and $result.Diagnosis.AgentVersion -ne 'NOT_FOUND') {
            $summaryVersion = $result.Diagnosis.AgentVersion
        }
        if ($result.Diagnosis.InstanceId -and $result.Diagnosis.InstanceId -notin @('N/A','MISSING','ERROR')) {
            $summaryInstanceId = $result.Diagnosis.InstanceId
        }
        if ($result.Diagnosis.DetectedRegion -and -not $summaryRegion) {
            $summaryRegion = $result.Diagnosis.DetectedRegion
        }
    }

    # From bootstrap log output (if install/reinstall succeeded)
    foreach ($bsKey in $result.BootstrapResults.Keys) {
        $bs = $result.BootstrapResults[$bsKey]
        if ($bs.ExitCode -eq 0 -and $bs.LogLines) {
            $logJoined = $bs.LogLines -join "`n"
            if ($logJoined -match '"instance-id"\s*:\s*"(mi-[a-f0-9]+)"') { $summaryInstanceId = $Matches[1] }
            if ($logJoined -match '"release-version"\s*:\s*"([^"]+)"')    { $summaryVersion = $Matches[1] }
            if ($logJoined -match '"region"\s*:\s*"([^"]+)"')             { $summaryRegion = $Matches[1] }
        }
    }

    # Fallback: parse from raw action output
    if (-not $summaryInstanceId -or -not $summaryVersion) {
        foreach ($a in $actionHistory) {
            if ($a.Code -in $script:SSMSuccessCodes -and $a.RawOutput) {
                if (-not $summaryInstanceId -and $a.RawOutput -match '"instance-id"\s*:\s*"(mi-[a-f0-9]+)"') {
                    $summaryInstanceId = $Matches[1]
                }
                if (-not $summaryVersion -and $a.RawOutput -match '"release-version"\s*:\s*"([^"]+)"') {
                    $summaryVersion = $Matches[1]
                }
                if (-not $summaryRegion -and $a.RawOutput -match '"region"\s*:\s*"([^"]+)"') {
                    $summaryRegion = $Matches[1]
                }
            }
        }
    }

    $elapsed = [math]::Round(((Get-Date) - [DateTimeOffset]::Parse($result.StartedAt).LocalDateTime).TotalSeconds)

    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan

    if ($DiagnoseOnly) {
        Write-Host "  DIAGNOSIS COMPLETE" -ForegroundColor Cyan
        Write-Host ("=" * 72) -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  VM           $VMName" -ForegroundColor White
        Write-Host "  OS           $VmOsType" -ForegroundColor White
        Write-Host "  Platform     $Platform" -ForegroundColor White
        if ($result.Diagnosis) {
            $svcColor = if ($result.Diagnosis.Healthy) { 'Green' } elseif ($result.Diagnosis.ServiceStatus -eq 'NOT_INSTALLED') { 'Red' } else { 'Yellow' }
            Write-Host "  Service      $($result.Diagnosis.ServiceStatus)" -ForegroundColor $svcColor
        }
        if ($summaryVersion)    { Write-Host "  Version      $summaryVersion" -ForegroundColor White }
        if ($summaryInstanceId) { Write-Host "  Instance ID  $summaryInstanceId" -ForegroundColor White }
        if ($summaryRegion)     { Write-Host "  Region       $summaryRegion" -ForegroundColor White }
        Write-Host "  Duration     ${elapsed}s" -ForegroundColor DarkGray
        Write-Host "  Timestamp    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
        Write-Host ""
        if ($result.Diagnosis -and $result.Diagnosis.Issues.Count -gt 0) {
            Write-Host "  Issues:" -ForegroundColor Yellow
            foreach ($issue in $result.Diagnosis.Issues) {
                Write-Host "    - $issue" -ForegroundColor Yellow
            }
            Write-Host ""
        }
        Write-Host "  Run without -DiagnoseOnly to apply fixes." -ForegroundColor DarkGray

    } elseif ($result.FixedByAction -or $result.FixedAtStep) {
        Write-Host "  SUCCESS" -ForegroundColor Green
        Write-Host ("=" * 72) -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  VM           $VMName" -ForegroundColor White
        Write-Host "  OS           $VmOsType" -ForegroundColor White
        Write-Host "  Result       " -NoNewline -ForegroundColor White; Write-Host "RESOLVED" -ForegroundColor Green
        Write-Host "  Fixed by     $($result.FixedByAction)" -ForegroundColor Green
        if ($summaryVersion)    { Write-Host "  Version      $summaryVersion" -ForegroundColor White }
        if ($summaryInstanceId) { Write-Host "  Instance ID  $summaryInstanceId" -ForegroundColor Cyan }
        if ($summaryRegion)     { Write-Host "  Region       $summaryRegion" -ForegroundColor White }
        Write-Host "  Duration     ${elapsed}s" -ForegroundColor White
        Write-Host "  Timestamp    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
        if ($changesMade.Count -gt 0) {
            Write-Host ""
            Write-Host "  Changes:" -ForegroundColor Green
            foreach ($change in $changesMade) {
                Write-Host "    + $change" -ForegroundColor Green
            }
        }
        # Pending reboot note
        if ($result.Preflight -and $result.Preflight.PendingReboot) {
            Write-Host ""
            Write-Host "  Note: Pending reboot detected ($($result.Preflight.PendingRebootReasons -join ', '))" -ForegroundColor Yellow
            Write-Host "  The agent is working but a reboot is still advisable." -ForegroundColor DarkGray
        }

    } elseif ($result.EscalationRequired) {
        Write-Host "  ESCALATION REQUIRED" -ForegroundColor Magenta
        Write-Host ("=" * 72) -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  VM           $VMName" -ForegroundColor White
        Write-Host "  OS           $VmOsType" -ForegroundColor White
        Write-Host "  Result       " -NoNewline -ForegroundColor White; Write-Host $result.Outcome -ForegroundColor Magenta
        Write-Host "  Duration     ${elapsed}s" -ForegroundColor White
        Write-Host "  Timestamp    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Reason:" -ForegroundColor Yellow
        Write-Host "  $($result.EscalationReason)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Escalate to #passport-escalations in Teams" -ForegroundColor Yellow
        # Pending reboot note
        if ($result.Preflight -and $result.Preflight.PendingReboot) {
            Write-Host ""
            Write-Host "  Note: Pending reboot detected ($($result.Preflight.PendingRebootReasons -join ', '))" -ForegroundColor Yellow
        }

    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        Write-Host ("=" * 72) -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  VM           $VMName" -ForegroundColor White
        Write-Host "  OS           $VmOsType" -ForegroundColor White
        Write-Host "  Result       " -NoNewline -ForegroundColor White; Write-Host "UNRESOLVED" -ForegroundColor Red
        Write-Host "  Duration     ${elapsed}s" -ForegroundColor White
        Write-Host "  Timestamp    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Actions attempted:" -ForegroundColor DarkGray
        foreach ($a in $actionHistory) {
            $icon = if ($a.Code -in $script:SSMSuccessCodes) { '[OK]' } else { '[X] ' }
            $col  = if ($a.Code -in $script:SSMSuccessCodes) { 'Green' } else { 'Red' }
            Write-Host "    $icon $($a.Action) -> $($a.Code): $($a.Message)" -ForegroundColor $col
        }
        # Pending reboot note
        if ($result.Preflight -and $result.Preflight.PendingReboot) {
            Write-Host ""
            Write-Host "  Note: Pending reboot detected ($($result.Preflight.PendingRebootReasons -join ', '))" -ForegroundColor Yellow
            Write-Host "  A reboot may resolve underlying issues preventing remediation." -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  Manual investigation needed:" -ForegroundColor Yellow
        Write-Host "    - NSG / Azure Firewall blocking outbound 443" -ForegroundColor DarkGray
        Write-Host "    - Proxy misconfiguration" -ForegroundColor DarkGray
        Write-Host "    - Hybrid Activation expired or at registration limit" -ForegroundColor DarkGray
        Write-Host "    - MachineFingerprintDoesNotMatch (VM cloned/restored)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Escalate to #passport-escalations in Teams" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
}

Write-Result -R $result -Changes $changesMade