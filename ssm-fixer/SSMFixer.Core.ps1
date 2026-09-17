<#
.SYNOPSIS
    Core types and workflow engine for SSM Fixer.

.DESCRIPTION
    Single shared module dot-sourced by Invoke-SSMFixer.ps1. Combines the
    output schema (factory functions for structured result objects) and the
    state-machine planner (action codes and the Get-NextSSMAction function)
    so consumers only need to load one file.

    Sections:
      1. Schema version
      2. Output schema factories
            New-SSMFixerResult           - top-level result envelope
            New-SSMDiagnosis             - Step-1 agent diagnostics
            New-SSMEndpointResult        - one connectivity test
            New-SSMCliCheck              - one ssm-cli diagnostic row
            New-SSMStepResult            - legacy "step N" outcome record
            New-SSMBootstrapResult       - bootstrap.ps1/.py invocation result
            New-SSMRunCommandFailure     - Azure Run Command failure data
            Complete-SSMFixerResult      - finalise timings and outcome
      3. Bootstrap exit code reference
            $script:BootstrapExitCodes        - exit code -> human message
            $script:PlatformServicesExitCodes - codes that indicate off-VM failure
      4. Workflow engine
            $script:SSMActions / SSMActionCodes / SSMActionRisk / SSMRiskLabels
            $script:SSMSuccessCodes / SSMTerminalFailureCodes
            New-SSMActionResult          - one action's outcome record
            New-SSMPlanDecision          - one planner decision record
            Get-SSMActionCodeFromBootstrap - exit code -> action result code
            Get-SSMActionAttempts        - count attempts per action
            Test-SSMDiagBool             - tolerate string vs bool from JSON
            Get-NextSSMAction            - the planner (pure function)
            Get-SSMPlannedAction         - planner helper (applies MaxRisk cap)
            Convert-SSMMaxStepToRisk     - -MaxStep parameter -> risk cap
#>


# ============================================================================
# 1. Schema version
# ============================================================================

# Bump on breaking changes to the output JSON shape.
$script:SSMFixerSchemaVersion = '1.3.0'


# ============================================================================
# 2. Output schema factories
# ============================================================================

function New-SSMFixerResult {
    <#
    .SYNOPSIS  Creates the top-level result envelope.
    #>
    param(
        [string]$VMName,
        [string]$ResourceGroupName,
        [string]$OsType,
        [string]$Region,
        [string]$Platform,
        [bool]$DiagnoseOnly,
        [int]$TimeoutSeconds,
        [int]$MaxStep,
        [int]$SkipToStep
    )

    [PSCustomObject]@{
        SchemaVersion     = $script:SSMFixerSchemaVersion
        VMName            = $VMName
        ResourceGroupName = $ResourceGroupName
        OsType            = $OsType
        Region            = $Region
        Platform          = $Platform
        DiagnoseOnly      = $DiagnoseOnly
        TimeoutSeconds    = $TimeoutSeconds
        MaxStep           = $MaxStep
        SkipToStep        = $SkipToStep
        StartedAt         = (Get-Date -Format 'o')
        CompletedAt       = $null
        Duration          = $null
        # Populated during execution
        Preflight         = $null   # New-SSMPreflightResult
        Diagnosis         = $null   # New-SSMDiagnosis
        Connectivity      = @()     # New-SSMEndpointResult[]
        Proxy             = @()     # string[]
        SsmCliDiagnostics = @()     # New-SSMCliCheck[]
        LogErrors         = @()     # string[]
        Steps             = @{}     # step-number -> New-SSMStepResult (legacy view)
        ActionHistory     = @()     # New-SSMActionResult[] - every action attempted, in order
        PlanLog           = @()     # New-SSMPlanDecision[]  - every planner decision, in order
        Changes           = @()     # string[]
        Outcome           = $null   # see SSM Fixer outcome codes table below
        FixedAtStep       = $null   # int or null (legacy: numeric step that resolved it)
        FixedByAction     = $null   # string or null - the action name that resolved it
        RunCommandFailure = $null   # New-SSMRunCommandFailure or null
        BootstrapResults  = @{}     # step-key -> New-SSMBootstrapResult
        EscalationRequired = $false # true when something off-VM is the blocker
        EscalationReason   = $null  # string
        Error             = $null   # string - top-level error if the script itself failed
    }
}

# SSM Fixer Outcome codes (kept centralised so the planner and the schema agree):
#   RESOLVED                          - agent is healthy after action(s)
#   UNRESOLVED                        - all viable actions tried, agent still unhealthy
#   DIAGNOSED                         - diagnose-only run completed
#   ERROR                             - the fixer itself failed (top-level exception)
#   PLATFORM_SERVICES_UNAVAILABLE     - Rackspace Platform Services 5xx (off-VM)
#   PLATFORM_SERVICES_REJECTED        - Rackspace Platform Services 4xx (off-VM)
#   INSTALL_FAILED                    - install failed and -MaxStep blocks further remediation
#   INSTALL_FAILED_NETWORK            - install failed at download/HTTP layer (NSG/proxy/DNS)
#   INSTALL_FAILED_UNSUPPORTED_OS     - bootstrap rejected the VM as unsupported
#   RUN_COMMAND_FAILED                - Azure Run Command itself can't reach the VM

function New-SSMDiagnosis {
    <#
    .SYNOPSIS  Captures Step 1 agent diagnostics from the remote VM.
    #>
    param(
        [string]$ServiceStatus,
        [string]$StartType,
        [string]$AgentVersion,
        [object]$RegistrationExists,   # bool or string 'true'/'false'
        [object]$RegistrationAgeDays,  # number or -1
        [string]$DetectedRegion,
        [object]$FingerprintExists,    # bool or string
        [object]$SsmCliExists,         # bool or string
        [string]$InstanceId,
        [object]$AgentExeExists = $null,
        [string[]]$LogErrors = @()
    )

    # Normalise booleans that may arrive as strings from Linux JSON
    $regBool = $RegistrationExists -eq $true -or $RegistrationExists -eq 'true'
    $fpBool  = $FingerprintExists  -eq $true -or $FingerprintExists  -eq 'true'
    $cliBool = $SsmCliExists       -eq $true -or $SsmCliExists       -eq 'true'
    $exeBool = if ($null -eq $AgentExeExists) { $null }
               else { $AgentExeExists -eq $true -or $AgentExeExists -eq 'true' }

    [PSCustomObject]@{
        ServiceStatus      = $ServiceStatus
        StartType          = $StartType
        AgentVersion       = if ($AgentVersion) { $AgentVersion } else { 'NOT_FOUND' }
        RegistrationExists = $regBool
        RegistrationAgeDays = $RegistrationAgeDays
        DetectedRegion     = $DetectedRegion
        FingerprintExists  = $fpBool
        SsmCliExists       = $cliBool
        AgentExeExists     = $exeBool
        InstanceId         = if ($InstanceId) { $InstanceId } else { 'N/A' }
        LogErrors          = @($LogErrors)
        Issues             = @()   # string[] - populated by caller
        Healthy            = $false
    }
}

function New-SSMEndpointResult {
    <#
    .SYNOPSIS  One endpoint connectivity test result.
    #>
    param(
        [string]$Endpoint,
        [string]$Status,     # PASS | FAIL
        [string]$DnsOk,
        [string]$PortOk
    )

    [PSCustomObject]@{
        Endpoint = $Endpoint
        Status   = $Status
        DnsOk    = $DnsOk
        PortOk   = $PortOk
    }
}

function New-SSMCliCheck {
    <#
    .SYNOPSIS  One row from ssm-cli get-diagnostics output.
    #>
    param(
        [string]$Check,
        [string]$Status,   # Success | Failed | Skipped
        [string]$Note
    )

    [PSCustomObject]@{
        Check  = $Check
        Status = $Status
        Note   = $Note
    }
}

function New-SSMStepResult {
    <#
    .SYNOPSIS  Outcome of a single remediation step (legacy view).
    .DESCRIPTION
        Kept for backwards compatibility with consumers that read result.Steps.
        New code should read result.ActionHistory instead.
    #>
    param(
        [int]$StepNumber,
        [string]$Title,
        [string]$Risk,
        [string]$Status,    # SUCCESS | FAILED | SKIPPED | NOT_RUN | PLATFORM_SERVICES_FAILED | RUN_COMMAND_FAILED
        [string[]]$Messages = @()
    )

    [PSCustomObject]@{
        StepNumber = $StepNumber
        Title      = $Title
        Risk       = $Risk
        Status     = $Status
        Messages   = $Messages
    }
}


# ============================================================================
# 3. Bootstrap exit code reference
# ============================================================================
# Source: bootstrap.ps1 header comments. Maps Rackspace bootstrap exit codes
# to human-readable messages. Get-SSMActionCodeFromBootstrap (below) classifies
# them into the smaller set of action result codes the planner uses.

$script:BootstrapExitCodes = @{
    0   = 'Success'
    100 = "Failed to install 'Amazon SSM Agent'"
    101 = "Failed to uninstall 'Amazon SSM Agent'"
    103 = "Unable to stop 'AmazonSsmAgent' service"
    104 = "'AmazonSsmAgent' service did not reach 'running' status"
    105 = 'GET request to activation job url failed'
    106 = 'SSM agent activation job was not successful (Rackspace Platform Services)'
    107 = 'Agent activation job did not complete after multiple attempts (Rackspace Platform Services)'
    108 = 'POST request to activation url failed (Rackspace Platform Services)'
    109 = 'POST request to activation url did not return a Location header (Rackspace Platform Services)'
    110 = 'Failed to execute agent registration command'
    111 = 'Failed to execute agent diagnostics command'
    112 = 'Management agent was not registered successfully'
    113 = "'ssm-cli.exe' command does not exist"
    114 = 'Failed to execute clear agent registration command'
    115 = 'HTTP request failed while installing Amazon SSM Agent'
    116 = "Package 'AmazonSsmAgent' is not currently installed"
    117 = 'HTTP request failed while uninstalling Amazon SSM Agent'
    118 = 'Could not retrieve token after multiple attempts'
    119 = 'VMWare/OpenStack get token command failed'
    120 = 'GET request to metadata instance url failed'
    121 = 'GET request to metadata attest url failed'
    122 = 'Token file not found (dedicated)'
    123 = 'Token file is empty (dedicated)'
    124 = 'GET request to instance identity url failed'
    125 = 'GET request to instance metadata identity url failed'
    126 = 'Downloading agent package installer failed'
    127 = "'amazon-ssm-agent' command not found"
    128 = 'SSM package is not installed, cannot reregister agent'
    129 = "'ssm-cli' command does not exist"
    133 = 'Unsupported Windows product type (Server / DC only)'
    134 = 'Unsupported Windows version'
    135 = 'Only 64-bit Windows is supported'
    136 = "'rpctool' command does not exist"
    137 = 'Could not retrieve OpenStack auth token'
    138 = 'OpenStack vendordata API returned an error'
    144 = 'Uncaught exception'
}

# Exit codes that indicate the failure is on the Rackspace Platform Services
# side (not on the VM). These short-circuit escalation rather than fall
# through to progressively more destructive remediation steps.
$script:PlatformServicesExitCodes = @(105, 106, 107, 108, 109)

function New-SSMBootstrapResult {
    <#
    .SYNOPSIS  Captures the outcome of a bootstrap.ps1 / bootstrap.py invocation.
    .DESCRIPTION
        Includes the exit code, a human-readable description, and - if the
        agent failed to register because of Rackspace Platform Services - the
        HTTP status and URL from the activation POST so the caller can
        escalate with the right context.
    #>
    param(
        [string]$Command,                           # Install | Reregister | Uninstall
        [Nullable[int]]$ExitCode = $null,
        [string]$ExitCodeMessage,
        [string]$ActivationUrl,
        [Nullable[int]]$ActivationHttpStatus = $null,
        [string[]]$LogLines = @(),
        [string]$DurationSeconds
    )

    if (-not $ExitCodeMessage -and $null -ne $ExitCode) {
        $ExitCodeMessage = $script:BootstrapExitCodes[[int]$ExitCode]
        if (-not $ExitCodeMessage) { $ExitCodeMessage = "Unknown exit code $ExitCode" }
    }

    $isPlatformSvc = $false
    if ($null -ne $ExitCode -and $script:PlatformServicesExitCodes -contains [int]$ExitCode) {
        $isPlatformSvc = $true
    }
    if ($ActivationHttpStatus -and [int]$ActivationHttpStatus -ge 500 -and [int]$ActivationHttpStatus -le 599) {
        $isPlatformSvc = $true
    }

    [PSCustomObject]@{
        Command                  = $Command
        ExitCode                 = $ExitCode
        ExitCodeMessage          = $ExitCodeMessage
        ActivationUrl            = $ActivationUrl
        ActivationHttpStatus     = $ActivationHttpStatus
        PlatformServicesFailure  = $isPlatformSvc
        LogLines                 = $LogLines
        DurationSeconds          = $DurationSeconds
    }
}

function New-SSMRunCommandFailure {
    <#
    .SYNOPSIS  Captures Azure Run Command failure diagnosis data.
    #>
    param(
        [string]$PowerState,
        [string]$ProvisioningState,
        [string]$AzureAgentVersion,
        [string]$AzureAgentStatus,
        [string[]]$Issues = @(),
        [object[]]$StuckRunCommands = @(),
        [object[]]$RemediationOptions = @()
    )

    [PSCustomObject]@{
        PowerState         = $PowerState
        ProvisioningState  = $ProvisioningState
        AzureAgentVersion  = $AzureAgentVersion
        AzureAgentStatus   = $AzureAgentStatus
        Issues             = $Issues
        StuckRunCommands   = $StuckRunCommands
        RemediationOptions = $RemediationOptions
    }
}

function New-SSMPreflightResult {
    <#
    .SYNOPSIS
        Captures the outcome of the preflight probe (Run Command responsiveness
        + pending-reboot check) that runs before Step 1 diagnostics.
    .DESCRIPTION
        Run Command non-responsiveness and a pending reboot are both common
        causes of remediation failure that don't show up in agent diagnostics.
        Catching them up front saves time and produces clearer escalation
        messages than letting later steps time out or wedge MSI.
    #>
    param(
        [string]$Status = 'NOT_RUN',                 # OK | RUN_COMMAND_FAILED | NOT_RUN
        [string]$Hostname,
        [Nullable[double]]$DurationSeconds = $null,
        [bool]$PendingReboot = $false,
        [string[]]$PendingRebootReasons = @(),       # e.g. CBS, WindowsUpdate, PendingFileRename, ComputerRename
        [string]$Message = ''
    )

    [PSCustomObject]@{
        Status                = $Status
        Hostname              = $Hostname
        DurationSeconds       = $DurationSeconds
        PendingReboot         = $PendingReboot
        PendingRebootReasons  = $PendingRebootReasons
        Message               = $Message
    }
}

function Complete-SSMFixerResult {
    <#
    .SYNOPSIS  Finalises the result object with timing and outcome.
    #>
    param(
        [PSCustomObject]$Result
    )

    $Result.CompletedAt = Get-Date -Format 'o'
    $start = [DateTimeOffset]::Parse($Result.StartedAt)
    $end   = [DateTimeOffset]::Parse($Result.CompletedAt)
    $Result.Duration = [math]::Round(($end - $start).TotalSeconds, 1)

    # Outcomes the workflow planner may have set explicitly - don't overwrite
    # them with the generic UNRESOLVED.
    $explicitOutcomes = @(
        'PLATFORM_SERVICES_UNAVAILABLE','PLATFORM_SERVICES_REJECTED',
        'INSTALL_FAILED','INSTALL_FAILED_NETWORK','INSTALL_FAILED_UNSUPPORTED_OS',
        'RUN_COMMAND_FAILED','RESOLVED','UNRESOLVED','DIAGNOSED'
    )

    if ($Result.Error) {
        $Result.Outcome = 'ERROR'
    } elseif ($Result.DiagnoseOnly -and -not $Result.Outcome) {
        $Result.Outcome = 'DIAGNOSED'
    } elseif ($Result.FixedAtStep -or $Result.FixedByAction) {
        if (-not $Result.Outcome -or $Result.Outcome -notin $explicitOutcomes -or $Result.Outcome -in @('UNRESOLVED','DIAGNOSED')) {
            $Result.Outcome = 'RESOLVED'
        }
    } elseif (-not $Result.Outcome -or $Result.Outcome -notin $explicitOutcomes) {
        $Result.Outcome = 'UNRESOLVED'
    }

    return $Result
}


# ============================================================================
# 4. Workflow engine
# ============================================================================
# State-machine planner: diagnose, plan next action based on current state and
# action history, execute, classify, repeat. Each remediation action returns
# one of $script:SSMActionCodes; the planner inspects only those codes (plus
# the diagnosis) to decide what to do next.

# --- Stable action names ---
$script:SSMActions = @{
    Diagnose       = 'Diagnose'
    FixStartupType = 'FixStartupType'
    Restart        = 'Restart'
    Reregister     = 'Reregister'
    Install        = 'Install'
    Reinstall      = 'Reinstall'
    Stop           = 'Stop'
}

# --- Action result codes ---
# Every remediation action returns one of these, regardless of OS or step.
$script:SSMActionCodes = @{
    OK                      = 'OK'                      # Action ran AND post-condition (agent healthy) verified
    OK_NO_VERIFY            = 'OK_NO_VERIFY'            # Action ran cleanly but health was not re-checked
    FAIL_NETWORK            = 'FAIL_NETWORK'            # Download / connectivity failure (NSG / proxy / DNS / port 443)
    FAIL_PLATFORM_SERVICES  = 'FAIL_PLATFORM_SERVICES'  # Rackspace Platform Services rejected/unavailable (off-VM)
    FAIL_UNSUPPORTED_OS     = 'FAIL_UNSUPPORTED_OS'     # Bootstrap exit 133/134/135 - terminal
    FAIL_PRECONDITION       = 'FAIL_PRECONDITION'       # Action's precondition not met
    FAIL_TRANSIENT          = 'FAIL_TRANSIENT'          # Run Command timeout / partial output / no exit code
    FAIL_UNHEALTHY_AFTER    = 'FAIL_UNHEALTHY_AFTER'    # Action ran cleanly but health check still fails
    FAIL_UNKNOWN            = 'FAIL_UNKNOWN'            # Unrecognised / unmapped failure
    FAIL_RUN_COMMAND        = 'FAIL_RUN_COMMAND'        # Azure Run Command itself failed (off-agent)
}

# --- Risk per action (used to honour -MaxStep) ---
# 0 = No risk, 1 = Low, 2 = Medium, 3 = High
$script:SSMActionRisk = @{
    Diagnose       = 0
    FixStartupType = 0
    Install        = 1
    Restart        = 1
    Reregister     = 2
    Reinstall      = 3
    Stop           = 0
}
$script:SSMRiskLabels = @('No', 'Low', 'Medium', 'High')

# --- Code groupings ---
$script:SSMSuccessCodes = @('OK', 'OK_NO_VERIFY')
# Codes that should immediately terminate the workflow regardless of remaining
# attempts (planner short-circuits on these).
$script:SSMTerminalFailureCodes = @(
    'FAIL_PLATFORM_SERVICES'
    'FAIL_NETWORK'
    'FAIL_UNSUPPORTED_OS'
    'FAIL_RUN_COMMAND'
)

function New-SSMActionResult {
    <#
    .SYNOPSIS
        Factory for a single action's outcome record.
    .DESCRIPTION
        Captures everything we need to: (a) report to the user, (b) feed the
        next planner call, (c) include in the JSON output. The orchestrator
        appends one of these to ActionHistory after each action runs.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Code,
        [string]$Message = '',
        [PSCustomObject]$BootstrapResult = $null,
        [string[]]$Changes = @(),
        [string]$RawOutput = ''
    )
    [PSCustomObject]@{
        Action          = $Action
        Code            = $Code
        Risk            = $script:SSMActionRisk[$Action]
        Message         = $Message
        BootstrapResult = $BootstrapResult
        Changes         = $Changes
        RawOutput       = $RawOutput
        Timestamp       = Get-Date -Format 'o'
    }
}

function New-SSMPlanDecision {
    <#
    .SYNOPSIS
        Factory for a single planner decision (what the planner chose, and why).
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason,
        [int]$Risk = 0,
        [bool]$Terminal = $false,
        [string]$Outcome = $null
    )
    [PSCustomObject]@{
        Action    = $Action
        Reason    = $Reason
        Risk      = $Risk
        RiskLabel = $script:SSMRiskLabels[$Risk]
        Terminal  = $Terminal
        Outcome   = $Outcome
        Timestamp = Get-Date -Format 'o'
    }
}

function Get-SSMActionCodeFromBootstrap {
    <#
    .SYNOPSIS
        Maps a bootstrap exit code into one of the standard action result codes.
    .DESCRIPTION
        Returns one of: OK_NO_VERIFY, FAIL_NETWORK, FAIL_PLATFORM_SERVICES,
        FAIL_UNSUPPORTED_OS, FAIL_TRANSIENT, FAIL_UNKNOWN.
    #>
    param([PSCustomObject]$BootstrapResult)

    if (-not $BootstrapResult)              { return 'FAIL_TRANSIENT' }
    $exit = $BootstrapResult.ExitCode
    if ($null -eq $exit)                    { return 'FAIL_TRANSIENT' }
    if ([int]$exit -eq 0)                   { return 'OK_NO_VERIFY' }
    if ($BootstrapResult.PlatformServicesFailure) { return 'FAIL_PLATFORM_SERVICES' }

    # Network / download failures - Step 4 (reinstall) cannot help, escalate.
    $networkCodes     = @(115, 117, 118, 126)   # HTTP failures, downloader failures
    $unsupportedCodes = @(133, 134, 135)        # Wrong product type / version / arch - terminal

    if ($networkCodes     -contains [int]$exit) { return 'FAIL_NETWORK' }
    if ($unsupportedCodes -contains [int]$exit) { return 'FAIL_UNSUPPORTED_OS' }

    # Other documented codes (100/101/103/104/110/111/112/127/128/144 etc.)
    # generally mean the install/uninstall pipeline broke in a way that a
    # cleanup-and-retry (Reinstall) might fix.
    return 'FAIL_UNKNOWN'
}

function Get-SSMActionAttempts {
    <#
    .SYNOPSIS
        Counts how many times each action has been attempted, from the history.
    .OUTPUTS
        Hashtable keyed by action name, value is integer count.
    #>
    param([object[]]$History = @())
    $counts = @{}
    foreach ($h in $History) {
        if (-not $h -or -not $h.Action) { continue }
        if (-not $counts.ContainsKey($h.Action)) { $counts[$h.Action] = 0 }
        $counts[$h.Action]++
    }
    return $counts
}

function Test-SSMDiagBool {
    # Diagnostic JSON booleans can come back as literal $true/$false or as
    # the strings 'true'/'false' (Linux). Normalise.
    param($Value)
    return ($Value -eq $true -or $Value -eq 'true')
}

function Get-NextSSMAction {
    <#
    .SYNOPSIS
        State-machine planner. Decides the next remediation action based on
        the current diagnosis and the history of actions already attempted.

    .DESCRIPTION
        Pure function - no I/O. Returns a New-SSMPlanDecision describing the
        next action. When no further action will help (success, terminal
        failure, or all options exhausted), returns Action='Stop' with
        Terminal=$true and a populated Outcome.

        Decision tree (high level):

            healthy?                     -> Stop / RESOLVED
            last action terminal-failed? -> Stop / <matching outcome>
            agent NOT_INSTALLED?
                Install never tried      -> Install
                Install tried, unhealthy -> Reinstall
                Reinstall tried          -> Stop / UNRESOLVED
            binaries missing?            -> Reinstall (or Stop if already tried)
            startup type wrong (only)?   -> FixStartupType
            identity / registration MISSING but binaries OK?
                Reregister never tried   -> Reregister
                Reregister tried         -> Reinstall
                Reinstall tried          -> Stop / UNRESOLVED
            service not running but rest OK?
                Restart never tried      -> Restart
                Restart tried            -> Reregister
                Reregister tried         -> Reinstall
                Reinstall tried          -> Stop / UNRESOLVED
            generic unhealthy            -> escalate Restart -> Reregister -> Reinstall

        Each action is attempted at most once (the planner escalates after one
        try). MaxRisk caps the ladder - if the chosen action's risk exceeds
        MaxRisk, the planner returns Stop instead.

    .PARAMETER Diagnosis
        The Diagnosis object from Step 1 (New-SSMDiagnosis output).

    .PARAMETER History
        Array of New-SSMActionResult records, oldest first.

    .PARAMETER MaxRisk
        Maximum action risk to allow (0=No, 1=Low, 2=Medium, 3=High).
        Default 3 (allow everything up to and including Reinstall).

    .PARAMETER DiagnoseOnly
        When $true, planner always returns Stop / DIAGNOSED.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Diagnosis,
        [object[]]$History = @(),
        [int]$MaxRisk = 3,
        [bool]$DiagnoseOnly = $false
    )

    # --- Trivial gates ---
    if ($DiagnoseOnly) {
        return (New-SSMPlanDecision -Action 'Stop' `
            -Reason 'Diagnose-only mode - no remediation will be attempted' `
            -Terminal $true -Outcome 'DIAGNOSED')
    }

    if ($Diagnosis -and $Diagnosis.Healthy) {
        return (New-SSMPlanDecision -Action 'Stop' `
            -Reason 'Agent is healthy - no action needed' `
            -Terminal $true -Outcome 'RESOLVED')
    }

    # --- Short-circuit on the previous action's terminal failure ---
    $last = if ($History.Count -gt 0) { $History[-1] } else { $null }
    if ($last) {
        switch ($last.Code) {
            'FAIL_PLATFORM_SERVICES' {
                $bs = $last.BootstrapResult
                $http = if ($bs) { $bs.ActivationHttpStatus } else { $null }
                $outcome = if ($http -and [int]$http -ge 500) { 'PLATFORM_SERVICES_UNAVAILABLE' } else { 'PLATFORM_SERVICES_REJECTED' }
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Rackspace Platform Services rejected the request - failure is off-VM. Escalate to #passport-escalations." `
                    -Terminal $true -Outcome $outcome)
            }
            'FAIL_NETWORK' {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Network failure during bootstrap (download/HTTP). Reinstall would re-fail at the same hop. Resolve NSG/proxy/DNS to add-ons.manage.rackspace.com and AWS S3, then retry." `
                    -Terminal $true -Outcome 'INSTALL_FAILED_NETWORK')
            }
            'FAIL_UNSUPPORTED_OS' {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Bootstrap rejected this VM as unsupported (wrong OS edition, version, or architecture). No remediation possible." `
                    -Terminal $true -Outcome 'INSTALL_FAILED_UNSUPPORTED_OS')
            }
            'FAIL_RUN_COMMAND' {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Azure Run Command cannot reach the VM. This is an Azure VM agent issue, not an SSM agent issue." `
                    -Terminal $true -Outcome 'RUN_COMMAND_FAILED')
            }
        }
    }

    # --- Build attempt counts ---
    $attempts = Get-SSMActionAttempts -History $History

    # Helper: did we attempt this action already?
    $tried = { param($name) $attempts.ContainsKey($name) -and $attempts[$name] -gt 0 }

    # --- Read diagnosis ---
    $svc        = $Diagnosis.ServiceStatus
    $startType  = $Diagnosis.StartType
    $regOk      = Test-SSMDiagBool $Diagnosis.RegistrationExists
    $instId     = $Diagnosis.InstanceId
    $exeOk      = Test-SSMDiagBool $Diagnosis.AgentExeExists
    $cliOk      = Test-SSMDiagBool $Diagnosis.SsmCliExists
    $binariesOk = $exeOk -or $cliOk
    $svcRunning = $svc -in @('Running', 'active')
    $startTypeOk = $startType -in @('Automatic', 'enabled')

    # ----------------------------------------------------------------------
    # Branch A - Agent is NOT INSTALLED
    # ----------------------------------------------------------------------
    if ($svc -eq 'NOT_INSTALLED') {
        if (& $tried 'Install') {
            # Install was attempted. Terminal codes were caught above; we got here
            # because the install was FAIL_UNHEALTHY_AFTER, FAIL_UNKNOWN, or
            # FAIL_TRANSIENT. Try Reinstall (cleanup + retry) once.
            if (& $tried 'Reinstall') {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Install and Reinstall both attempted; agent still not present. Escalate." `
                    -Terminal $true -Outcome 'UNRESOLVED')
            }
            return (Get-SSMPlannedAction -Action 'Reinstall' `
                -Reason "Fresh install did not produce a healthy agent - escalate to cleanup + reinstall." `
                -MaxRisk $MaxRisk)
        }
        return (Get-SSMPlannedAction -Action 'Install' `
            -Reason "Agent not installed - fresh install via bootstrap." `
            -MaxRisk $MaxRisk)
    }

    # ----------------------------------------------------------------------
    # Branch B - Service entry exists but binaries are missing (corrupt install)
    # ----------------------------------------------------------------------
    if (-not $binariesOk) {
        if (& $tried 'Reinstall') {
            return (New-SSMPlanDecision -Action 'Stop' `
                -Reason "Agent binaries still missing after Reinstall. Escalate." `
                -Terminal $true -Outcome 'UNRESOLVED')
        }
        return (Get-SSMPlannedAction -Action 'Reinstall' `
            -Reason "Service entry exists but agent binaries are missing - corrupt install." `
            -MaxRisk $MaxRisk)
    }

    # ----------------------------------------------------------------------
    # Branch C - Only issue is wrong startup type
    # ----------------------------------------------------------------------
    $startTypeWrong = (-not $startTypeOk) -and $startType -ne 'N/A'
    $registeredOk   = $regOk -and ($instId -notin @('MISSING', 'ERROR'))
    if ($startTypeWrong -and $svcRunning -and $registeredOk -and -not (& $tried 'FixStartupType')) {
        return (Get-SSMPlannedAction -Action 'FixStartupType' `
            -Reason "Startup type is '$startType' (should be Automatic/enabled). Service is otherwise healthy." `
            -MaxRisk $MaxRisk)
    }

    # ----------------------------------------------------------------------
    # Branch D - Identity / registration missing (but binaries present)
    # ----------------------------------------------------------------------
    $identityMissing = ($instId -in @('MISSING', 'ERROR')) -or (-not $regOk)
    if ($identityMissing -and $binariesOk) {
        if (& $tried 'Reregister') {
            if (& $tried 'Reinstall') {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Reregister and Reinstall both attempted; identity still missing. Escalate." `
                    -Terminal $true -Outcome 'UNRESOLVED')
            }
            return (Get-SSMPlannedAction -Action 'Reinstall' `
                -Reason "Reregister did not restore agent identity - escalate to full reinstall." `
                -MaxRisk $MaxRisk)
        }
        $why = if (-not $regOk) { "registration file is missing" } else { "instance ID is $instId" }
        return (Get-SSMPlannedAction -Action 'Reregister' `
            -Reason "Binaries present but $why - clear and re-register." `
            -MaxRisk $MaxRisk)
    }

    # ----------------------------------------------------------------------
    # Branch D2 - Fingerprint mismatch in recent agent logs
    # ----------------------------------------------------------------------
    # Typical after VM clone, snapshot restore, or any change to host
    # identifiers (UUID, MAC). The agent is registered and running, but
    # credential refresh fails because the fingerprint AWS has on record no
    # longer matches the host. Re-register clears the Vault and bootstrap
    # generates a fresh fingerprint - no MSI work needed. If Reregister
    # doesn't resolve it, escalate straight to Reinstall - Restart cannot
    # fix a fingerprint mismatch and would just waste a step.
    $fpMismatch = $false
    if ($Diagnosis.LogErrors) {
        foreach ($err in $Diagnosis.LogErrors) {
            if ($err -match 'MachineFingerprintDoesNotMatch') { $fpMismatch = $true; break }
        }
    }
    if ($fpMismatch -and $binariesOk) {
        if (& $tried 'Reregister') {
            if (& $tried 'Reinstall') {
                return (New-SSMPlanDecision -Action 'Stop' `
                    -Reason "Fingerprint mismatch persists after Reregister and Reinstall. Escalate." `
                    -Terminal $true -Outcome 'UNRESOLVED')
            }
            return (Get-SSMPlannedAction -Action 'Reinstall' `
                -Reason "Reregister did not clear MachineFingerprintDoesNotMatch - escalate to full reinstall." `
                -MaxRisk $MaxRisk)
        }
        return (Get-SSMPlannedAction -Action 'Reregister' `
            -Reason "Agent log: MachineFingerprintDoesNotMatch (typical after VM clone/restore) - clear and re-register." `
            -MaxRisk $MaxRisk)
    }

    # ----------------------------------------------------------------------
    # Branch E - Service not running, everything else OK
    # ----------------------------------------------------------------------
    if (-not $svcRunning -and $registeredOk -and $binariesOk) {
        if (-not (& $tried 'Restart')) {
            return (Get-SSMPlannedAction -Action 'Restart' `
                -Reason "Service is '$svc' but binaries and registration are intact." `
                -MaxRisk $MaxRisk)
        }
        if (-not (& $tried 'Reregister')) {
            return (Get-SSMPlannedAction -Action 'Reregister' `
                -Reason "Restart did not bring the service up - try clearing and re-registering." `
                -MaxRisk $MaxRisk)
        }
        if (-not (& $tried 'Reinstall')) {
            return (Get-SSMPlannedAction -Action 'Reinstall' `
                -Reason "Restart and Reregister both failed to start the service - full reinstall." `
                -MaxRisk $MaxRisk)
        }
        return (New-SSMPlanDecision -Action 'Stop' `
            -Reason "Service still not running after Restart, Reregister, and Reinstall. Escalate." `
            -Terminal $true -Outcome 'UNRESOLVED')
    }

    # ----------------------------------------------------------------------
    # Branch F - Generic unhealthy (issues found but not matching the above
    # specific patterns). Escalate progressively.
    # ----------------------------------------------------------------------
    if (-not (& $tried 'Restart')) {
        return (Get-SSMPlannedAction -Action 'Restart' `
            -Reason "Issues detected but no specific pattern matched - start with low-risk restart." `
            -MaxRisk $MaxRisk)
    }
    if (-not (& $tried 'Reregister')) {
        return (Get-SSMPlannedAction -Action 'Reregister' `
            -Reason "Restart did not resolve the issue - escalate to re-register." `
            -MaxRisk $MaxRisk)
    }
    if (-not (& $tried 'Reinstall')) {
        return (Get-SSMPlannedAction -Action 'Reinstall' `
            -Reason "Restart and Reregister did not resolve the issue - escalate to full reinstall." `
            -MaxRisk $MaxRisk)
    }
    return (New-SSMPlanDecision -Action 'Stop' `
        -Reason "Restart, Reregister, and Reinstall all attempted without success. Escalate." `
        -Terminal $true -Outcome 'UNRESOLVED')
}

function Get-SSMPlannedAction {
    <#
    .SYNOPSIS
        Internal helper: wraps a planner choice and applies the MaxRisk cap.
    .DESCRIPTION
        If the chosen action's risk exceeds MaxRisk, returns Stop instead so
        the orchestrator surfaces a clear "MaxStep cap blocks further
        remediation" message rather than silently doing nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason,
        [int]$MaxRisk = 3
    )

    $risk = $script:SSMActionRisk[$Action]
    if ($null -eq $risk) { $risk = 0 }

    if ($risk -gt $MaxRisk) {
        $maxLabel = $script:SSMRiskLabels[$MaxRisk]
        return (New-SSMPlanDecision -Action 'Stop' `
            -Reason "Next action would be '$Action' ($($script:SSMRiskLabels[$risk]) risk) but -MaxStep limits remediation to $maxLabel risk. $Reason. Re-run with a higher -MaxStep to attempt this." `
            -Terminal $true -Outcome 'UNRESOLVED')
    }

    return (New-SSMPlanDecision -Action $Action -Reason $Reason -Risk $risk)
}

function Convert-SSMMaxStepToRisk {
    <#
    .SYNOPSIS
        Maps the user-facing -MaxStep parameter (1-4) to the internal risk
        cap used by the planner.
    .DESCRIPTION
        -MaxStep 1: only diagnostics / FixStartupType / Install (Low).
        -MaxStep 2: also allow Restart (Low).  Same risk cap as MaxStep 1.
        -MaxStep 3: also allow Reregister (Medium).
        -MaxStep 4: also allow Reinstall (High). Default.
    #>
    param([int]$MaxStep)
    switch ($MaxStep) {
        1       { return 1 }
        2       { return 1 }
        3       { return 2 }
        4       { return 3 }
        default { return 3 }
    }
}