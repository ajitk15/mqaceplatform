#!/usr/bin/env bash
###############################################################################
# run_dumps.sh — run the MQ and ACE config extractors back-to-back and drop the
# consolidated CSVs into /opt/apps/mqaceserver/resources.
#
# Invoked hourly by cron on the Ansible control node (see schedule_dumps.yml).
# Safe to run by hand too:  /opt/apps/mqaceserver/run_dumps.sh
#
# Overridable via environment:
#   MQACE_PLAYBOOK_DIR   where the extract_*.yml live   (default below)
#   MQACE_INVENTORY      Ansible inventory file         (default /etc/ansible/hosts)
#   MQACE_RESOURCES_DIR  output directory for the CSVs  (default below)
###############################################################################
set -uo pipefail

# cron runs with a bare PATH; Ansible/Python live under /usr/local/bin here.
export PATH=/usr/local/bin:/usr/bin:/bin

PLAYBOOK_DIR="${MQACE_PLAYBOOK_DIR:-/opt/apps/mqaceserver/playbooks}"
INVENTORY="${MQACE_INVENTORY:-/etc/ansible/hosts}"
RESOURCES_DIR="${MQACE_RESOURCES_DIR:-/opt/apps/mqaceserver/resources}"
LOG_DIR="/var/log/mqace-dumps"

mkdir -p "$RESOURCES_DIR" "$LOG_DIR"
LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "starting MQ/ACE config dump extraction"
rc=0

run_pb() {
  local pb="$1"; shift
  log "running $pb"
  if ansible-playbook -i "$INVENTORY" "$PLAYBOOK_DIR/$pb" "$@" >> "$LOG" 2>&1; then
    log "$pb OK"
  else
    log "ERROR: $pb failed (see $LOG)"
    rc=1
  fi
}

run_pb extract_qmgr_dump.yml \
  -e "qmgr_dump_output=$RESOURCES_DIR/qmgr_dump.csv"

run_pb extract_node_dump.yml \
  -e "node_dump_output=$RESOURCES_DIR/node_dump.csv" \
  -e "node_config_output=$RESOURCES_DIR/node_config.csv"

# Keep the MQ+ACE MCP app's manifests current: copy the freshly generated CSVs
# into its resources/ dir (the MCP server reads them from there) — replace any
# existing copy. No-op if the app isn't deployed.
APP_RES="/opt/apps/mqaceserver/mqacemcp/resources"
if [ -d "$APP_RES" ]; then
  for f in qmgr_dump.csv node_dump.csv node_config.csv; do
    [ -f "$RESOURCES_DIR/$f" ] && install -m 0644 "$RESOURCES_DIR/$f" "$APP_RES/$f"
  done
  log "synced manifests to $APP_RES"
fi

# Retain ~1 week of hourly logs.
ls -1t "$LOG_DIR"/run-*.log 2>/dev/null | tail -n +169 | xargs -r rm -f

log "done (rc=$rc)"
exit "$rc"
