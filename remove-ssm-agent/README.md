# remove-ssm-agent

Uninstalls the **Amazon SSM Agent** from a VM. Two implementations for the two OS families:

- `removessm.ps1` — Windows
- `Remove-AzLinuxSSM.sh` — Linux

Both are designed to run **on the target VM** (directly, or pasted into the Azure Portal
**Run Command** blade). They do **not** reboot the machine.

## Windows — `removessm.ps1`

Stops and removes the `AmazonSSMAgent` service, uninstalls the MSI from Programs and
Features, deletes the leftover service if present, cleans up residual install directories,
and verifies removal.

```powershell
# Run in an elevated PowerShell session on the VM
.\removessm.ps1
```

## Linux — `Remove-AzLinuxSSM.sh`

Stops and disables `amazon-ssm-agent`, removes it via snap / dpkg / rpm as appropriate,
cleans up unit files and residual paths, and verifies removal.

Safety: does not reboot, does not restart other services, does not run apt/yum
update/upgrade, and cancels any pending reboot triggers.

```bash
# Run as root on the VM (or paste into Azure Run Command)
sudo bash Remove-AzLinuxSSM.sh
```

## Related

- [`check-azlinux-ssm`](../check-azlinux-ssm) / [`check-azwindows-ssm`](../check-azwindows-ssm) — check agent status first
- [`ssm-fixer`](../ssm-fixer) — diagnose and repair the agent instead of removing it
