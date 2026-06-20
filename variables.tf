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

# Optional: private S3 bucket holding the IBM MQ/ACE developer binaries.
# Leave empty to skip granting S3 access (default). Set it to enable the
# Ansible control node to pull binaries from S3 (see scripts/install_platform.yml).
variable "mq_ace_s3_bucket" {
  description = "Name of the private S3 bucket holding MQ/ACE installer archives (empty = disabled)"
  type        = string
  default     = ""
}
