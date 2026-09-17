param (
    [int]$TargetPID
)

# Import the IIS WebAdministration module
Import-Module WebAdministration

# 1. Map PID to Application Pool using WMI
$workerProcess = Get-WmiObject -Namespace "root\WebAdministration" -Class WorkerProcess -Filter "ProcessId = $TargetPID"

if ($workerProcess) {
    $appPoolName = $workerProcess.AppPoolName
    Write-Output "PID $TargetPID belongs to IIS Application Pool: $appPoolName"
    Write-Output "---------------------------------------------------------"

    # 2. Get Websites associated with this Application Pool
    Write-Output "Associated Websites:"
    Get-Website | Where-Object { $_.applicationPool -eq $appPoolName } | Select-Object Name, Id, State, PhysicalPath | Format-Table -AutoSize
    
    # 3. Get Web Applications associated with this Application Pool
    Write-Output "Associated Web Applications:"
    Get-WebApplication | Where-Object { $_.applicationPool -eq $appPoolName } | Select-Object Site, Name, PhysicalPath | Format-Table -AutoSize
} else {
    Write-Output "No IIS Worker Process (w3wp.exe) found matching PID $TargetPID."
}