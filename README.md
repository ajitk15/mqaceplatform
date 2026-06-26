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
│  │         Ansible Control Node (EIP)     │                         │
│  │  Ansible · Status dashboard (:8090)    │                         │
│  │  MQ+ACE MCP stack (:8001-:8004)        │                         │
│  │  Caddy secure gateway (HTTPS + auth):  │                         │
│  │    :443  → status dashboard            │                         │
│  │    :8444 → Streamlit chat UI           │                         │
│  │    :8445 → MCP log dashboard           │                         │
│  └────────────────────────────────────────┘                         │
│                                                                     │
│  SSH key + secrets in AWS SSM Parameter Store (not in user_data)    │
└─────────────────────────────────────────────────────────────────────┘
```

Human access from anywhere is via the **Caddy secure gateway** on the control
node's **Elastic IP** (stable across rebuilds): one HTTPS endpoint per service,
each behind Basic Auth. The raw service ports (`:8090`, `:8003`, `:8004`) stay
restricted to the operator IP and are reached by Caddy over `localhost`. See
[Secure remote access](#secure-remote-access-caddy-gateway).

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.6.0 |
| AWS CLI | >= 2.x (configured with credentials) |

## Quick Start

```bash
# 1. Edit terraform.tfvars – set your IP (and optionally notify_email,
#    gateway_username, gateway_allowed_cidr_blocks, mcp_allowed_cidr_blocks)
#    Find your IP:  curl -s https://checkip.amazonaws.com
vim terraform.tfvars   # replace YOUR_IP_HERE

# 1b. (Nothing to do for the gateway password — it's a fixed Basic Auth
#      credential, admin / gway123, hashed at deploy time by the playbook.)

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

## Cost (free tier)

**Not free if run 24/7.** The EC2 free tier covers ~1 t3.micro continuously
(750 hrs/mo), but this deploys **4× t3.micro** + 4× 25 GB gp3 (100 GB) + public
IPv4s — so most of it is beyond the free allowance.

| Resource | Billed (after free allowance) | ~Monthly |
|----------|-------------------------------|----------|
| EC2 — 4× t3.micro (1 free) | 3 instances | ~$22 |
| EBS — 100 GB gp3 (30 GB free) | 70 GB | ~$6 |
| Public IPv4 — 4 addrs (1 free, $0.005/hr each since Feb 2024) | 3 | ~$11 |
| SSM Parameter Store · SES · data-out | within free tier | ~$0 |
| **Total (running 24/7)** | | **≈ $40–45 / mo** |

- On the **new AWS "free plan"** (credit-based) this is **$0 out of pocket** — it
  draws ~$40–45/mo from the promo credits (~$100–$200), lasting ~2–4 months.
- On the **traditional 12-month free tier** you'd be **billed ~$40/mo** (only 1 of
  4 instances fits the 750-hr allowance).
- **Biggest saver — automated:** an EventBridge **stop/start schedule** is enabled
  by default (`enable_instance_scheduler`) — stops all 4 instances at **21:00
  daily** and starts them **08:00 Mon–Fri** (`scheduler_timezone`, default
  `Asia/Kolkata`; cron via `instance_stop_cron` / `instance_start_cron`). While
  stopped, compute → $0 (only ~$8/mo EBS remains). Data, private IPs (Ansible
  inventory) and the control-node EIP persist, so the platform comes back
  end-to-end on start (services are systemd-enabled; allow ~2–5 min to converge).
- Or `terraform destroy` when fully done. Check actual spend in Billing →
  **Bills** / **Free tier** / **Credits**.

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
| Port | Purpose | Exposure |
|------|---------|----------|
| 22 | SSH | operator IP |
| 8090 | MQ/ACE status (validate) dashboard | operator IP (public via gateway :443) |
| 8000–8010 | MQ+ACE MCP stack (8001 MCP server SSE/HTTP+BasicAuth · 8002 chat backend · 8003 Streamlit UI · 8004 log dashboard) | operator IP (8001 also `mcp_allowed_cidr_blocks`) |
| 443 | **Caddy gateway** → status dashboard (HTTPS + Basic Auth) | `gateway_allowed_cidr_blocks` |
| 8444 | **Caddy gateway** → Streamlit chat UI (HTTPS + Basic Auth) | `gateway_allowed_cidr_blocks` |
| 8445 | **Caddy gateway** → MCP log dashboard `/dashboard` (HTTPS + Basic Auth) | `gateway_allowed_cidr_blocks` |

> The MCP server on `:8001` runs plain HTTP (TLS disabled — see `mcp_tls_enabled`
> in `setup_mqacemcp.yml`) protected by Basic Auth; its only clients are the
> local chat backend and, optionally, a remote backend allowed via
> `mcp_allowed_cidr_blocks`.

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
| `setup_gateway.yml` | Control node: Caddy secure gateway (`:443`/`:8444`/`:8445`, HTTPS + Basic Auth) fronting the dashboard, chat UI, and log dashboard |
| `setup_ace_components.yml` | Create integration servers + deploy demo BARs (best-effort) |

Two more scripts run outside `install_platform.yml`: `run_validate.sh`
(every 2 min via cron) renders the `:8090` status dashboard, and
`email_dashboard.sh` emails the dashboard as an HTML attachment via SES.

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

## Secure remote access (Caddy gateway)

The control node runs a **Caddy reverse-proxy gateway** that exposes the platform's
web UIs over **one HTTPS endpoint per service**, each behind **Basic Auth**. This
is the supported way to reach the platform from a restricted network: only the
gateway ports are public, and Caddy talks to the real services over `localhost`,
so the raw ports stay locked to the operator IP.

| Endpoint | Serves |
|----------|--------|
| `https://<eip>` (`:443`) | MQ/ACE status dashboard |
| `https://<eip>:8444` | Streamlit chat UI |
| `https://<eip>:8445/dashboard` | MCP log dashboard |

`<eip>` is the control node's **Elastic IP** (Terraform output `control_node_eip` /
`gateway_url` / `chat_ui_url` / `log_dashboard_url`) — stable across rebuilds and
restarts. TLS is a **self-signed cert** (no domain), so browsers show a one-time
"untrusted" warning; add a real domain later for trusted Let's Encrypt certs.

**Gateway login is a fixed Basic Auth credential — `admin` / `gway123`.** The
playbook generates the bcrypt hash at deploy time with `caddy hash-password`
(no plaintext or hash in git/state); change it by editing `gateway_password` in
`scripts/setup_gateway.yml`.

Login user is `var.gateway_username` (default `admin`); who may reach the gateway
ports is `var.gateway_allowed_cidr_blocks` (default `["0.0.0.0/0"]` — safe because
of TLS + Basic Auth; tighten to your CIDRs for stricter access).

## Email notifications (SES)

When the install finishes successfully, the control node **emails the dashboard**
to `var.notify_email` via Amazon SES (free; the address is verified once as an SES
identity — `aws_ses_email_identity.notify`). `email_dashboard.sh` attaches the
rendered status dashboard as an HTML file, so it's readable even with no network
path to the platform. Set `notify_email = ""` to disable.

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
