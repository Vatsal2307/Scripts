# get-iis-worker-process-info

Maps an **IIS worker process (`w3wp.exe`) PID** to its Application Pool, and lists the
websites and web applications served by that pool. Read-only.

## What it does

Given a process ID, it uses the IIS `WebAdministration` WMI provider to find the owning
application pool, then lists the associated websites (name, ID, state, physical path) and
web applications. Useful when Task Manager shows a busy `w3wp.exe` and you need to know
which site it belongs to.

## Prerequisites

- Run **on the IIS web server itself** (not remotely against Azure)
- Windows with the IIS `WebAdministration` module available
- An elevated (Administrator) PowerShell session

## Usage

```powershell
.\Get-IISWorkerProcessInfo.ps1 -TargetPID 12345
```

## Parameters

| Parameter    | Description                              |
| ------------ | ---------------------------------------- |
| `-TargetPID` | The process ID of the `w3wp.exe` worker. |

## Note

This is a host-level IIS diagnostic script — it does not use the Azure modules.
