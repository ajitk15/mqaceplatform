###############################################################################
# Locals – port definitions & common tags
###############################################################################

locals {
  common_tags = {
    Project     = var.platform_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    OS          = "RedHat Linux"
  }

  # ---------------------------------------------------------------------------
  # IBM MQ default ports
  # 1414-1421 – MQ listeners within the VPC (CLUSRCVR/CLUSSDR cluster channels):
  #             1414 MQREPO1 (full repo, server1), 1415 QM1 (dev, server1),
  #             1416 MQREPO2 (full repo, server2), 1420 MQNODE1 (server2),
  #             1421 MQNODE2 (server3). 1417-1419 currently unused.
  # 9443  – MQ Web Console HTTPS
  # 9080  – MQ Web Console HTTP
  # 1883  – MQTT
  # 8883  – MQTT over TLS
  # 9157  – MQ Prometheus metrics exporter
  #
  # NOTE: SSH from the Ansible control node is added as a separate
  #       aws_security_group_rule (source_security_group_id) in main.tf (Fix #3).
  # ---------------------------------------------------------------------------
  mq_ingress_rules = [
    { from_port = 22,   to_port = 22,   protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "SSH from operator" },
    { from_port = 1414, to_port = 1421, protocol = "tcp", cidr = ["10.0.0.0/16"],          description = "MQ Listeners (cluster QMs 1414-1419 + ACE node QMs 1420-1421)" },
    { from_port = 9443, to_port = 9443, protocol = "tcp", cidr = var.allowed_cidr_blocks,   description = "MQ Web Console HTTPS" },
    { from_port = 9080, to_port = 9080, protocol = "tcp", cidr = var.allowed_cidr_blocks,   description = "MQ Web Console HTTP" },
    { from_port = 1883, to_port = 1883, protocol = "tcp", cidr = ["10.0.0.0/16"],           description = "MQTT" },
    { from_port = 8883, to_port = 8883, protocol = "tcp", cidr = ["10.0.0.0/16"],           description = "MQTT over TLS" },
    { from_port = 9157, to_port = 9157, protocol = "tcp", cidr = ["10.0.0.0/16"],           description = "MQ Prometheus Metrics" },
  ]

  # ---------------------------------------------------------------------------
  # IBM ACE (App Connect Enterprise) default ports
  # 7600  – Integration node listener
  # 7800  – Integration server HTTP
  # 7843  – Integration server HTTPS
  # 4414  – Web admin (ACE dashboard)
  # 9483  – ACE Web UI HTTPS
  # ---------------------------------------------------------------------------
  ace_ingress_rules = [
    { from_port = 7600, to_port = 7600, protocol = "tcp", cidr = ["10.0.0.0/16"],         description = "ACE Integration Node" },
    { from_port = 7800, to_port = 7800, protocol = "tcp", cidr = ["10.0.0.0/16"],         description = "ACE HTTP" },
    { from_port = 7843, to_port = 7843, protocol = "tcp", cidr = ["10.0.0.0/16"],         description = "ACE HTTPS" },
    { from_port = 4414, to_port = 4414, protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "ACE Admin" },
    { from_port = 9483, to_port = 9483, protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "ACE Web UI HTTPS" },
  ]

  # ---------------------------------------------------------------------------
  # Ansible control node ports
  # ---------------------------------------------------------------------------
  ansible_ingress_rules = [
    { from_port = 22,   to_port = 22,   protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "SSH from operator" },
    { from_port = 8090, to_port = 8090, protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "MQ/ACE status dashboard" },
    { from_port = 8000, to_port = 8010, protocol = "tcp", cidr = var.allowed_cidr_blocks, description = "MQ+ACE MCP stack (MCP server, chat backend, Streamlit UI, dashboard)" },
  ]
}
