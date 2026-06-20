#!/bin/bash
###############################################################################
# Bootstrap: MQ-only server (Server 1 & Server 4)
# OS: Red Hat Enterprise Linux 9
#
# Fixes applied:
#   #5  – enable firewalld before using firewall-cmd
#   #6  – python version derived from template variable (not hardcoded)
###############################################################################
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

# Template variables (resolved by Terraform templatefile())
PYTHON_VERSION="${python_version}"
ANSIBLE_PUBKEY="${ansible_pubkey}"

# FIX #14 – ensure /usr/local/bin is on PATH throughout this script
export PATH=/usr/local/bin:$PATH

# Ensure swap exists before any heavy work. t3.micro has ~1 GB RAM and no swap;
# dnf and compiling Python from source get OOM-killed without it.
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 3G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=3072
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "=== [1/6] System update ==="
dnf update -y

echo "=== [2/6] Install base packages ==="
dnf install -y \
  wget curl tar gzip unzip \
  gcc gcc-c++ make \
  openssl-devel bzip2-devel libffi-devel zlib-devel \
  xz-devel sqlite-devel readline-devel \
  net-tools bind-utils \
  firewalld \
  git vim

echo "=== [3/6] Install Python $${PYTHON_VERSION} from source ==="
# FIX #6 – use the variable to build the full tarball name and symlink target
PYTHON_MINOR=$(echo "$${PYTHON_VERSION}" | cut -d. -f2)
PYTHON_FULL="$${PYTHON_VERSION}.0"

cd /tmp
wget -q "https://www.python.org/ftp/python/$${PYTHON_FULL}/Python-$${PYTHON_FULL}.tgz"
rm -rf "Python-$${PYTHON_FULL}"   # ensure a clean source tree on any re-run
tar xzf "Python-$${PYTHON_FULL}.tgz"
cd "Python-$${PYTHON_FULL}"
# Note: --enable-optimizations (PGO) runs the full test suite and is both very
# slow and fragile on a 1 GB t3.micro (a single flaky test fails the build).
# Omitted deliberately — a non-PGO build is plenty for this platform.
./configure --with-ensurepip=install
make -j$(nproc)
make altinstall

# Symlink using the variable-derived name so bumping python_version just works
ln -sf /usr/local/bin/python$${PYTHON_VERSION} /usr/local/bin/python3
ln -sf /usr/local/bin/pip$${PYTHON_VERSION}    /usr/local/bin/pip3
python3 --version

echo "=== [4/6] Configure Ansible SSH access ==="
ANSIBLE_USER="ec2-user"
HOME_DIR="/home/$${ANSIBLE_USER}"
mkdir -p "$${HOME_DIR}/.ssh"
chmod 700 "$${HOME_DIR}/.ssh"
# Append the Ansible control node's public key so it can log in
echo "$${ANSIBLE_PUBKEY}" >> "$${HOME_DIR}/.ssh/authorized_keys"
chmod 600 "$${HOME_DIR}/.ssh/authorized_keys"
chown -R $${ANSIBLE_USER}:$${ANSIBLE_USER} "$${HOME_DIR}/.ssh"

echo "=== [5/6] Enable firewalld and open IBM MQ ports ==="
# FIX #5 – start firewalld first; AWS RHEL 9 AMIs ship with it disabled
systemctl enable --now firewalld
systemctl is-active firewalld

firewall-cmd --permanent --add-port=1414/tcp  # MQ Listener (default QM)
firewall-cmd --permanent --add-port=1415/tcp  # MQ Listener (additional QMs)
firewall-cmd --permanent --add-port=9443/tcp  # MQ Web Console HTTPS
firewall-cmd --permanent --add-port=9080/tcp  # MQ Web Console HTTP
firewall-cmd --permanent --add-port=1883/tcp  # MQTT
firewall-cmd --permanent --add-port=8883/tcp  # MQTT over TLS
firewall-cmd --permanent --add-port=9157/tcp  # MQ Prometheus metrics
firewall-cmd --reload

echo "=== [6/6] IBM MQ installation placeholder ==="
# IBM MQ requires a licence from IBM Passport Advantage.
# After placing the RPM at /opt/mq-binaries/ run the Ansible playbook:
#   dnf install -y /opt/mq-binaries/ibm-mqadvanced-server-dev-*.x86_64.rpm
#   /opt/mqm/bin/crtmqm QM1
#   /opt/mqm/bin/strmqm QM1
mkdir -p /opt/mq-binaries

echo "=== Bootstrap complete ==="
