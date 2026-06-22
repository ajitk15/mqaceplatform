#!/bin/bash
###############################################################################
# email_dashboard.sh — email the MQ/ACE status dashboard as an HTML attachment.
#
# Firewall-proof way to view the :8090 dashboard from networks that block the
# AWS public IP and tunnels (Cloudflare etc.): the recipient just opens the
# attached mq-ace-dashboard.html locally in any browser — no connectivity to the
# platform required. Delivered via Amazon SES send-raw-email (supports
# attachments, unlike send-email).
#
# Reads from /etc/platform-notify.conf (written by Terraform's deploy step):
#   NOTIFY_EMAIL        verified SES address (from + to)
#   AWS_DEFAULT_REGION  SES region
#   DASHBOARD_HTML      path to the rendered dashboard (optional override)
#
# Usage:
#   email_dashboard.sh [--refresh]      # --refresh re-renders the dashboard first
#   SUBJECT="custom subject" email_dashboard.sh
#
# Snapshot is point-in-time. A cron can send it periodically — mind the SES
# sandbox quota (200/day): e.g. every 30 min = 48/day.
###############################################################################
set -uo pipefail

CONF=/etc/platform-notify.conf
[ -r "$CONF" ] || { echo "email_dashboard: no $CONF — skipping"; exit 0; }
# shellcheck disable=SC1090
. "$CONF"

[ -n "${NOTIFY_EMAIL:-}" ] || { echo "email_dashboard: NOTIFY_EMAIL empty — skipping"; exit 0; }
REGION=${AWS_DEFAULT_REGION:-us-east-1}
HTML=${DASHBOARD_HTML:-/home/ec2-user/validate-www/index.html}

# Optionally re-render the dashboard to capture the very latest status.
if [ "${1:-}" = "--refresh" ] && [ -x /usr/local/bin/run_validate.sh ]; then
  /usr/local/bin/run_validate.sh >/dev/null 2>&1 || true
fi

[ -r "$HTML" ] || { echo "email_dashboard: dashboard html not found at $HTML — skipping"; exit 0; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SUBJECT=${SUBJECT:-"MQ/ACE dashboard snapshot ($TS)"}
BOUNDARY="mqace_$(date +%s)_$$"
B64=$(base64 "$HTML")   # GNU base64 wraps at 76 cols (MIME-safe)

MIME=$(mktemp /tmp/mqace-mail.XXXXXX)
{
  printf 'From: %s\n' "$NOTIFY_EMAIL"
  printf 'To: %s\n' "$NOTIFY_EMAIL"
  printf 'Subject: %s\n' "$SUBJECT"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: multipart/mixed; boundary="%s"\n\n' "$BOUNDARY"
  printf -- '--%s\n' "$BOUNDARY"
  printf 'Content-Type: text/plain; charset=UTF-8\n\n'
  printf 'Attached is the current IBM MQ/ACE platform status dashboard.\n'
  printf 'Open mq-ace-dashboard.html in any browser — no network access to the platform is required.\n\n'
  printf 'Captured (UTC): %s\n\n' "$TS"
  printf -- '--%s\n' "$BOUNDARY"
  printf 'Content-Type: text/html; charset=UTF-8; name="mq-ace-dashboard.html"\n'
  printf 'Content-Transfer-Encoding: base64\n'
  printf 'Content-Disposition: attachment; filename="mq-ace-dashboard.html"\n\n'
  printf '%s\n\n' "$B64"
  printf -- '--%s--\n' "$BOUNDARY"
} > "$MIME"

# SES RawMessage.Data is a blob: base64-encode the whole MIME message (single
# line) and pass via cli-input-json. (fileb:// isn't expanded inside the
# --raw-message shorthand, so this is the portable path.)
RAW_B64=$(base64 -w0 "$MIME")
JSON=$(mktemp /tmp/mqace-raw.XXXXXX.json)
printf '{"RawMessage":{"Data":"%s"}}' "$RAW_B64" > "$JSON"

if aws ses send-raw-email --region "$REGION" --cli-input-json "file://$JSON"; then
  echo "email_dashboard: sent snapshot to $NOTIFY_EMAIL ($TS)"
  rc=0
else
  echo "email_dashboard: SES send-raw-email failed"
  rc=1
fi
rm -f "$MIME" "$JSON"
exit $rc
