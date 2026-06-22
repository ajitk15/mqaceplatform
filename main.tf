###############################################################################
# Red Hat Linux Platform – MQ/ACE + Ansible Control Node
# Architecture:
#   Server 1  → MQ only
#   Server 2  → MQ + ACE
#   Server 3  → MQ + ACE
#   Server 4  → MQ only
#   Ansible   → Ansible Control Node
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # FIX #7 – remote state with encryption + locking
  # Uncomment and fill in before first apply:
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "rhel-mq-platform/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   kms_key_id     = "alias/terraform-state"
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# Key Pair – generated locally; private key stored in SSM Parameter Store (Fix #1, #2)
###############################################################################
resource "tls_private_key" "platform" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "platform" {
  key_name   = "${var.platform_name}-key"
  public_key = tls_private_key.platform.public_key_openssh
}

# Write PEM locally for operator SSH use (not passed into user_data)
resource "local_file" "private_key" {
  content         = tls_private_key.platform.private_key_pem
  filename        = "${path.module}/${var.platform_name}-key.pem"
  file_permission = "0600"
}

# FIX #1 & #2 – store private key in SSM Parameter Store (SecureString, free tier);
# the control node's bootstrap fetches it at runtime via its IAM role.
resource "aws_ssm_parameter" "platform_key" {
  name        = "/${var.platform_name}/ssh-private-key"
  description = "Platform SSH private key for Ansible control node"
  type        = "SecureString" # encrypted with the default aws/ssm KMS key (no cost)
  value       = tls_private_key.platform.private_key_pem

  tags = local.common_tags
}

###############################################################################
# IAM Role – lets the Ansible control node read the SSH key parameter (Fix #1)
###############################################################################
resource "aws_iam_role" "ansible_control" {
  name = "${var.platform_name}-ansible-control-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ansible_secrets" {
  name = "read-platform-ssh-key"
  role = aws_iam_role.ansible_control.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.platform_key.arn,
          # Other platform secrets (e.g. /<platform>/openai-api-key) the control
          # node injects into app config at deploy time. Secrets live in SSM,
          # never in git or Terraform state.
          "arn:aws:ssm:${var.aws_region}:*:parameter/${var.platform_name}/*",
        ]
      },
      {
        # Decrypt the SecureString — scoped to calls made via SSM only.
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ansible_control" {
  name = "${var.platform_name}-ansible-control-profile"
  role = aws_iam_role.ansible_control.name
}

# Optional – let the Ansible control node read MQ/ACE binaries from a private
# S3 bucket. Created only when var.mq_ace_s3_bucket is non-empty.
resource "aws_iam_role_policy" "ansible_s3_binaries" {
  count = var.mq_ace_s3_bucket != "" ? 1 : 0
  name  = "read-mq-ace-binaries"
  role  = aws_iam_role.ansible_control.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.mq_ace_s3_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.mq_ace_s3_bucket}"
      }
    ]
  })
}

###############################################################################
# "Platform ready" email notification (SES) — free, no SMTP/password.
# Verifies the notify address as an SES identity; the control node sends an
# email (from/to that address) with the :8090 dashboard URL when the install
# finishes successfully. Created only when var.notify_email is set.
#
# First apply in a fresh account: AWS emails a one-time verification link to the
# address that must be clicked. In the SES sandbox both sender and recipient must
# be verified — using the same address for both satisfies that with one click.
###############################################################################
resource "aws_ses_email_identity" "notify" {
  count = var.notify_email != "" ? 1 : 0
  email = var.notify_email
}

# Let the Ansible control node send the "ready" email from the verified identity.
resource "aws_iam_role_policy" "ansible_ses_send" {
  count = var.notify_email != "" ? 1 : 0
  name  = "send-ready-notification"
  role  = aws_iam_role.ansible_control.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = aws_ses_email_identity.notify[0].arn
      Condition = {
        StringEquals = { "ses:FromAddress" = var.notify_email }
      }
    }]
  })
}

###############################################################################
# VPC & Networking
###############################################################################
resource "aws_vpc" "platform" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.platform_name}-vpc" })
}

resource "aws_internet_gateway" "platform" {
  vpc_id = aws_vpc.platform.id
  tags   = merge(local.common_tags, { Name = "${var.platform_name}-igw" })
}

resource "aws_subnet" "platform" {
  vpc_id                  = aws_vpc.platform.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.platform_name}-subnet" })
}

resource "aws_route_table" "platform" {
  vpc_id = aws_vpc.platform.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.platform.id
  }

  tags = merge(local.common_tags, { Name = "${var.platform_name}-rt" })
}

resource "aws_route_table_association" "platform" {
  subnet_id      = aws_subnet.platform.id
  route_table_id = aws_route_table.platform.id
}

###############################################################################
# Security Groups
###############################################################################
module "sg_mq" {
  source        = "./modules/security_groups"
  name          = "${var.platform_name}-sg-mq"
  description   = "IBM MQ default ports"
  vpc_id        = aws_vpc.platform.id
  common_tags   = local.common_tags
  ingress_rules = local.mq_ingress_rules
}

# FIX #3 – allow Ansible control node SG to SSH into MQ servers
resource "aws_security_group_rule" "mq_allow_ansible_ssh" {
  type                     = "ingress"
  security_group_id        = module.sg_mq.sg_id
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = module.sg_ansible.sg_id
  description              = "Allow Ansible control node SSH"
}

# Allow the control node (Ansible + MCP server) to reach the MQ REST/Console API
# (9443). The MCP tools query queue managers over https://<qm-host>:9443/ibmmq/rest;
# the base mq_ingress_rules only open 9443 to the operator CIDR, not in-VPC.
resource "aws_security_group_rule" "mq_allow_ansible_rest" {
  type                     = "ingress"
  security_group_id        = module.sg_mq.sg_id
  from_port                = 9443
  to_port                  = 9443
  protocol                 = "tcp"
  source_security_group_id = module.sg_ansible.sg_id
  description              = "Allow Ansible/MCP control node to reach MQ REST/Console"
}

module "sg_ace" {
  source        = "./modules/security_groups"
  name          = "${var.platform_name}-sg-ace"
  description   = "IBM ACE default ports"
  vpc_id        = aws_vpc.platform.id
  common_tags   = local.common_tags
  ingress_rules = local.ace_ingress_rules
}

# Allow the control node (Ansible + MCP server) to reach the ACE admin REST API
# (4414, the node port in node_config.csv). ace_node_overview / ace_server_explore
# call it; ace_ingress_rules only open 4414 to the operator CIDR, not in-VPC.
resource "aws_security_group_rule" "ace_allow_ansible_admin" {
  type                     = "ingress"
  security_group_id        = module.sg_ace.sg_id
  from_port                = 4414
  to_port                  = 4414
  protocol                 = "tcp"
  source_security_group_id = module.sg_ansible.sg_id
  description              = "Allow Ansible/MCP control node to reach ACE admin REST"
}

module "sg_ansible" {
  source        = "./modules/security_groups"
  name          = "${var.platform_name}-sg-ansible"
  description   = "Ansible control node ports"
  vpc_id        = aws_vpc.platform.id
  common_tags   = local.common_tags
  ingress_rules = local.ansible_ingress_rules
}

###############################################################################
# MQ-only Servers  (Server 1 & 4)
###############################################################################
module "server1" {
  source             = "./modules/ec2_instance"
  name               = "${var.platform_name}-server1-mq"
  ami_id             = data.aws_ami.rhel.id
  instance_type      = var.instance_type_mq
  subnet_id          = aws_subnet.platform.id
  key_name           = aws_key_pair.platform.key_name
  security_group_ids = [module.sg_mq.sg_id]
  common_tags        = merge(local.common_tags, { Role = "MQ" })
  user_data = templatefile("${path.module}/scripts/mq_setup.sh.tpl", {
    python_version = var.python_version
    ansible_pubkey = tls_private_key.platform.public_key_openssh
  })
}

###############################################################################
# MQ + ACE Servers  (Server 2 & 3)
###############################################################################
module "server2" {
  source             = "./modules/ec2_instance"
  name               = "${var.platform_name}-server2-mq-ace"
  ami_id             = data.aws_ami.rhel.id
  instance_type      = var.instance_type_mq_ace
  subnet_id          = aws_subnet.platform.id
  key_name           = aws_key_pair.platform.key_name
  security_group_ids = [module.sg_mq.sg_id, module.sg_ace.sg_id]
  common_tags        = merge(local.common_tags, { Role = "MQ+ACE" })
  user_data = templatefile("${path.module}/scripts/mq_ace_setup.sh.tpl", {
    python_version = var.python_version
    ansible_pubkey = tls_private_key.platform.public_key_openssh
  })
}

module "server3" {
  source             = "./modules/ec2_instance"
  name               = "${var.platform_name}-server3-mq-ace"
  ami_id             = data.aws_ami.rhel.id
  instance_type      = var.instance_type_mq_ace
  subnet_id          = aws_subnet.platform.id
  key_name           = aws_key_pair.platform.key_name
  security_group_ids = [module.sg_mq.sg_id, module.sg_ace.sg_id]
  common_tags        = merge(local.common_tags, { Role = "MQ+ACE" })
  user_data = templatefile("${path.module}/scripts/mq_ace_setup.sh.tpl", {
    python_version = var.python_version
    ansible_pubkey = tls_private_key.platform.public_key_openssh
  })
}

###############################################################################
# Ansible Control Node
# FIX #8 – explicit depends_on ensures private IPs are resolved before templating
###############################################################################
module "ansible_control" {
  source               = "./modules/ec2_instance"
  name                 = "${var.platform_name}-ansible-control"
  ami_id               = data.aws_ami.rhel.id
  instance_type        = var.instance_type_ansible
  subnet_id            = aws_subnet.platform.id
  key_name             = aws_key_pair.platform.key_name
  security_group_ids   = [module.sg_ansible.sg_id]
  iam_instance_profile = aws_iam_instance_profile.ansible_control.name
  common_tags          = merge(local.common_tags, { Role = "AnsibleControl" })
  user_data = templatefile("${path.module}/scripts/ansible_control_setup.sh.tpl", {
    python_version = var.python_version
    param_name     = aws_ssm_parameter.platform_key.name
    server1_ip     = module.server1.private_ip
    server2_ip     = module.server2.private_ip
    server3_ip     = module.server3.private_ip
    ansible_user   = var.rhel_user
  })

  depends_on = [
    module.server1,
    module.server2,
    module.server3,
    aws_ssm_parameter.platform_key,
  ]
}

###############################################################################
# Dynamic Ansible Inventory file – written locally for workstation use
# Uses PUBLIC IPs (operator → servers).
# The control node inventory (private IPs) is written by its bootstrap script.
###############################################################################
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory/hosts.ini"
  content = templatefile("${path.module}/inventory/hosts.ini.tpl", {
    server1_ip   = module.server1.public_ip
    server2_ip   = module.server2.public_ip
    server3_ip   = module.server3.public_ip
    ansible_ip   = module.ansible_control.public_ip
    ssh_key_file = "${path.module}/${var.platform_name}-key.pem"
    ansible_user = var.rhel_user
  })
}

###############################################################################
# Deploy the Ansible playbooks onto the control node (self-contained infra).
# SSHes into the control node and copies scripts/ to /etc/ansible/playbooks/,
# so the playbooks are ready to run with no manual upload. Re-runs whenever the
# control node is replaced or any file under scripts/ changes.
###############################################################################
resource "terraform_data" "deploy_playbooks" {
  triggers_replace = [
    module.ansible_control.instance_id,
    sha1(join("", [for f in fileset("${path.module}/scripts", "**") : filesha1("${path.module}/scripts/${f}")])),
  ]

  connection {
    type        = "ssh"
    host        = module.ansible_control.public_ip
    user        = var.rhel_user
    private_key = tls_private_key.platform.private_key_pem
    timeout     = "10m"
  }

  # Upload the whole scripts/ tree to the operator's home directory.
  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/home/${var.rhel_user}"
  }

  # Move the playbooks into place under /etc/ansible/playbooks and launch the
  # full platform install as a DETACHED background unit, then return immediately.
  #
  # Crucially this does NOT hold the SSH session open waiting for cloud-init:
  # the control node's bootstrap compiles Python from source (~20 min on
  # t3.micro), and keeping one provisioner SSH channel open that long is fragile
  # (the session can drop with "remote command exited without exit status").
  # Instead, run_platform_install.sh itself does `cloud-init status --wait` first,
  # so the long wait happens inside the detached systemd unit. The install
  # (MQ + queue managers + MQ Console + ACE + integration nodes/servers) plus the
  # every-2-min validation cron all run as part of `terraform apply`; the
  # dashboard on :8090 tracks progress as the nodes come up.
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/ansible/playbooks",
      "sudo cp -r /home/${var.rhel_user}/scripts/. /etc/ansible/playbooks/",
      "sudo chown -R root:root /etc/ansible/playbooks",
      "sudo install -m 0755 /etc/ansible/playbooks/run_platform_install.sh /usr/local/bin/run_platform_install.sh",
      "sudo install -m 0755 /etc/ansible/playbooks/run_validate.sh /usr/local/bin/run_validate.sh",
      # Drop the "platform ready" notification config (verified SES sender) so
      # run_platform_install.sh can email the dashboard URL on success. Rewritten
      # on every apply, so no instance replacement is needed to (re)configure it.
      "printf 'NOTIFY_EMAIL=%s\\nDASHBOARD_PORT=8090\\nAWS_DEFAULT_REGION=${var.aws_region}\\n' '${var.notify_email}' | sudo tee /etc/platform-notify.conf >/dev/null",
      "echo 'Playbooks deployed to /etc/ansible/playbooks/'",
      # Detached transient unit: survives this SSH session; apply returns at once.
      "sudo systemctl stop platform-install.service 2>/dev/null || true",
      "sudo systemctl reset-failed platform-install.service 2>/dev/null || true",
      "sudo systemd-run --unit=platform-install --collect --description='MQ/ACE platform install' /usr/local/bin/run_platform_install.sh",
      "echo 'Platform install launched (waits for cloud-init internally). Watch: sudo journalctl -u platform-install -f  or  tail -f /var/log/platform-install.log'",
    ]
  }
}
