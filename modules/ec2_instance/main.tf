###############################################################################
# Module: ec2_instance
###############################################################################

# FIX #10 – all variables now have type and description

variable "name" {
  description = "Name tag applied to the instance and root volume"
  type        = string
}

variable "ami_id" {
  description = "AMI ID to launch"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (e.g. t3.large)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID to place the instance in"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "security_group_ids" {
  description = "List of security group IDs to attach"
  type        = list(string)
}

variable "common_tags" {
  description = "Tags merged onto all resources"
  type        = map(string)
}

variable "user_data" {
  description = "Cloud-init bootstrap script content"
  type        = string
  default     = ""
}

variable "iam_instance_profile" {
  description = "Optional IAM instance profile name to attach (e.g. for Secrets Manager access)"
  type        = string
  default     = null
}

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.iam_instance_profile
  user_data                   = var.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens = "required"  # IMDSv2 enforced
  }

  tags = merge(var.common_tags, { Name = var.name })
}

output "public_ip"   { value = aws_instance.this.public_ip }
output "private_ip"  { value = aws_instance.this.private_ip }
output "instance_id" { value = aws_instance.this.id }
