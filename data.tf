###############################################################################
# Data Sources
###############################################################################

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

# Current AWS account & region (useful for outputs / ARN construction)
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
