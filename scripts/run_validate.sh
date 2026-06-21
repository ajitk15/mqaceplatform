#!/bin/bash
###############################################################################
# run_validate.sh — cron target. Renders the MQ/ACE status dashboard by running
# validate_platform.yml, which writes /home/ec2-user/validate-www/index.html
# (served on :8090 by validate-dashboard.service).
#
# Installed to /usr/local/bin/run_validate.sh and invoked every 2 minutes by
# /etc/cron.d/mq-ace-validate.
###############################################################################
set -uo pipefail

PB_DIR=/etc/ansible/playbooks
export ANSIBLE_CONFIG=/etc/ansible/ansible.cfg
export HOME=/root
cd "$PB_DIR" || exit 1

# Prefer the proven RHEL AppStream ansible-core (2.14) over the pip build (2.21).
ANSIBLE_PLAYBOOK=""
for c in /usr/bin/ansible-playbook /usr/local/bin/ansible-playbook; do
  [ -x "$c" ] && ANSIBLE_PLAYBOOK="$c" && break
done
[ -z "$ANSIBLE_PLAYBOOK" ] && { echo "$(date): ansible-playbook not found"; exit 1; }

echo "=== $(date): rendering dashboard ==="
"$ANSIBLE_PLAYBOOK" validate_platform.yml
