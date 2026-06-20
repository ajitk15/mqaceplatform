###############################################################################
# Module: security_groups
###############################################################################

# FIX #10 – all variables now have type and description

variable "name" {
  description = "Security group name"
  type        = string
}

variable "description" {
  description = "Security group description"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to create the security group in"
  type        = string
}

variable "common_tags" {
  description = "Tags merged onto the security group"
  type        = map(string)
}

variable "ingress_rules" {
  description = "List of ingress rule objects (from_port, to_port, protocol, cidr, description)"
  type        = list(any)
}

resource "aws_security_group" "this" {
  name        = var.name
  description = var.description
  vpc_id      = var.vpc_id

  # Allow all outbound (required for dnf updates, pip, Ansible Galaxy, Secrets Manager API)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(var.common_tags, { Name = var.name })
}

resource "aws_security_group_rule" "ingress" {
  count = length(var.ingress_rules)

  type              = "ingress"
  security_group_id = aws_security_group.this.id
  from_port         = var.ingress_rules[count.index].from_port
  to_port           = var.ingress_rules[count.index].to_port
  protocol          = var.ingress_rules[count.index].protocol
  cidr_blocks       = var.ingress_rules[count.index].cidr
  description       = var.ingress_rules[count.index].description
}

output "sg_id" {
  description = "ID of the created security group"
  value       = aws_security_group.this.id
}
