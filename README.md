# Red Hat Linux – MQ/ACE Platform (Terraform IaC) — v2

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                   Red Hat Enterprise Linux 9 / AWS                  │
│                        VPC  10.0.0.0/16                             │
│                                                                     │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐   │
│  │ Server 1 │  │   Server 2   │  │   Server 3   │  │ Server 4 │   │
│  │   MQ     │  │  MQ + ACE    │  │  MQ + ACE    │  │   MQ     │   │
│  └──────────┘  └──────────────┘  └──────────────┘  └──────────┘   │
│       ▲               ▲                 ▲                ▲          │
│       └───────────────┴─────────────────┴────────────────┘          │
│                        SSH via SG rule                               │
│  ┌────────────────────────────────────────┐                         │
│  │         Ansible Control Node           │                         │
│  │  Ansible · MCP (:8080) · Chatbot (:3000)│                        │
│  └────────────────────────────────────────┘                         │
│                                                                     │
│  SSH key stored in AWS Secrets Manager (not in user_data)           │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.6.0 |
| AWS CLI | >= 2.x (configured with credentials) |

## Quick Start

```bash
# 1. Edit terraform.tfvars – set your IP
#    Find your IP:  curl -s https://checkip.amazonaws.com
vim terraform.tfvars   # replace YOUR_IP_HERE

# 2. Initialise Terraform
terraform init

# 3. Preview
terraform plan

# 4. Apply
terraform apply -auto-approve

# 5. View outputs
terraform output
```

## Destroy

```bash
terraform destroy -auto-approve
```

Everything is tagged `ManagedBy = Terraform`. Nothing is left behind.

---

## Security improvements in v2

| Fix | What changed |
|-----|-------------|
| #1 | SSH private key is stored in AWS Secrets Manager; fetched at runtime by the Ansible node via IAM role — never appears in user_data or the AWS console |
| #2 | IAM role + instance profile replaces embedding secrets in state |
| #3 | MQ server SGs now have an explicit `source_security_group_id` rule allowing SSH from the Ansible control node SG |
| #4 | PEM key is written via `aws secretsmanager get-secret-value` directly to disk — no heredoc quoting issue |
| #5 | `systemctl enable --now firewalld` runs before every `firewall-cmd` call |
| #6 | Python version symlinks are derived from `var.python_version` — bumping the var just works |
| #7 | Remote S3 backend template included (commented out) — uncomment and fill in before production use |
| #8 | `depends_on` added to Ansible control node to guarantee server IPs are known at plan time |
| #11 | `allowed_cidr_blocks` has no default — Terraform will error if not set |
| #13 | Node.js installed via NodeSource RPM (official method for RHEL 9) |
| #14 | `export PATH=/usr/local/bin:$PATH` added early in every bootstrap script |
| #15 | `mcp_port`/`chatbot_port` written to `/etc/ansible/group_vars/all.yml` — playbooks use them directly |
| #16 | `.gitignore` added — prevents `.pem`, `.tfstate`, and `hosts.ini` from being committed |
| #17 | `outputs.tf` — path output no longer marked `sensitive`; private key content never exposed as output |

---

## Ports enabled

### IBM MQ (Servers 1, 2, 3, 4)
| Port | Purpose |
|------|---------|
| 1414–1415 | MQ Listener |
| 9443 | MQ Web Console HTTPS |
| 9080 | MQ Web Console HTTP |
| 1883 | MQTT |
| 8883 | MQTT over TLS |
| 9157 | Prometheus metrics |

### IBM ACE (Servers 2 & 3 only)
| Port | Purpose |
|------|---------|
| 7600 | Integration Node listener |
| 7800 | Integration Server HTTP |
| 7843 | Integration Server HTTPS |
| 4414 | ACE Web Admin |
| 9483 | ACE Web UI HTTPS |

### Ansible Control Node
| Port | Purpose |
|------|---------|
| 22 | SSH |
| 8080 | MCP server |
| 3000 | Chatbot |

---

## IBM MQ & ACE installation

The EC2 bootstrap only prepares prerequisites and opens ports — it does **not**
install MQ/ACE. Use the Ansible playbooks under `scripts/` to install them.

### Binaries — use the free Developer editions

| Product | Edition | Cost |
|---------|---------|------|
| IBM MQ | **MQ Advanced for Developers** | Free (dev use) |
| IBM ACE | **ACE Developer Edition** | Free (dev use) |

Both require an IBMid to download (no anonymous download), so stage them once.
**Recommended: a private S3 bucket** in the same account/region.

```bash
# After downloading the dev archives with your IBMid:
aws s3 mb s3://my-mq-ace-binaries --region us-east-1
aws s3 cp mqadv_dev942_linux_x86-64.tar.gz            s3://my-mq-ace-binaries/mq/
aws s3 cp 12.0.12.0-ACE-LINUX64-DEVELOPER.tar.gz      s3://my-mq-ace-binaries/ace/
```

Grant the control node read access by setting the (optional) Terraform variable
and re-applying — this adds an `s3:GetObject` policy to its IAM role only:

```hcl
# terraform.tfvars
mq_ace_s3_bucket = "my-mq-ace-binaries"
```
```bash
terraform apply
```

### Run the install playbooks

```bash
# On the Ansible control node (playbooks live in scripts/, copy them across or git clone):
#   scripts/mq_ace_install_vars.yml   <- edit: queue manager name, ports, dev password, ACE bits
#   scripts/install_mq.yml            <- install IBM MQ  -> all_mq_servers (mirrors the manual RPM install)
#   scripts/configure_mq.yml          <- queue manager + dev objects + MQ Console (mqweb)
#   scripts/install_ace.yml           <- install IBM ACE -> mq_ace servers
#   scripts/install_platform.yml      <- runs all three in order

ansible-playbook install_platform.yml

# Then verify the install end-to-end:
ansible-playbook verify_mq_ace.yml
```

`install_mq.yml` downloads the free developer edition straight from IBM's public
mirror (`public.dhe.ibm.com`, no IBMid) and installs the same RPM set as a manual
install, then `setmqinst -i`. It also creates a swapfile, since `t3.micro` (1 GB
RAM) is below MQ minimums — fine for dev/eval only.

`configure_mq.yml` then creates the queue manager (`crtmqm`/`strmqm` + a
`mq-<qm>.service` unit), applies the developer MQSC objects (listener, `DEV.QUEUE.1`,
`DEV.APP.SVRCONN`), and enables + starts **mqweb** (MQ Console + REST API) with
remote access and a `mqweb.service` unit so it survives reboots:

```
MQ Console → https://<server-public-ip>:9443/ibmmq/console/
```

Login is the `mq_admin_user` / `mq_dev_password` from `mq_ace_install_vars.yml`
(written into `mqwebuser.xml`). Reaching it from your workstation requires your
IP in `allowed_cidr_blocks` (port 9443 is already open in the MQ SG).

`verify_mq_ace.yml` confirms the queue manager is RUNNING and does a real
put/get round-trip on `DEV.QUEUE.1`, then checks each ACE integration server's
service state and admin REST endpoint.

> Note on tooling: run these with the OS-supplied **ansible-core** (e.g. `/usr/bin/ansible-playbook`),
> and ensure `/etc/ansible/ansible.cfg` uses `stdout_callback = default` (the
> bundled `yaml` callback was removed in newer community.general).

---

## Verifying the platform

```bash
# SSH to the Ansible control node
ssh -i rhel-mq-platform-key.pem ec2-user@$(terraform output -raw ansible_control_public_ip)

# Test Ansible connectivity to all servers
ansible all -m ping

# Run the verification playbook
ansible-playbook /etc/ansible/playbooks/verify_platform.yml
```

---

## Remote state (production)

Uncomment the `backend "s3"` block in `main.tf` and create:
- An S3 bucket with versioning + SSE-KMS encryption
- A DynamoDB table (`LockID` String hash key) for state locking

```bash
terraform init -reconfigure
```
