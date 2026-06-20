###############################################################################
# Outputs
###############################################################################

output "server1_public_ip" {
  description = "Server 1 (MQ) public IP"
  value       = module.server1.public_ip
}

output "server2_public_ip" {
  description = "Server 2 (MQ+ACE) public IP"
  value       = module.server2.public_ip
}

output "server3_public_ip" {
  description = "Server 3 (MQ+ACE) public IP"
  value       = module.server3.public_ip
}

output "ansible_control_public_ip" {
  description = "Ansible Control Node public IP"
  value       = module.ansible_control.public_ip
}

output "ansible_control_private_ip" {
  description = "Ansible Control Node private IP"
  value       = module.ansible_control.private_ip
}

output "mcp_url" {
  description = "MCP server endpoint"
  value       = "http://${module.ansible_control.public_ip}:${var.mcp_port}"
}

output "chatbot_url" {
  description = "Chatbot service endpoint"
  value       = "http://${module.ansible_control.public_ip}:${var.chatbot_port}"
}

output "ssh_command_ansible" {
  description = "SSH command to reach the Ansible control node"
  value       = "ssh -i ${var.platform_name}-key.pem ${var.rhel_user}@${module.ansible_control.public_ip}"
}

output "ssh_command_server1" {
  description = "SSH to Server 1 (MQ)"
  value       = "ssh -i ${var.platform_name}-key.pem ${var.rhel_user}@${module.server1.public_ip}"
}

output "ami_used" {
  description = "RHEL AMI resolved by the data source"
  value       = data.aws_ami.rhel.id
}

output "key_pair_name" {
  description = "EC2 key pair name"
  value       = aws_key_pair.platform.key_name
}

# FIX #17 – removed spurious sensitive=true on the path; the path itself is not secret.
# The private key content is never exposed as an output (it is only in Secrets Manager).
output "private_key_local_path" {
  description = "Path to the generated private key on your local machine (keep this file secure)"
  value       = local_file.private_key.filename
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding the platform SSH private key"
  value       = aws_secretsmanager_secret.platform_key.arn
}
