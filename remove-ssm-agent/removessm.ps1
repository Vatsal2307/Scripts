$ErrorActionPreference = 'Stop'
 
Write-Output "=== Amazon SSM Agent Uninstall Script ==="
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output ""
 
# --- Stop the service first to ensure clean uninstall (avoids reboot requirement) ---
Write-Output "Checking for AmazonSSMAgent service..."
 
$service = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
 
if ($service) {
    Write-Output "Service found. Status: $($service.Status)"
 
    if ($service.Status -eq 'Running') {
        Write-Output "Stopping AmazonSSMAgent service..."
        Stop-Service -Name 'AmazonSSMAgent' -Force
        Start-Sleep -Seconds 3
        Write-Output "Service stopped."
    }
} else {
    Write-Output "AmazonSSMAgent service not found (may already be removed)."
}
 
# --- Uninstall via MSI (Programs and Features) ---
Write-Output ""
Write-Output "Checking for Amazon SSM Agent in installed programs..."
 
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
 
$ssmEntry = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Amazon SSM*' -or $_.DisplayName -like '*AWS Systems Manager*' }
 
if ($ssmEntry) {
    foreach ($entry in $ssmEntry) {
        Write-Output "Found: $($entry.DisplayName) (Version: $($entry.DisplayVersion))"
        $uninstallString = $entry.UninstallString
 
        if ($uninstallString -match 'msiexec') {
            # Extract the product code if present
            if ($uninstallString -match '\{[A-F0-9\-]+\}') {
                $productCode = $Matches[0]
                Write-Output "Uninstalling via msiexec with product code: $productCode"
                $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru
            } else {
                # Fallback: run the uninstall string directly
                $cleanCmd = $uninstallString -replace 'msiexec.exe\s*', ''
                $cleanCmd = "$cleanCmd /qn /norestart"
                Write-Output "Uninstalling via msiexec: $cleanCmd"
                $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $cleanCmd -Wait -PassThru
            }
            Write-Output "msiexec exit code: $($process.ExitCode)"
        } elseif ($uninstallString) {
            Write-Output "Running uninstall command: $uninstallString"
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$uninstallString`" /quiet /norestart" -Wait -PassThru
            Write-Output "Uninstall exit code: $($process.ExitCode)"
        }
    }
} else {
    Write-Output "No Amazon SSM Agent found in installed programs registry."
}
 
# --- Remove the service if it still exists after uninstall ---
Write-Output ""
Write-Output "Checking if AmazonSSMAgent service still exists..."
 
$service = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
 
if ($service) {
    Write-Output "Service still present. Removing..."
    sc.exe delete 'AmazonSSMAgent'
    Write-Output "Service removal result: $LASTEXITCODE"
} else {
    Write-Output "Service already removed by uninstaller."
}
 
# --- Attempt 3: Clean up installation directories ---
Write-Output ""
Write-Output "Cleaning up residual files..."
 
$paths = @(
    "$env:ProgramFiles\Amazon\SSM",
    "${env:ProgramFiles(x86)}\Amazon\SSM",
    "$env:ProgramData\Amazon\SSM"
)
 
foreach ($path in $paths) {
    if (Test-Path $path) {
        Write-Output "Removing directory: $path"
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $path)) {
            Write-Output "  Removed successfully."
        } else {
            Write-Output "  WARNING: Could not fully remove (files may be locked)."
        }
    }
}
 
# --- Verification ---
Write-Output ""
Write-Output "=== Verification ==="
 
$remainingService = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
$remainingProgram = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Amazon SSM*' -or $_.DisplayName -like '*AWS Systems Manager*' }
 
if (-not $remainingService -and -not $remainingProgram) {
    Write-Output "SUCCESS: Amazon SSM Agent has been fully removed."
} else {
    if ($remainingService) { Write-Output "WARNING: Service still exists." }
    if ($remainingProgram) { Write-Output "WARNING: Program entry still in registry." }
}
 
Write-Output ""
Write-Output "Script completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"