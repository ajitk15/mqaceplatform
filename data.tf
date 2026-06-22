###############################################################################
# Data Sources
###############################################################################

# Current account ID — used to scope IAM policies to specific resource ARNs.
data "aws_caller_identity" "current" {}

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
