#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Defaults
# ----------------------------
DEFAULT_CONFIG_DIR="${CONFIG_DIR:-/data}"
DEFAULT_CONFIG="$DEFAULT_CONFIG_DIR/linode-ddns.conf"
LAST_IP_FILE="$DEFAULT_CONFIG_DIR/linode-ddns.lastip"
API_URL="https://api.linode.com/v4"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"  # Default 5 minutes
CONTINUOUS_MODE="${CONTINUOUS_MODE:-false}"

CONFIG="$DEFAULT_CONFIG"

# ----------------------------
# Command-line args
# ----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --continuous)
      CONTINUOUS_MODE="true"
      shift
      ;;
    --interval)
      CHECK_INTERVAL="$2"
      if [[ ! "$CHECK_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --interval must be a positive integer (got: $CHECK_INTERVAL)"
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Usage: $0 [--config /path/to/config] [--continuous] [--interval SECONDS]"
      exit 1
      ;;
  esac
done

# Validate CHECK_INTERVAL is a positive integer (after processing args)
if [[ ! "$CHECK_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CHECK_INTERVAL must be a positive integer (got: $CHECK_INTERVAL)"
  exit 1
fi

# ----------------------------
# Load PAT from environment or .env
# ----------------------------
if [[ -z "${PAT:-}" ]] && [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source ".env"
fi

if [[ -z "${PAT:-}" ]]; then
  echo "ERROR: No PAT found. Set PAT environment variable or create .env file with:"
  echo 'PAT="your_linode_api_token_here"'
  exit 1
fi

# ----------------------------
# Helpers
# ----------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

get_public_ip() {
  # reliable sources only
  local providers=("https://ipinfo.io/ip" "https://checkip.amazonaws.com" "https://api.ipify.org")
  for url in "${providers[@]}"; do
    local ip
    ip=$(curl -4 -s --max-time 10 --fail "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

api_call() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local http_code
  local response_file="${TMPDIR:-/tmp}/linode_response_$$.json"
  
  if [[ -n "$data" ]]; then
    http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
      -X "$method" \
      -H "Authorization: Bearer $PAT" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "$url")
  else
    http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
      -H "Authorization: Bearer $PAT" \
      "$url")
  fi
  
  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    cat "$response_file"
    rm -f "$response_file"
    return 0
  else
    log "ERROR: API call failed with HTTP $http_code"
    [[ -f "$response_file" ]] && cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi
}

get_domain_id() {
  local domain="$1"
  local result
  result=$(api_call "GET" "$API_URL/domains" || echo "")
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result" | jq -r ".data[] | select(.domain==\"$domain\") | .id" | head -n1
}

get_record_id() {
  local domain_id="$1" name="$2"
  local result
  result=$(api_call "GET" "$API_URL/domains/$domain_id/records" || echo "")
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result" | jq -r ".data[] | select(.type==\"A\" and .name==\"$name\") | .id" | head -n1
}

get_record_ip() {
  local domain_id="$1" name="$2"
  local result
  result=$(api_call "GET" "$API_URL/domains/$domain_id/records" || echo "")
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result" | jq -r ".data[] | select(.type==\"A\" and .name==\"$name\") | .target" | head -n1
}

get_dns_baseline_ip() {
  # On first run, fetch the current DNS IP from the first configured domain
  # This gives us a baseline to compare against
  local first_entry="${DOMAINS[0]}"
  if [[ -z "$first_entry" ]]; then
    return 1
  fi
  
  local domain hostname
  domain=$(echo "$first_entry" | cut -d',' -f1)
  hostname=$(echo "$first_entry" | cut -d',' -f2)
  
  local domain_id
  domain_id=$(get_domain_id "$domain")
  if [[ -z "$domain_id" ]] || [[ "$domain_id" == "null" ]]; then
    return 1
  fi
  
  local dns_ip
  dns_ip=$(get_record_ip "$domain_id" "$hostname")
  if [[ -z "$dns_ip" ]] || [[ "$dns_ip" == "null" ]]; then
    # Record doesn't exist yet, return empty
    return 1
  fi
  
  echo "$dns_ip"
  return 0
}


# ----------------------------
# Signal handling for graceful shutdown
# ----------------------------
cleanup() {
  log "Shutting down gracefully..."
  exit 0
}

trap cleanup SIGTERM SIGINT

# ----------------------------
# Main update function
# ----------------------------
run_update() {
  # Ensure config directory exists
  mkdir -p "$(dirname "$CONFIG")"
  mkdir -p "$(dirname "$LAST_IP_FILE")"

  # Load config
  if [[ ! -f "$CONFIG" ]]; then
    log "ERROR: Configuration file not found: $CONFIG"
    log "Please run setup.sh to configure domains."
    return 1
  fi

  # shellcheck disable=SC1090
  source "$CONFIG"

  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    log "ERROR: No domains configured in $CONFIG"
    log "Please run setup.sh to configure domains."
    return 1
  fi

  # Get current public IP
  local current_ip
  current_ip=$(get_public_ip)
  if [[ -z "$current_ip" ]]; then
    log "ERROR: Could not determine public IP."
    return 1
  fi

  local last_ip=""
  [[ -f "$LAST_IP_FILE" ]] && last_ip=$(cat "$LAST_IP_FILE")

  # On first run (no lastip file), fetch current DNS IP as baseline
  if [[ -z "$last_ip" ]]; then
    log "First run detected. Fetching current DNS IP as baseline..."
    local dns_baseline
    dns_baseline=$(get_dns_baseline_ip)
    if [[ -n "$dns_baseline" ]] && [[ "$dns_baseline" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      last_ip="$dns_baseline"
      log "Current DNS IP: $last_ip"
      
      # If DNS already matches current IP, just save it and skip update
      if [[ "$current_ip" = "$last_ip" ]]; then
        log "DNS IP matches current public IP ($current_ip). No update needed."
        echo "$current_ip" > "$LAST_IP_FILE"
        return 0
      fi
    else
      log "Could not fetch DNS baseline (record may not exist yet). Proceeding with update."
    fi
  fi

  if [[ "$current_ip" = "$last_ip" ]]; then
    log "IP unchanged ($current_ip). Skipping update."
    return 0
  fi

  log "Public IP changed: ${last_ip:-<none>} → $current_ip"
  echo "$current_ip" > "$LAST_IP_FILE"

  # Update all configured domains
  local success=true
  for entry in "${DOMAINS[@]}"; do
    local domain hostname display_name
    domain=$(echo "$entry" | cut -d',' -f1)
    hostname=$(echo "$entry" | cut -d',' -f2)
    
    # Display name for logging
    if [[ -z "$hostname" ]]; then
      display_name="$domain"
    else
      display_name="$hostname.$domain"
    fi

    log "Updating $display_name"

    local domain_id
    domain_id=$(get_domain_id "$domain")
    if [[ -z "$domain_id" ]] || [[ "$domain_id" == "null" ]]; then
      log "ERROR: Domain $domain not found in Linode."
      success=false
      continue
    fi

    local record_id
    record_id=$(get_record_id "$domain_id" "$hostname")

    if [[ -z "$record_id" ]] || [[ "$record_id" == "null" ]]; then
      log "A record for $display_name not found — creating."

      local create_payload
      create_payload=$(jq -n \
        --arg name "${hostname:-}" \
        --arg ip "$current_ip" \
        '{type:"A", name:$name, target:$ip}')

      if api_call "POST" "$API_URL/domains/$domain_id/records" "$create_payload" >/dev/null; then
        log "Created $display_name → $current_ip"
      else
        log "ERROR: Failed to create record for $display_name"
        success=false
      fi
      continue
    fi

    # Update existing record
    local update_payload
    update_payload=$(jq -n --arg ip "$current_ip" '{target:$ip}')

    if api_call "PUT" "$API_URL/domains/$domain_id/records/$record_id" "$update_payload" >/dev/null; then
      log "Updated $display_name → $current_ip"
    else
      log "ERROR: Failed to update record for $display_name"
      success=false
    fi
  done

  if [[ "$success" == "true" ]]; then
    log "All DNS records processed successfully."
  else
    log "WARNING: Some DNS records failed to update."
    return 1
  fi
}

# ----------------------------
# Main execution
# ----------------------------
if [[ "${CONTINUOUS_MODE}" == "true" ]]; then
  log "Starting continuous mode (checking every ${CHECK_INTERVAL}s)"
  while true; do
    run_update || true
    sleep "$CHECK_INTERVAL"
  done
else
  run_update
fi
