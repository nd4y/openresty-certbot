#!/bin/bash
set -euo pipefail
CONFIG_FILE="$1"

CERT_DIR="/etc/letsencrypt/live"
RENEWAL_DIR="/etc/letsencrypt/renewal"
ARCHIVE_DIR="/etc/letsencrypt/archive"
LOG_TS_FORMAT="+%Y-%m-%dT%H:%M:%S%z"
STANDALONE_PORT=8080
POSTHOOK_DIR="/posthooks"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date "$LOG_TS_FORMAT")
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"msg\":\"$msg\"}"
}

cleanup_missing() {
  declare -A desired_certs=()
  for i in $(yq eval '.certificates | keys | .[]' "$CONFIG_FILE"); do
    name=$(yq eval ".certificates[$i].name" "$CONFIG_FILE")
    desired_certs["$name"]=1
  done

  for conf in "$RENEWAL_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    existing=$(basename "$conf" .conf)
    if [[ -z "${desired_certs[$existing]+found}" ]]; then
      log INFO "Removing orphaned certificate: $existing"
      certbot delete --cert-name "$existing" --non-interactive --quiet >/dev/null 2>&1 || \
        log WARN "Failed to delete $existing via certbot, removing manually"
      rm -rf \
        "$CERT_DIR/$existing" \
        "$ARCHIVE_DIR/$existing" \
        "$RENEWAL_DIR/$existing.conf" || true
    fi
  done

  find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r dir; do
    dir_name=$(basename "$dir")
    if [[ ! -f "$RENEWAL_DIR/$dir_name.conf" && -z "${desired_certs[$dir_name]+found}" ]]; then
      log WARN "Orphan live directory found (no renewal): $dir_name — removing manually"
      rm -rf "$CERT_DIR/$dir_name" "$ARCHIVE_DIR/$dir_name" || true
    fi
  done
}

issue_missing() {
  local total new_issued=0
  total=$(yq eval '.certificates | length' "$CONFIG_FILE")

  for ((i = 0; i < total; i++)); do
    name=$(yq eval ".certificates[$i].name" "$CONFIG_FILE")
    validation=$(yq eval ".certificates[$i].validation" "$CONFIG_FILE")
    dns_plugin=$(yq eval ".certificates[$i].dns_plugin" "$CONFIG_FILE" 2>/dev/null || echo "")
    api_token=$(yq eval ".certificates[$i].api_token" "$CONFIG_FILE" 2>/dev/null || echo "")
    credentials_file=$(yq eval ".certificates[$i].credentials_file" "$CONFIG_FILE" 2>/dev/null || echo "")
    staging=$(yq eval ".certificates[$i].staging" "$CONFIG_FILE" 2>/dev/null || echo "false")
    email=$(yq eval ".certificates[$i].email" "$CONFIG_FILE" 2>/dev/null || echo "admin@example.com")
    post_hook=$(yq eval ".certificates[$i].post_hook" "$CONFIG_FILE" 2>/dev/null || echo "")
    extra_args=$(yq eval ".certificates[$i].extra_args" "$CONFIG_FILE" 2>/dev/null || echo "")
    yaml_domains=($(yq eval ".certificates[$i].domains[]" "$CONFIG_FILE"))

    local existing_domains=()
    if certbot certificates --cert-name "$name" >/tmp/certinfo 2>/dev/null; then
      existing_domains=($(grep "Domains:" /tmp/certinfo | cut -d':' -f2- | tr -s ' ' '\n' | sort))
    fi

    local yaml_sorted=$(printf "%s\n" "${yaml_domains[@]}" | sort)
    local existing_sorted=$(printf "%s\n" "${existing_domains[@]}" | sort)

    local reissue_needed=false
    if [[ "$yaml_sorted" != "$existing_sorted" ]]; then
      reissue_needed=true
    fi

    if [ -f "$RENEWAL_DIR/$name.conf" ]; then
      current_auth=$(grep -E '^authenticator *= *' "$RENEWAL_DIR/$name.conf" | awk -F= '{print $2}' | tr -d '[:space:]')
      desired_auth=""
      if [[ "$validation" == "dns" ]]; then
        desired_auth="dns-$dns_plugin"
      elif [[ "$validation" == "http" ]]; then
        desired_auth="standalone"
      fi
      if [[ "$current_auth" != "$desired_auth" ]]; then
        log INFO "Validation method changed for $name ($current_auth → $desired_auth)"
        reissue_needed=true
      fi
    fi

    if [ "$validation" == "dns" ] && [ -f "$RENEWAL_DIR/$name.conf" ]; then
      if ! grep -q "$credentials_file" "$RENEWAL_DIR/$name.conf" 2>/dev/null; then
        log INFO "DNS credentials or plugin changed for $name"
        reissue_needed=true
      fi
    fi

    if [[ "$reissue_needed" == "true" && -d "$CERT_DIR/$name" ]]; then
      log INFO "Reissuing certificate for $name due to config changes"
      certbot delete --cert-name "$name" --non-interactive --quiet >/dev/null 2>&1 || true
      rm -rf "$CERT_DIR/$name" "$ARCHIVE_DIR/$name" "$RENEWAL_DIR/$name.conf" || true
    elif [ -d "$CERT_DIR/$name" ]; then
      log INFO "Certificate $name already exists and configuration matches, skipping."
      continue
    fi

    log INFO "Issuing new certificate: $name"
    CMD=(certbot certonly --non-interactive --agree-tos --email "$email" --cert-name "$name")
    [[ "$staging" == "true" ]] && CMD+=("--staging")

    if [[ "$validation" == "dns" ]]; then
      if [[ -n "$credentials_file" && "$credentials_file" != "null" ]]; then
        CMD+=("--dns-$dns_plugin" "--dns-$dns_plugin-credentials" "$credentials_file")
      elif [[ -n "$api_token" && "$api_token" != "null" ]]; then
        TMP_FILE="/tmp/${dns_plugin}-$(date +%s).ini"
        echo "dns_${dns_plugin}_api_token = ${api_token}" > "$TMP_FILE"
        chmod 600 "$TMP_FILE"
        CMD+=("--dns-$dns_plugin" "--dns-$dns_plugin-credentials" "$TMP_FILE")
      else
        log ERROR "No credentials for DNS plugin $dns_plugin"
        continue
      fi
    elif [[ "$validation" == "http" ]]; then
      CMD+=("--standalone" "--http-01-port" "$STANDALONE_PORT")
    else
      log ERROR "Unknown validation method '$validation' for $name"
      continue
    fi

    for d in "${yaml_domains[@]}"; do
      CMD+=("-d" "$d")
    done

    if [[ -n "$post_hook" && "$post_hook" != "null" ]]; then
      if [[ -x "$POSTHOOK_DIR/$post_hook" ]]; then
        log INFO "Using post-hook script: $POSTHOOK_DIR/$post_hook"
        CMD+=("--deploy-hook" "$POSTHOOK_DIR/$post_hook" "--disable-hook-validation")
      else
        log INFO "Using inline post-hook command: $post_hook"
        CMD+=("--deploy-hook" "$post_hook" "--disable-hook-validation")
      fi
    fi

    if [[ -n "$extra_args" && "$extra_args" != "null" ]]; then
      read -r -a EXTRA <<<"$extra_args"
      CMD+=("${EXTRA[@]}")
    fi

    log DEBUG "Running: ${CMD[*]}"
    if "${CMD[@]}" >/tmp/certbot_run.log 2>&1; then
      log INFO "Successfully issued certificate for $name"
      ((new_issued++))
    else
      log ERROR "Failed to issue certificate for $name"
      tail -n 10 /tmp/certbot_run.log | sed 's/^/  /' | while read -r line; do
        log DEBUG "Certbot: $line"
      done
    fi

    sleep 5
  done

  if ((new_issued > 0)); then
    log INFO "Issued $new_issued new certificate(s)"
  else
    log INFO "No new certificates needed"
  fi
}

main() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log ERROR "Config file not found: $CONFIG_FILE"
    exit 1
  fi

  log INFO "Syncing Certbot state with YAML configuration..."
  cleanup_missing
  issue_missing
  log INFO "Sync complete."
}

main "$@" || log WARN "Issue script completed with warnings"
exit 0
