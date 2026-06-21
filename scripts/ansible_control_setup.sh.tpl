#!/bin/bash
###############################################################################
# Bootstrap: Ansible Control Node
# OS: Red Hat Enterprise Linux 9
#
# Fixes applied:
#   #1  – private key fetched from SSM Parameter Store at runtime (not in user_data)
#   #4  – heredoc uses unquoted delimiter so Terraform interpolation works, but
#          the key is written via aws ssm get-parameter rather than a shell variable
#   #5  – enable firewalld before using firewall-cmd
#   #6  – python version derived from template variable
#   #13 – Node.js installed via NodeSource RPM (not deprecated dnf module stream)
#   #14 – /usr/local/bin added to PATH early
###############################################################################
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

# Template variables (resolved by Terraform)
PYTHON_VERSION="${python_version}"
PARAM_NAME="${param_name}"
SERVER1_IP="${server1_ip}"
SERVER2_IP="${server2_ip}"
SERVER3_IP="${server3_ip}"
ANSIBLE_USER="${ansible_user}"
HOME_DIR="/home/$${ANSIBLE_USER}"

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

echo "=== [1/10] System update ==="
dnf update -y

echo "=== [2/10] Install base packages ==="
dnf install -y \
  wget curl tar gzip unzip \
  gcc gcc-c++ make \
  openssl-devel bzip2-devel libffi-devel zlib-devel \
  xz-devel sqlite-devel readline-devel \
  net-tools bind-utils \
  firewalld \
  cronie \
  git vim \
  awscli2 \
  sshpass

echo "=== [3/10] Install Python $${PYTHON_VERSION} from source ==="
# FIX #6 – use the variable for both tarball and symlink names
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

echo "=== [4/10] Install Ansible ==="
# Prefer RHEL AppStream ansible-core (2.14) — the proven binary for these
# playbooks; it lands at /usr/bin/ansible-playbook. Non-fatal if unavailable:
# run_platform_install.sh falls back to the pip build below.
dnf install -y ansible-core || echo "ansible-core via dnf unavailable; using pip ansible"

# pip ansible (newer) + boto3/botocore for AWS modules and the S3 installer pull.
/usr/local/bin/pip3 install --upgrade pip
/usr/local/bin/pip3 install ansible ansible-lint paramiko boto3 botocore

# FIX #14 – verify using explicit path; not dependent on $PATH being set
/usr/local/bin/ansible --version
command -v /usr/bin/ansible-playbook >/dev/null && /usr/bin/ansible-playbook --version || true

echo "=== [5/10] Fetch SSH private key from SSM Parameter Store (Fix #1 & #4) ==="
# The key is never in user_data or any shell variable – fetched securely at runtime.
mkdir -p "$${HOME_DIR}/.ssh"
chmod 700 "$${HOME_DIR}/.ssh"

aws ssm get-parameter \
  --name "$${PARAM_NAME}" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  > "$${HOME_DIR}/.ssh/platform-key.pem"

chmod 600 "$${HOME_DIR}/.ssh/platform-key.pem"
chown -R $${ANSIBLE_USER}:$${ANSIBLE_USER} "$${HOME_DIR}/.ssh"
echo "SSH key written to $${HOME_DIR}/.ssh/platform-key.pem"

echo "=== [6/10] Create Ansible inventory and config ==="
mkdir -p /etc/ansible /etc/ansible/playbooks

# Inventory uses PRIVATE IPs (control node → servers are all in the same VPC)
cat > /etc/ansible/hosts << INVENTORY
[mq_only]
server1 ansible_host=$${SERVER1_IP} ansible_user=$${ANSIBLE_USER} ansible_ssh_private_key_file=$${HOME_DIR}/.ssh/platform-key.pem

[mq_ace]
server2 ansible_host=$${SERVER2_IP} ansible_user=$${ANSIBLE_USER} ansible_ssh_private_key_file=$${HOME_DIR}/.ssh/platform-key.pem
server3 ansible_host=$${SERVER3_IP} ansible_user=$${ANSIBLE_USER} ansible_ssh_private_key_file=$${HOME_DIR}/.ssh/platform-key.pem

[all_mq_servers:children]
mq_only
mq_ace

[platform:children]
all_mq_servers
INVENTORY

cat > /etc/ansible/ansible.cfg << CFG
[defaults]
inventory           = /etc/ansible/hosts
remote_user         = $${ANSIBLE_USER}
private_key_file    = $${HOME_DIR}/.ssh/platform-key.pem
host_key_checking   = False
retry_files_enabled = False
# community.general's "yaml" callback was removed in v12; use the built-in
# default callback with YAML-formatted results instead.
stdout_callback     = ansible.builtin.default
result_format       = yaml
# Use RHEL's system Python (3.9) for Ansible modules — NOT the source-built 3.13.
# ansible-core 2.14's get_url/urls module passes cert_file/key_file to
# http.client.HTTPSConnection, which Python 3.12+ removed, breaking every HTTPS
# download on the targets. System 3.9 is the proven, compatible interpreter.
interpreter_python  = /usr/bin/python3

[ssh_connection]
ssh_args            = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
pipelining          = True
CFG

# Set the Python interpreter for all Ansible playbooks. Use the RHEL system
# Python 3.9 (/usr/bin/python3): ansible-core 2.14 modules (get_url) are
# incompatible with the source-built Python 3.13 (cert_file kwarg removed in
# 3.12+). The 3.13 build remains available for the chatbot/MCP if needed.
mkdir -p /etc/ansible/group_vars
cat > /etc/ansible/group_vars/all.yml << GVARS
---
ansible_python_interpreter: /usr/bin/python3
GVARS

echo "=== [7/10] Enable firewalld and open ports ==="
# FIX #5 – enable firewalld before calling firewall-cmd
systemctl enable --now firewalld
systemctl is-active firewalld

firewall-cmd --permanent --add-port=8090/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# Copy verify playbook
cp /tmp/verify_platform.yml /etc/ansible/playbooks/verify_platform.yml 2>/dev/null || true

echo "=== MQ/ACE validation dashboard server (port 8090) ==="
# Serves the HTML rendered by validate_platform.yml; starts now with a
# placeholder so http://<public-ip>:8090/ is live immediately.
DASHBOARD_DIR="$${HOME_DIR}/validate-www"
mkdir -p "$${DASHBOARD_DIR}"
cat > "$${DASHBOARD_DIR}/index.html" << 'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>MQ/ACE Validation Dashboard</title></head>
<body style="font-family:sans-serif;margin:2rem">
<h1>MQ/ACE Validation Dashboard</h1>
<p>No data yet. Generate it from the control node with:</p>
<pre>ansible-playbook /etc/ansible/playbooks/validate_platform.yml</pre>
</body></html>
HTML
chown -R $${ANSIBLE_USER}:$${ANSIBLE_USER} "$${DASHBOARD_DIR}"

cat > /etc/systemd/system/validate-dashboard.service << DASHSVC
[Unit]
Description=MQ/ACE Validation Dashboard (static HTTP on 8090)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$${ANSIBLE_USER}
WorkingDirectory=$${DASHBOARD_DIR}
ExecStart=/usr/local/bin/python3 -m http.server 8090 --bind 0.0.0.0 --directory $${DASHBOARD_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
DASHSVC

systemctl daemon-reload
systemctl enable --now validate-dashboard

PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")
echo "=== Bootstrap complete – Ansible Control Node ready ==="
echo "    Dashboard → http://$${PUBLIC_IP}:8090/"
echo "    Run: ansible all -m ping"
