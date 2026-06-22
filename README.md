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
│  │  Ansible · Status dashboard (:8090)    │                         │
│  │  MQ+ACE MCP stack (:8001-:8004)        │                         │
│  └────────────────────────────────────────┘                         │
│                                                                     │
│  SSH key stored in AWS SSM Parameter Store (not in user_data)       │
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
| #1 | SSH private key is stored in AWS SSM Parameter Store (SecureString, encrypted with the default `aws/ssm` KMS key — no cost); fetched at runtime by the Ansible node via IAM role — never appears in user_data or the AWS console |
| #2 | IAM role + instance profile replaces embedding secrets in state |
| #3 | MQ server SGs now have an explicit `source_security_group_id` rule allowing SSH from the Ansible control node SG |
| #4 | PEM key is written via `aws ssm get-parameter --with-decryption` directly to disk — no heredoc quoting issue |
| #5 | `systemctl enable --now firewalld` runs before every `firewall-cmd` call |
| #6 | Python version symlinks are derived from `var.python_version` — bumping the var just works |
| #7 | Remote S3 backend template included (commented out) — uncomment and fill in before production use |
| #8 | `depends_on` added to Ansible control node to guarantee server IPs are known at plan time |
| #11 | `allowed_cidr_blocks` has no default — Terraform will error if not set |
| #14 | `export PATH=/usr/local/bin:$PATH` added early in every bootstrap script |
| #16 | `.gitignore` added — prevents `.pem`, `.tfstate`, and `hosts.ini` from being committed |
| #17 | `outputs.tf` — path output no longer marked `sensitive`; private key content never exposed as output |

---

## Ports enabled

### IBM MQ (Servers 1, 2, 3, 4)
| Port | Purpose |
|------|---------|
| 1414–1421 | MQ Listeners — cluster QMs (1414 MQREPO1, 1415 QM1, 1416 MQREPO2) + ACE node QMs (1420 MQNODE1, 1421 MQNODE2); open in-VPC only |
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
| 8090 | MQ/ACE status (validate) dashboard |
| 8000–8010 | MQ+ACE MCP stack (8001 MCP server SSE/TLS · 8002 chat backend · 8003 Streamlit UI · 8004 log dashboard) |

---

## IBM MQ & ACE installation

**The install runs automatically as part of `terraform apply`.** After the control
node comes up, Terraform's `deploy_playbooks` resource copies `scripts/` to
`/etc/ansible/playbooks/` and launches `run_platform_install.sh` as a detached
`platform-install` systemd unit. That driver waits for cloud-init to finish on
every node, then runs `install_platform.yml` end-to-end. `apply` returns
immediately — the long install continues in the background and the `:8090`
dashboard tracks progress (red → green) as nodes come online.

```bash
# Watch the install from the control node:
ssh -i rhel-mq-platform-key.pem ec2-user@$(terraform output -raw ansible_control_public_ip)
sudo journalctl -u platform-install -f      # or: tail -f /var/log/platform-install.log
```

`install_platform.yml` orchestrates, in order:

| Playbook | Does |
|----------|------|
| `install_mq.yml` | Install IBM MQ on all MQ servers (mirrors the manual RPM install) |
| `setup_mq_components.yml` | Create per-server queue managers + `ACECLUSTER` from `scripts/mqsetup/*.mqsc` |
| `configure_mq.yml` | Create the dev QM (`QM1`) + dev MQSC objects + start the MQ Console (mqweb) |
| `install_ace.yml` | Install IBM ACE on the MQ+ACE servers (Server 2 & 3) |
| `schedule_dumps.yml` | Control node: every-30-min queue-manager / node config dump cron |
| `setup_mqacemcp.yml` | Control node: clone the MQ+ACE MCP stack, build per-component Python 3.13 venvs, run under systemd |
| `setup_ace_components.yml` | Create integration servers + deploy demo BARs (best-effort) |

The EC2 bootstrap (cloud-init) only prepares prerequisites and opens ports — all
MQ/ACE install work happens in the playbooks above. To re-run or run a single
stage manually:

```bash
cd /etc/ansible/playbooks
ansible-playbook install_platform.yml     # full install
ansible-playbook verify_mq_ace.yml        # verify end-to-end
```

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

### Install variables

`scripts/mq_ace_install_vars.yml` holds the install settings — queue-manager
name, ports, dev password, and ACE bits. Terraform copies it to
`/etc/ansible/playbooks/` with the rest of `scripts/`; edit it there (and re-run
`install_platform.yml`) to change defaults. Instance sizing is set in
`terraform.tfvars` / `variables.tf` (`instance_type_mq` = `t3.large`,
`instance_type_mq_ace` = `t3.xlarge`, `instance_type_ansible` = `t3.medium`).

`install_mq.yml` downloads the free developer edition straight from IBM's public
mirror (`public.dhe.ibm.com`, no IBMid) and installs the same RPM set as a manual
install, then `setmqinst -i`. It also creates a swapfile to keep small instance
types comfortably above MQ minimums — fine for dev/eval only.

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
