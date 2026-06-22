###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy the platform"
  type        = string
  default     = "us-east-1"
}

variable "platform_name" {
  description = "Prefix used for all resource names"
  type        = string
  default     = "rhel-mq-platform"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "rhel_version" {
  description = "RHEL major version (9 recommended)"
  type        = string
  default     = "9"
}

variable "rhel_user" {
  description = "Default SSH user for RHEL AMIs"
  type        = string
  default     = "ec2-user"
}

variable "instance_type_mq" {
  description = "EC2 instance type for MQ-only servers (Server 1 & 4)"
  type        = string
  default     = "t3.large"
}

variable "instance_type_mq_ace" {
  description = "EC2 instance type for MQ+ACE servers (Server 2 & 3)"
  type        = string
  default     = "t3.xlarge"
}

variable "instance_type_ansible" {
  description = "EC2 instance type for Ansible control node"
  type        = string
  default     = "t3.medium"
}

variable "python_version" {
  description = "Python version to compile and install (must be >= 3.13, e.g. '3.13')"
  type        = string
  default     = "3.13"

  validation {
    condition     = tonumber(split(".", var.python_version)[1]) >= 13
    error_message = "python_version must be 3.13 or higher (e.g. '3.13', '3.14')."
  }
}

# FIX #11 – no default; operator must explicitly set their IP
variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach SSH and management ports. Must be set explicitly (e.g. [\"YOUR_IP/32\"])."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidr_blocks) > 0
    error_message = "allowed_cidr_blocks must not be empty. Set it to your IP, e.g. [\"1.2.3.4/32\"]."
  }
}

variable "environment" {
  description = "Environment label (dev / staging / prod)"
  type        = string
  default     = "dev"
}

# Email address that receives an SNS notification (with the :8090 dashboard URL)
# each time the platform install finishes successfully. SNS email notifications
# are free for the first 1,000/month — no SMTP/password required. The address
# must confirm a one-time subscription link AWS emails on first apply.
variable "notify_email" {
  description = "Email address to notify with the dashboard URL when infrastructure is ready (empty = disabled)"
  type        = string
  default     = ""
}

# CIDRs allowed to reach the MCP server on :8001 *in addition to* the operator
# IP — for a remote chat backend (e.g. hosted on Render) that can't be pinned to
# a single egress IP. Empty = no extra access. ["0.0.0.0/0"] opens it to the
# whole internet (demo only: the MCP is plain HTTP protected solely by Basic
# Auth, so rotate the default mcpadmin password before exposing it).
variable "mcp_allowed_cidr_blocks" {
  description = "Extra CIDRs allowed inbound to the MCP server on :8001 (e.g. a remote backend). Empty = none."
  type        = list(string)
  default     = []
}

# Secure gateway (Caddy on the control node) — fronts the platform's web
# services behind one HTTPS endpoint (:443) with Basic Auth, so the otherwise
# auth-less dashboard isn't exposed directly. Username for the gateway login;
# the password's bcrypt hash is read from SSM /<platform>/gateway-password-hash.
variable "gateway_username" {
  description = "Basic-auth username for the Caddy secure gateway on :443"
  type        = string
  default     = "admin"
}

# CIDRs allowed to reach the gateway on :443. TLS + Basic Auth protect it, so
# ["0.0.0.0/0"] is acceptable (demo). Empty = no gateway access rule created.
variable "gateway_allowed_cidr_blocks" {
  description = "CIDRs allowed inbound to the secure gateway on :443"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Auto stop/start the EC2 instances on a schedule to save cost / stretch free
# credits (stop overnight, start on weekday mornings). Implemented with
# EventBridge Scheduler calling the EC2 API directly (no Lambda). Data persists
# across stop/start; private IPs (Ansible inventory) and the control-node EIP are
# unchanged, so the platform comes back end-to-end on start.
variable "enable_instance_scheduler" {
  description = "Create EventBridge schedules to auto stop/start all platform EC2 instances"
  type        = bool
  default     = true
}

variable "scheduler_timezone" {
  description = "IANA timezone for the stop/start cron schedules (e.g. Asia/Kolkata, UTC)"
  type        = string
  default     = "Asia/Kolkata"
}

variable "instance_stop_cron" {
  description = "EventBridge Scheduler cron for stopping instances (default 21:00 daily)"
  type        = string
  default     = "cron(0 21 * * ? *)"
}

variable "instance_start_cron" {
  description = "EventBridge Scheduler cron for starting instances (default 08:00 Mon-Fri)"
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

# Optional: private S3 bucket holding the IBM MQ/ACE developer binaries.
# Leave empty to skip granting S3 access (default). Set it to enable the
# Ansible control node to pull binaries from S3 (see scripts/install_platform.yml).
variable "mq_ace_s3_bucket" {
  description = "Name of the private S3 bucket holding MQ/ACE installer archives (empty = disabled)"
  type        = string
  default     = ""
}
