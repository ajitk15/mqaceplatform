#!/bin/bash
###############################################################################
# Bootstrap: MQ + ACE server (Server 2 & Server 3)
# OS: Red Hat Enterprise Linux 9
#
# Fixes applied:
#   #5  – enable firewalld before using firewall-cmd
#   #6  – python version derived from template variable (not hardcoded)
###############################################################################
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

PYTHON_VERSION="${python_version}"
ANSIBLE_PUBKEY="${ansible_pubkey}"

# FIX #14 – ensure /usr/local/bin is on PATH throughout
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

echo "=== [1/7] System update ==="
dnf update -y

echo "=== [2/7] Install base packages ==="
dnf install -y \
  wget curl tar gzip unzip \
  gcc gcc-c++ make \
  openssl-devel bzip2-devel libffi-devel zlib-devel \
  xz-devel sqlite-devel readline-devel \
  net-tools bind-utils \
  java-17-openjdk java-17-openjdk-devel \
  firewalld \
  git vim

echo "=== [3/7] Install Python $${PYTHON_VERSION} from source ==="
# FIX #6 – derive tarball name and symlink from the variable
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

ln -sf /usr/local/bin/python$${PYTHON_VERSION} /usr/local/bin/python3
ln -sf /usr/local/bin/pip$${PYTHON_VERSION}    /usr/local/bin/pip3
python3 --version

echo "=== [4/7] Configure JAVA_HOME for ACE ==="
# Resolve the exact JVM directory installed
JAVA_HOME_PATH=$(dirname $(dirname $(readlink -f $(which java))))
cat > /etc/profile.d/java.sh <<JAVA
export JAVA_HOME=$${JAVA_HOME_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
JAVA
source /etc/profile.d/java.sh
java -version

echo "=== [5/7] Configure Ansible SSH access ==="
ANSIBLE_USER="ec2-user"
HOME_DIR="/home/$${ANSIBLE_USER}"
mkdir -p "$${HOME_DIR}/.ssh"
chmod 700 "$${HOME_DIR}/.ssh"
echo "$${ANSIBLE_PUBKEY}" >> "$${HOME_DIR}/.ssh/authorized_keys"
chmod 600 "$${HOME_DIR}/.ssh/authorized_keys"
chown -R $${ANSIBLE_USER}:$${ANSIBLE_USER} "$${HOME_DIR}/.ssh"

echo "=== [6/7] Enable firewalld and open MQ + ACE ports ==="
# FIX #5 – start firewalld first
systemctl enable --now firewalld
systemctl is-active firewalld

# MQ ports
firewall-cmd --permanent --add-port=1414/tcp
firewall-cmd --permanent --add-port=1415/tcp
firewall-cmd --permanent --add-port=9443/tcp
firewall-cmd --permanent --add-port=9080/tcp
firewall-cmd --permanent --add-port=1883/tcp
firewall-cmd --permanent --add-port=8883/tcp
firewall-cmd --permanent --add-port=9157/tcp
# ACE ports
firewall-cmd --permanent --add-port=7600/tcp
firewall-cmd --permanent --add-port=7800/tcp
firewall-cmd --permanent --add-port=7843/tcp
firewall-cmd --permanent --add-port=4414/tcp
firewall-cmd --permanent --add-port=9483/tcp
firewall-cmd --reload

echo "=== [7/7] IBM MQ + ACE installation placeholder ==="
mkdir -p /opt/mq-binaries /opt/ace-binaries
# After placing installers in the above dirs, run the Ansible playbook.

echo "=== Bootstrap complete ==="
