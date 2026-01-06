## Embedded provisioning script for container setup
import std/strutils

const ProvisionScript* = """
set -e

# Wait for network (up to 60 seconds)
network_ready=false
for i in {1..60}; do
    if ping -c1 -W1 archive.ubuntu.com &>/dev/null; then
        network_ready=true
        break
    fi
    sleep 1
done

if [[ "$network_ready" != "true" ]]; then
    echo "ERROR: Network not available after 60 seconds" >&2
    exit 1
fi

# Update and install packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    openssh-server \
    docker.io \
    docker-compose \
    curl \
    git \
    ca-certificates \
    sudo

# Create dev user with matching UID (UID_PLACEHOLDER replaced at runtime)
existing_user=$(getent passwd UID_PLACEHOLDER | cut -d: -f1)
if [[ -n "$existing_user" ]]; then
    userdel -r "$existing_user" 2>/dev/null || true
fi
useradd -m -s /bin/bash -u UID_PLACEHOLDER dev
usermod -aG docker dev

# Configure passwordless sudo
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev
chmod 440 /etc/sudoers.d/dev

# Configure SSH
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Enable and start services
systemctl enable ssh docker
systemctl start ssh docker
"""

proc getProvisionScript*(hostUid: int): string =
  ## Return provision script with UID placeholder replaced
  result = ProvisionScript.replace("UID_PLACEHOLDER", $hostUid)
