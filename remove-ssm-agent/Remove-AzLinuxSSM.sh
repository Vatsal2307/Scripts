#!/bin/bash
###############################################################################
# Remove-AzLinuxSSM.sh
# Removes Amazon SSM Agent from a Linux Azure VM.
# Intended to be pasted directly into the Azure Portal "Run Command" blade.
#
# SAFETY:
#   - Does NOT reboot the VM
#   - Does NOT restart any other services
#   - Does NOT run apt/yum update or upgrade
#   - Only targets the amazon-ssm-agent package and its files
###############################################################################

echo "=== Amazon SSM Agent Uninstall Script (Linux) ==="
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hostname: $(hostname)"
echo ""

# --- Stop the service ---
echo "Checking for amazon-ssm-agent service..."

if systemctl list-units --type=service --all 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    STATUS=$(systemctl is-active amazon-ssm-agent 2>/dev/null || true)
    echo "Service found. Status: $STATUS"

    if [[ "$STATUS" == "active" ]]; then
        echo "Stopping amazon-ssm-agent service..."
        systemctl stop amazon-ssm-agent
        sleep 2
        echo "Service stopped."
    fi

    echo "Disabling amazon-ssm-agent service..."
    systemctl disable amazon-ssm-agent 2>/dev/null || true
else
    echo "amazon-ssm-agent service not found via systemctl."
fi

# --- Uninstall the package ---
echo ""
echo "Checking for installed SSM Agent package..."

UNINSTALLED=false

# Check for snap-based installation
if command -v snap &>/dev/null && snap list 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    echo "Found snap package: amazon-ssm-agent"
    echo "Removing via snap..."
    snap remove amazon-ssm-agent
    UNINSTALLED=true
fi

# Check for deb-based installation (Debian/Ubuntu)
# Using --no-triggers to prevent any post-removal hooks from restarting services or rebooting
if dpkg -l 2>/dev/null | grep -qi 'amazon-ssm-agent'; then
    PACKAGE_NAME=$(dpkg -l | grep -i 'amazon-ssm-agent' | awk '{print $2}')
    echo "Found deb package: $PACKAGE_NAME"
    echo "Removing via dpkg (no triggers)..."
    dpkg --purge --no-triggers "$PACKAGE_NAME" 2>/dev/null || dpkg --purge "$PACKAGE_NAME" 2>/dev/null || true
    UNINSTALLED=true
fi

# Check for rpm-based installation (RHEL/CentOS/Amazon Linux)
# Using rpm -e --noscripts to skip any scriptlets that could trigger a reboot
if rpm -qa 2>/dev/null | grep -qi 'amazon-ssm-agent'; then
    PACKAGE_NAME=$(rpm -qa | grep -i 'amazon-ssm-agent')
    echo "Found rpm package: $PACKAGE_NAME"
    echo "Removing via rpm (no scripts)..."
    rpm -e --noscripts "$PACKAGE_NAME" 2>/dev/null || yum remove -y "$PACKAGE_NAME" 2>/dev/null || true
    UNINSTALLED=true
fi

if [[ "$UNINSTALLED" == "false" ]]; then
    echo "No SSM Agent package found via package manager."
fi

# --- Remove the service if it still exists ---
echo ""
echo "Checking if amazon-ssm-agent service still exists..."

if systemctl list-units --type=service --all 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    echo "Service still present. Removing unit files..."
    rm -f /etc/systemd/system/amazon-ssm-agent.service
    rm -f /usr/lib/systemd/system/amazon-ssm-agent.service
    # Reload daemon config only (does NOT restart any services or reboot)
    systemctl daemon-reload
    echo "Service unit files removed."
else
    echo "Service already removed."
fi

# --- Explicitly block any pending reboot triggers ---
# Some package scripts may schedule a reboot; cancel it if queued
if command -v shutdown &>/dev/null; then
    shutdown -c 2>/dev/null || true
fi

# --- Clean up residual files and directories ---
echo ""
echo "Cleaning up residual files..."

CLEANUP_PATHS=(
    "/usr/bin/amazon-ssm-agent"
    "/usr/bin/ssm-agent-worker"
    "/usr/bin/ssm-cli"
    "/usr/bin/ssm-document-worker"
    "/usr/bin/ssm-session-worker"
    "/usr/bin/ssm-session-logger"
    "/var/lib/amazon/ssm"
    "/var/log/amazon/ssm"
    "/etc/amazon/ssm"
    "/opt/aws/amazon-ssm-agent"
    "/snap/amazon-ssm-agent"
)

for path in "${CLEANUP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        echo "Removing: $path"
        rm -rf "$path"
        if [[ ! -e "$path" ]]; then
            echo "  Removed successfully."
        else
            echo "  WARNING: Could not fully remove."
        fi
    fi
done

# --- Verification ---
echo ""
echo "=== Verification ==="

REMAINING_SERVICE=false
REMAINING_PACKAGE=false

if systemctl list-units --type=service --all 2>/dev/null | grep -q 'amazon-ssm-agent'; then
    REMAINING_SERVICE=true
fi

if (dpkg -l 2>/dev/null | grep -qi 'amazon-ssm-agent') || \
   (rpm -qa 2>/dev/null | grep -qi 'amazon-ssm-agent') || \
   (command -v snap &>/dev/null && snap list 2>/dev/null | grep -q 'amazon-ssm-agent'); then
    REMAINING_PACKAGE=true
fi

if [[ "$REMAINING_SERVICE" == "false" && "$REMAINING_PACKAGE" == "false" ]]; then
    echo "SUCCESS: Amazon SSM Agent has been fully removed."
else
    if [[ "$REMAINING_SERVICE" == "true" ]]; then echo "WARNING: Service still exists."; fi
    if [[ "$REMAINING_PACKAGE" == "true" ]]; then echo "WARNING: Package still installed."; fi
fi

echo ""
echo "Script completed at $(date '+%Y-%m-%d %H:%M:%S')"
