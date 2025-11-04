#!/bin/bash
set -euo pipefail

CONFIG_FILE="/certbot/certs.yaml"
RENEW_INTERVAL_HOURS=12
LOG_TS_FORMAT="+%Y-%m-%dT%H:%M:%S%z"
POSTHOOK_DIR="/posthooks"

# ────────────────────────────────────────────────
# JSON logging
# ────────────────────────────────────────────────
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date "$LOG_TS_FORMAT")
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"msg\":\"$msg\"}"
}

log INFO "Starting certbot"
log INFO "Watching $CONFIG_FILE"
log INFO "Renew interval ${RENEW_INTERVAL_HOURS}h"

# ────────────────────────────────────────────────
# Function to extract post-hook from YAML
# ────────────────────────────────────────────────
get_posthook_arg() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo ""
    return
  fi
  local hooks=()
  while IFS= read -r hook; do
    [ -z "$hook" ] && continue
    if [ -x "$POSTHOOK_DIR/$hook" ]; then
      hooks+=(--deploy-hook "$POSTHOOK_DIR/$hook")
    else
      hooks+=(--deploy-hook "$hook")
    fi
  done < <(yq -r '.certificates[].post_hook | select(. != null)' "$CONFIG_FILE" 2>/dev/null || true)

  if [ ${#hooks[@]} -gt 0 ]; then
    echo "${hooks[*]} --disable-hook-validation"
  else
    echo ""
  fi
}

# ────────────────────────────────────────────────
# Initial synchronization on start
# ────────────────────────────────────────────────
log INFO "Initial certificate issuance check"
if /scripts/issue_from_yaml.sh "$CONFIG_FILE"; then
  log INFO "Initial sync completed"
else
  log WARN "Initial sync finished with warnings"
fi

# ────────────────────────────────────────────────
# Scheduled certificate renewal (after sync)
# ────────────────────────────────────────────────
(
  while true; do
    log INFO "Running scheduled renew"

    # Get posthook from YAML
    POSTHOOK_ARGS="$(get_posthook_arg)"

    if ! certbot renew $POSTHOOK_ARGS >/tmp/certbot-renew.log 2>&1; then
      log WARN "Scheduled renew failed"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '{"ts":"%s","level":"DEBUG","msg":"renew: %s"}\n' "$(date -u +%FT%TZ)" "$(echo "$line" | sed 's/"/\\"/g')"
      done < /tmp/certbot-renew.log
    else
      log INFO "Scheduled renew completed successfully"
    fi

    sleep "${RENEW_INTERVAL_HOURS}h"
  done
) &

# ────────────────────────────────────────────────
# Watching for changes in YAML
# ────────────────────────────────────────────────
while true; do
  if [ ! -f "$CONFIG_FILE" ]; then
    log WARN "Config file not found ($CONFIG_FILE), waiting 10s..."
    sleep 10
    continue
  fi

  log DEBUG "Waiting for changes in $CONFIG_FILE"

  # wait for change event on the file
  if inotifywait -q -e modify,close_write,move,create "$CONFIG_FILE" >/dev/null 2>&1; then
    log INFO "Config file changed, processing"
    if /scripts/issue_from_yaml.sh "$CONFIG_FILE"; then
      log INFO "Sync completed after config change"
    else
      log WARN "Sync completed with warnings after config change"
    fi
    sleep 2
  else
    log WARN "inotifywait returned non-zero, retrying in 10s"
    sleep 10
  fi
done
