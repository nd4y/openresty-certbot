#!/bin/bash
set -euo pipefail
LOG_TS_FORMAT="+%Y-%m-%dT%H:%M:%S%z"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date "$LOG_TS_FORMAT")
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"msg\":\"$msg\"}"
}

log INFO "Reloading OpenResty after cert update..."
RESPONSE=$(curl -s -m 5 -w "%{http_code}" -o /tmp/reload_body.txt http://openresty:8081/reload || echo "000")
BODY=$(cat /tmp/reload_body.txt 2>/dev/null || true)

if [[ "$RESPONSE" == "200" && "$BODY" == *"reloaded"* ]]; then
  log INFO "OpenResty reload confirmed: $BODY"
  exit 0
else
  log ERROR "OpenResty reload failed: HTTP $RESPONSE, body: $BODY"
  exit 1
fi
