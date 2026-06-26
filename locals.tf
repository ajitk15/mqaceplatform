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
  # Operator allow-list for SSH + management ports.
  # When var.auto_detect_ip is true, the public IP of the machine running
  # terraform (from data.http.my_public_ip) is added as a /32, so the SGs always
  # track the current dynamic IP without hand-editing terraform.tfvars. Any
  # CIDRs in var.allowed_cidr_blocks are appended (e.g. a fixed office range).
  # The conditional short-circuits, so the [0] index is only evaluated when the
  # data source actually exists (count = 1).
  # ---------------------------------------------------------------------------
  operator_cidrs = distinct(concat(
    var.auto_detect_ip ? ["${chomp(data.http.my_public_ip[0].response_body)}/32"] : [],
    var.allowed_cidr_blocks,
  ))

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
    { from_port = 22, to_port = 22, protocol = "tcp", cidr = local.operator_cidrs, description = "SSH from operator" },
    { from_port = 1414, to_port = 1421, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "MQ Listeners (cluster QMs 1414-1419 + ACE node QMs 1420-1421)" },
    { from_port = 9443, to_port = 9443, protocol = "tcp", cidr = local.operator_cidrs, description = "MQ Web Console HTTPS" },
    { from_port = 9080, to_port = 9080, protocol = "tcp", cidr = local.operator_cidrs, description = "MQ Web Console HTTP" },
    { from_port = 1883, to_port = 1883, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "MQTT" },
    { from_port = 8883, to_port = 8883, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "MQTT over TLS" },
    { from_port = 9157, to_port = 9157, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "MQ Prometheus Metrics" },
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
    { from_port = 7600, to_port = 7600, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "ACE Integration Node" },
    { from_port = 7800, to_port = 7800, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "ACE HTTP" },
    { from_port = 7843, to_port = 7843, protocol = "tcp", cidr = ["10.0.0.0/16"], description = "ACE HTTPS" },
    { from_port = 4414, to_port = 4414, protocol = "tcp", cidr = local.operator_cidrs, description = "ACE Admin" },
    { from_port = 9483, to_port = 9483, protocol = "tcp", cidr = local.operator_cidrs, description = "ACE Web UI HTTPS" },
  ]

  # ---------------------------------------------------------------------------
  # Ansible control node ports
  # 8090       – MQ/ACE status (validate) dashboard, served by validate-dashboard.service
  # 8000-8010  – MQ+ACE MCP stack (mqacemcp.service). Actual bindings within range:
  #              8001 MCP server (SSE, HTTP + Basic Auth — TLS disabled), 8002 chat
  #              backend (FastAPI), 8003 Streamlit UI, 8004 log dashboard. Range keeps
  #              headroom and matches the firewalld rule opened in setup_mqacemcp.yml.
  #              These stay operator-IP only; remote/human access is via the Caddy
  #              gateway (:443/:8444/:8445) and (for :8001) var.mcp_allowed_cidr_blocks.
  # ---------------------------------------------------------------------------
  ansible_ingress_rules = [
    { from_port = 22, to_port = 22, protocol = "tcp", cidr = local.operator_cidrs, description = "SSH from operator" },
    { from_port = 8090, to_port = 8090, protocol = "tcp", cidr = local.operator_cidrs, description = "MQ/ACE status dashboard" },
    { from_port = 8000, to_port = 8010, protocol = "tcp", cidr = local.operator_cidrs, description = "MQ+ACE MCP stack (8001 MCP/SSE, 8002 backend, 8003 UI, 8004 dashboard)" },
  ]
}
