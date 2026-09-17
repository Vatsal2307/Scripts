# check-azlinux-ssm

Checks whether the **Amazon SSM Agent** is installed on **Linux** Azure VMs. Read-only —
it inspects status via Azure VM Run Command and never modifies the VM.

Two implementations are provided:

- `Check-AzLinuxSSM.ps1` — PowerShell (Az module), supports many VMs across multiple subscriptions
- `Check-AzLinuxSSM.sh` — Bash (Azure CLI), checks all Linux VMs in one resource group

## PowerShell version

### Prerequisites
- Azure PowerShell module (`Az`)
- Authenticated session: `Connect-AzAccount`
- Reader + VM Run Command permissions on the target subscriptions

### Usage

```powershell
# From a CSV (columns: SubscriptionId, ResourceGroupName, VMName)
.\Check-AzLinuxSSM.ps1 -CsvPath ".\vm-list.csv"

# From an inline list
$vms = @(
    @{ SubscriptionId = "aaaa-bbbb-cccc"; ResourceGroupName = "rg-prod"; VMName = "linux-vm-01" },
    @{ SubscriptionId = "dddd-eeee-ffff"; ResourceGroupName = "rg-dev";  VMName = "linux-vm-02" }
)
.\Check-AzLinuxSSM.ps1 -VmList $vms
```

Results are printed as a summary table and exported to a timestamped CSV next to the script.

## Bash version

### Prerequisites
- Azure CLI (`az`)
- Logged in: `az login`

### Usage

```bash
./Check-AzLinuxSSM.sh <ResourceGroupName>
# e.g.
./Check-AzLinuxSSM.sh my-production-rg
```

It shows the active subscription and asks for confirmation, then checks every Linux VM in
the resource group via `az vm run-command`.

## Related

See [`remove-ssm-agent`](../remove-ssm-agent) to uninstall the agent.
