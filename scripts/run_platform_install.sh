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

# --- 5. Email the dashboard URL via SES (only on a clean install) --------------
# Free, no SMTP/password: sends from/to the verified SES address written by
# Terraform into /etc/platform-notify.conf. The address must be SES-verified once.
notify_ready() {
  [ -r /etc/platform-notify.conf ] || { echo "notify: no /etc/platform-notify.conf — skipping"; return; }
  # shellcheck disable=SC1091
  . /etc/platform-notify.conf
  [ -n "${NOTIFY_EMAIL:-}" ] || { echo "notify: NOTIFY_EMAIL empty — skipping"; return; }

  # IMDSv2 token (falls back to IMDSv1 if token fetch fails).
  local tok ip region port url body msg
  tok=$(curl -s --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
  ip=$(curl -s --max-time 3 ${tok:+-H "X-aws-ec2-metadata-token: $tok"} \
        http://169.254.169.254/latest/meta-data/public-ipv4 || echo unknown)
  region=${AWS_DEFAULT_REGION:-us-east-1}
  port="${DASHBOARD_PORT:-8090}"
  url="http://${ip}:${port}"

  body="Your IBM MQ/ACE platform install finished successfully.\n\nDashboard: ${url}\n\n(Generated automatically at $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_platform_install.sh)"
  msg=$(mktemp /tmp/ses-ready.XXXXXX.json)
  cat > "$msg" <<JSON
{
  "Source": "${NOTIFY_EMAIL}",
  "Destination": { "ToAddresses": ["${NOTIFY_EMAIL}"] },
  "Message": {
    "Subject": { "Data": "MQ/ACE platform is ready", "Charset": "UTF-8" },
    "Body": { "Text": { "Data": "${body}", "Charset": "UTF-8" } }
  }
}
JSON
  aws ses send-email --region "$region" --cli-input-json "file://$msg" \
    && echo "notify: sent ready email to $NOTIFY_EMAIL ($url)" \
    || echo "notify: SES send-email failed (non-fatal)"
  rm -f "$msg"
}

if [ "$RC" -eq 0 ]; then
  notify_ready || true
else
  echo "notify: install rc=$RC (not 0) — skipping ready notification"
fi

echo "=== platform install complete $(date), rc=$RC ==="
echo "############################################################"
exit $RC
