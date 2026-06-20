#!/bin/bash
###############################################################################
# Bootstrap: Ansible Control Node + MCP + Chatbot
# OS: Red Hat Enterprise Linux 9
#
# Fixes applied:
#   #1  – private key fetched from Secrets Manager at runtime (not in user_data)
#   #4  – heredoc uses unquoted delimiter so Terraform interpolation works, but
#          the key is written via aws secretsmanager rather than a shell variable
#   #5  – enable firewalld before using firewall-cmd
#   #6  – python version derived from template variable
#   #13 – Node.js installed via NodeSource RPM (not deprecated dnf module stream)
#   #14 – /usr/local/bin added to PATH early
#   #15 – mcp_port and chatbot_port written into group_vars for Ansible playbooks
###############################################################################
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

# Template variables (resolved by Terraform)
PYTHON_VERSION="${python_version}"
SECRET_ARN="${secret_arn}"
SERVER1_IP="${server1_ip}"
SERVER2_IP="${server2_ip}"
SERVER3_IP="${server3_ip}"
MCP_PORT="${mcp_port}"
CHATBOT_PORT="${chatbot_port}"
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

echo "=== [4/10] Install Ansible via pip ==="
/usr/local/bin/pip3 install --upgrade pip
/usr/local/bin/pip3 install ansible ansible-lint paramiko boto3 botocore

# FIX #14 – verify using explicit path; not dependent on $PATH being set
/usr/local/bin/ansible --version

echo "=== [5/10] Fetch SSH private key from Secrets Manager (Fix #1 & #4) ==="
# The key is never in user_data or any shell variable – fetched securely at runtime.
mkdir -p "$${HOME_DIR}/.ssh"
chmod 700 "$${HOME_DIR}/.ssh"

aws secretsmanager get-secret-value \
  --secret-id "$${SECRET_ARN}" \
  --query SecretString \
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
stdout_callback     = yaml
interpreter_python  = /usr/local/bin/python3

[ssh_connection]
ssh_args            = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
pipelining          = True
CFG

# FIX #15 – write port vars into group_vars so playbooks can reference them
mkdir -p /etc/ansible/group_vars
cat > /etc/ansible/group_vars/all.yml << GVARS
---
mcp_port: $${MCP_PORT}
chatbot_port: $${CHATBOT_PORT}
ansible_python_interpreter: /usr/local/bin/python3
GVARS

echo "=== [7/10] Enable firewalld and open ports ==="
# FIX #5 – enable firewalld before calling firewall-cmd
systemctl enable --now firewalld
systemctl is-active firewalld

firewall-cmd --permanent --add-port=$${MCP_PORT}/tcp
firewall-cmd --permanent --add-port=$${CHATBOT_PORT}/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

echo "=== [8/10] Install Node.js 20 via NodeSource (Fix #13) ==="
# FIX #13 – dnf module streams for nodejs are unreliable on RHEL 9;
#            NodeSource RPM repo is the supported production method.
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y nodejs
node --version
npm --version

echo "=== [9/10] Install and configure MCP server ==="
mkdir -p /opt/mcp-server
cat > /opt/mcp-server/package.json << 'PKGJSON'
{
  "name": "mcp-server",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.0",
    "cors": "^2.8.5"
  }
}
PKGJSON

# Write server.js – use shell var for port (already resolved above)
cat > /opt/mcp-server/server.js << MCPJS
const express = require('express');
const cors    = require('cors');
const app     = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.MCP_PORT || $${MCP_PORT};

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'MCP', port: PORT }));
app.post('/mcp', (req, res) => {
  // Extend this to integrate with MQ/ACE services
  res.json({ received: req.body, timestamp: new Date().toISOString() });
});

app.listen(PORT, () => console.log('MCP server running on port ' + PORT));
MCPJS

cd /opt/mcp-server && npm install

echo "=== Install Chatbot server ==="
mkdir -p /opt/chatbot
cat > /opt/chatbot/package.json << 'PKGJSON'
{
  "name": "chatbot-server",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.0",
    "cors": "^2.8.5",
    "ws": "^8.0.0"
  }
}
PKGJSON

cat > /opt/chatbot/server.js << BOTJS
const express = require('express');
const cors    = require('cors');
const { WebSocketServer } = require('ws');
const app     = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.CHATBOT_PORT || $${CHATBOT_PORT};

app.get('/health', (_, res) => res.json({ status: 'ok', service: 'Chatbot', port: PORT }));
app.post('/message', (req, res) => {
  const { message } = req.body;
  res.json({ reply: 'Received: ' + message, timestamp: new Date().toISOString() });
});

const server = app.listen(PORT, () => console.log('Chatbot running on port ' + PORT));
const wss    = new WebSocketServer({ server });
wss.on('connection', ws => {
  ws.send(JSON.stringify({ event: 'connected', service: 'Chatbot' }));
  ws.on('message', data => ws.send(JSON.stringify({ echo: data.toString() })));
});
BOTJS

cd /opt/chatbot && npm install

echo "=== [10/10] Create and enable systemd services ==="
cat > /etc/systemd/system/mcp-server.service << 'SVC'
[Unit]
Description=MCP Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/mcp-server
ExecStart=/usr/bin/node server.js
Environment=MCP_PORT=MCP_PORT_PLACEHOLDER
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

# Substitute the port value into the systemd unit
sed -i "s/MCP_PORT_PLACEHOLDER/$${MCP_PORT}/" /etc/systemd/system/mcp-server.service

cat > /etc/systemd/system/chatbot.service << 'SVC'
[Unit]
Description=Chatbot Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/chatbot
ExecStart=/usr/bin/node server.js
Environment=CHATBOT_PORT=CHATBOT_PORT_PLACEHOLDER
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

sed -i "s/CHATBOT_PORT_PLACEHOLDER/$${CHATBOT_PORT}/" /etc/systemd/system/chatbot.service

systemctl daemon-reload
systemctl enable --now mcp-server
systemctl enable --now chatbot

# Copy verify playbook
cp /tmp/verify_platform.yml /etc/ansible/playbooks/verify_platform.yml 2>/dev/null || true

PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")
echo "=== Bootstrap complete – Ansible Control Node ready ==="
echo "    MCP     → http://$${PUBLIC_IP}:$${MCP_PORT}/health"
echo "    Chatbot → http://$${PUBLIC_IP}:$${CHATBOT_PORT}/health"
echo "    Run: ansible all -m ping"
