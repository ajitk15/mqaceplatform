###############################################################################
# Red Hat Linux Platform – MQ/ACE + Ansible Control Node
# Architecture:
#   Server 1  → MQ only
#   Server 2  → MQ + ACE
#   Server 3  → MQ + ACE
#   Server 4  → MQ only
#   Ansible   → Ansible Control Node + MCP + Chatbot
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
# Key Pair – generated locally; private key stored in Secrets Manager (Fix #1, #2)
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

# FIX #1 & #2 – store private key in Secrets Manager; bootstrap script fetches it at runtime
resource "aws_secretsmanager_secret" "platform_key" {
  name                    = "${var.platform_name}/ssh-private-key"
  description             = "Platform SSH private key for Ansible control node"
  recovery_window_in_days = 0   # allow immediate destroy

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "platform_key" {
  secret_id     = aws_secretsmanager_secret.platform_key.id
  secret_string = tls_private_key.platform.private_key_pem
}

###############################################################################
# IAM Role – lets the Ansible control node read the secret (Fix #1)
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
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.platform_key.arn
    }]
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

module "sg_ace" {
  source        = "./modules/security_groups"
  name          = "${var.platform_name}-sg-ace"
  description   = "IBM ACE default ports"
  vpc_id        = aws_vpc.platform.id
  common_tags   = local.common_tags
  ingress_rules = local.ace_ingress_rules
}

module "sg_ansible" {
  source        = "./modules/security_groups"
  name          = "${var.platform_name}-sg-ansible"
  description   = "Ansible control node + MCP + Chatbot ports"
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
  user_data          = templatefile("${path.module}/scripts/mq_setup.sh.tpl", {
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
  user_data          = templatefile("${path.module}/scripts/mq_ace_setup.sh.tpl", {
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
  user_data          = templatefile("${path.module}/scripts/mq_ace_setup.sh.tpl", {
    python_version = var.python_version
    ansible_pubkey = tls_private_key.platform.public_key_openssh
  })
}

###############################################################################
# Ansible Control Node  (Ansible + MCP + Chatbot)
# FIX #8 – explicit depends_on ensures private IPs are resolved before templating
###############################################################################
module "ansible_control" {
  source             = "./modules/ec2_instance"
  name               = "${var.platform_name}-ansible-control"
  ami_id             = data.aws_ami.rhel.id
  instance_type      = var.instance_type_ansible
  subnet_id          = aws_subnet.platform.id
  key_name           = aws_key_pair.platform.key_name
  security_group_ids = [module.sg_ansible.sg_id]
  iam_instance_profile = aws_iam_instance_profile.ansible_control.name
  common_tags        = merge(local.common_tags, { Role = "AnsibleControl+MCP+Chatbot" })
  user_data          = templatefile("${path.module}/scripts/ansible_control_setup.sh.tpl", {
    python_version     = var.python_version
    secret_arn         = aws_secretsmanager_secret.platform_key.arn
    server1_ip         = module.server1.private_ip
    server2_ip         = module.server2.private_ip
    server3_ip         = module.server3.private_ip
    mcp_port           = var.mcp_port
    chatbot_port       = var.chatbot_port
    ansible_user       = var.rhel_user
  })

  depends_on = [
    module.server1,
    module.server2,
    module.server3,
    aws_secretsmanager_secret_version.platform_key,
  ]
}

###############################################################################
# Dynamic Ansible Inventory file – written locally for workstation use
# Uses PUBLIC IPs (operator → servers).
# The control node inventory (private IPs) is written by its bootstrap script.
###############################################################################
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory/hosts.ini"
  content  = templatefile("${path.module}/inventory/hosts.ini.tpl", {
    server1_ip   = module.server1.public_ip
    server2_ip   = module.server2.public_ip
    server3_ip   = module.server3.public_ip
    ansible_ip   = module.ansible_control.public_ip
    ssh_key_file = "${path.module}/${var.platform_name}-key.pem"
    ansible_user = var.rhel_user
  })
}
