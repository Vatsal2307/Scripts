#!/bin/bash

set -euo pipefail

# Check if a Resource Group argument was provided
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <ResourceGroupName>"
    echo "Example: $0 my-production-rg"
    exit 1
fi

TARGET_RG="$1"

echo "======================================================"
echo " Azure Linux VM SSM Agent Status Checker"
echo " Target Resource Group: $TARGET_RG"
echo "======================================================"

# 1. Verify Azure CLI login context
if ! az account show > /dev/null 2>&1; then
    echo "Error: You are not logged into Azure CLI. Please run 'az login' first."
    exit 1
fi

# 2. Show active subscription and prompt confirmation
echo ""
az account show --query "{Subscription:name, ID:id}" -o table
echo ""
read -r -p "Is this the correct subscription? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted. Run 'az account set --subscription <name_or_id>' to switch subscriptions."
    exit 1
fi

echo ""
echo "Fetching a list of Linux VMs in resource group '$TARGET_RG'..."

# 3. Trap ensures set -e is always restored on unexpected exit
trap 'set -e' EXIT

# 4. Pipe az vm list directly into while loop — avoids intermediate variable and word-splitting risk
#    The loop simply won't execute if no Linux VMs are found
az vm list \
    --resource-group "$TARGET_RG" \
    --query "[?storageProfile.osDisk.osType=='Linux'].{Name:name, ResourceGroup:resourceGroup}" \
    -o tsv | while IFS=$'\t' read -r vm_name resource_group; do

    echo "------------------------------------------------------"
    echo "Checking VM: $vm_name | Resource Group: $resource_group"

    # 5. Direct if-command pattern — no set +e / set -e toggle needed
    #    Stderr captured separately to keep SSM status output clean
    if run_output=$(az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "systemctl status amazon-ssm-agent.service" \
        --query "value[0].message" \
        --output tsv 2>/tmp/az_ssm_err); then
        printf "Status Output:\n%s\n" "$run_output"
    else
        az_err=$(<  /tmp/az_ssm_err)
        printf "Error executing command on %s.\nNote: Ensure the VM is powered on and the Azure Linux Agent is healthy.\nCLI Error: %s\n" "$vm_name" "$az_err"
    fi

done

echo "======================================================"
echo "Operation successfully completed."
