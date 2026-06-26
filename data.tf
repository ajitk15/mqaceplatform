###############################################################################
# Data Sources
###############################################################################

# Current account ID — used to scope IAM policies to specific resource ARNs.
data "aws_caller_identity" "current" {}

# Auto-detect the public IP of the machine running `terraform apply`.
# Used to keep the operator SSH/management SG rules locked to the current IP
# without having to hand-edit terraform.tfvars every time the ISP hands out a
# new dynamic address. Only consulted when var.auto_detect_ip = true (see
# local.operator_cidrs in locals.tf). checkip.amazonaws.com returns the bare
# IP plus a trailing newline, which is stripped with chomp() at the use site.
data "http" "my_public_ip" {
  count = var.auto_detect_ip ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  # Fail the apply loudly if the lookup doesn't return a clean 200, rather than
  # silently baking a garbage CIDR into the security groups.
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Public IP lookup failed (status ${self.status_code}). Set auto_detect_ip = false and populate allowed_cidr_blocks manually."
    }
  }
}

# Latest Red Hat Enterprise Linux 9 AMI (official Red Hat owner)
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"] # Official Red Hat AWS account

  filter {
    name   = "name"
    values = ["RHEL-${var.rhel_version}*GA*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}
