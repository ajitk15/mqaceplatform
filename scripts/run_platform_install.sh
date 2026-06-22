#!/bin/bash
###############################################################################
# run_platform_install.sh — end-to-end platform install driver.
#
# Launched (detached) by Terraform's deploy_playbooks provisioner right after
# the playbooks are copied to /etc/ansible/playbooks. It makes MQ/ACE install,
# queue-manager / integration-node setup, and the validation cron all part of
# `terraform apply` instead of a manual step.
#
# Steps:
#   1. install the every-2-min validation cron up front (so the :8090 dashboard
#      tracks progress red -> green while the long install runs);
#   2. wait until every MQ server's cloud-init bootstrap is done (Python built,
#      control-node SSH key in place) and Ansible can reach it;
#   3. run install_platform.yml — MQ install + queue managers + MQ Console +
#      ACE install + integration nodes (NODE1/NODE2) + integration servers;
#   4. render the dashboard once immediately.
#
# Watch:  journalctl -u platform-install -f   (or)   tail -f /var/log/platform-install.log
###############################################################################
set -uo pipefail

LOG=/var/log/platform-install.log
exec > >(tee -a "$LOG") 2>&1

PB_DIR=/etc/ansible/playbooks
export ANSIBLE_CONFIG=/etc/ansible/ansible.cfg
export HOME=/root
cd "$PB_DIR" || exit 1

echo "############################################################"
echo "=== platform install started $(date) ==="

# Wait for the control node's own bootstrap (cloud-init) to finish before using
# Ansible — it compiles Python from source and installs ansible-core/pip ansible.
# This runs inside the detached systemd unit, so a long wait is fine.
echo "=== waiting for cloud-init to finish on the control node ==="
cloud-init status --wait || true
echo "cloud-init done: $(cloud-init status 2>/dev/null || echo unknown)"

# Prefer the proven RHEL AppStream ansible-core (2.14) over the pip build (2.21).
ANSIBLE_PLAYBOOK=""
for c in /usr/bin/ansible-playbook /usr/local/bin/ansible-playbook; do
  [ -x "$c" ] && ANSIBLE_PLAYBOOK="$c" && break
done
[ -z "$ANSIBLE_PLAYBOOK" ] && { echo "FATAL: ansible-playbook not found"; exit 1; }
ANSIBLE="$(dirname "$ANSIBLE_PLAYBOOK")/ansible"
echo "using: $ANSIBLE_PLAYBOOK"

# --- 1. Validation cron (every 2 minutes) --------------------------------------
install -m 0755 "$PB_DIR/run_validate.sh" /usr/local/bin/run_validate.sh
cat > /etc/cron.d/mq-ace-validate <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
# Render the MQ/ACE status dashboard every 2 minutes.
*/2 * * * * root /usr/local/bin/run_validate.sh >> /var/log/platform-validate.log 2>&1
CRON
chmod 0644 /etc/cron.d/mq-ace-validate
systemctl enable --now crond 2>/dev/null || true
echo "validation cron installed (/etc/cron.d/mq-ace-validate)"

# --- 2. Wait for all MQ servers to finish bootstrapping ------------------------
echo "=== waiting for all MQ servers to be reachable (max ~40 min) ==="
reachable=0
for i in $(seq 1 80); do   # 80 * 30s = 40 min
  if "$ANSIBLE" all_mq_servers -m ping -o >/tmp/platform-ping.out 2>&1; then
    echo "all servers reachable after $i attempt(s)"
    reachable=1
    break
  fi
  echo "[$i/80] not all servers ready yet (still bootstrapping); retry in 30s"
  sleep 30
done
[ "$reachable" -ne 1 ] && echo "WARNING: proceeding though not all servers answered ping"

# --- 3. Full platform install --------------------------------------------------
echo "=== running install_platform.yml ==="
"$ANSIBLE_PLAYBOOK" install_platform.yml
RC=$?
echo "=== install_platform.yml finished, rc=$RC ==="

# --- 4. Render the dashboard immediately ---------------------------------------
/usr/local/bin/run_validate.sh || true

# --- 5. Email the dashboard as an HTML attachment via SES (on a clean install) -
# Firewall-proof delivery: the recipient opens the attached .html locally in a
# browser — no network access to the AWS public IP, and no tunnel (Cloudflare etc.
# are blocked on the target network). email_dashboard.sh builds a MIME message
# with the rendered :8090 dashboard attached and sends it via SES send-raw-email.
if [ "$RC" -eq 0 ]; then
  SUBJECT="MQ/ACE platform is ready — dashboard attached" /usr/local/bin/email_dashboard.sh || true
else
  echo "notify: install rc=$RC (not 0) — skipping ready notification"
fi

echo "=== platform install complete $(date), rc=$RC ==="
echo "############################################################"
exit $RC
