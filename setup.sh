#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Defaults
# ----------------------------
CONFIG_DIR="${CONFIG_DIR:-./data}"
CONFIG_FILE="$CONFIG_DIR/linode-ddns.conf"
API_URL="https://api.linode.com/v4"
DOCKER_IMAGE_NAME="${DOCKER_IMAGE_NAME:-linode-ddns}"

# ----------------------------
# Load PAT from .env or environment
# ----------------------------
if [[ -f ".env" ]]; then
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
prompt() {
  local msg="$1"
  read -r -p "$msg: " val
  echo "$val"
}

api_call() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local http_code
  
  if [[ -n "$data" ]]; then
    http_code=$(curl -s -w "%{http_code}" -o /tmp/linode_response.json \
      -X "$method" \
      -H "Authorization: Bearer $PAT" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "$url")
  else
    http_code=$(curl -s -w "%{http_code}" -o /tmp/linode_response.json \
      -H "Authorization: Bearer $PAT" \
      "$url")
  fi
  
  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    cat /tmp/linode_response.json
    return 0
  else
    echo "ERROR: API call failed with HTTP $http_code" >&2
    [[ -f /tmp/linode_response.json ]] && cat /tmp/linode_response.json >&2
    return 1
  fi
}

list_domains() {
  local result
  result=$(api_call "GET" "$API_URL/domains" || echo "")
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result" | jq -r '.data[] | "\(.domain) (ID: \(.id))"'
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

validate_domain() {
  local domain="$1"
  local domain_id
  domain_id=$(get_domain_id "$domain")
  if [[ -z "$domain_id" ]] || [[ "$domain_id" == "null" ]]; then
    return 1
  fi
  echo "$domain_id"
  return 0
}

# ----------------------------
# Setup configuration
# ----------------------------
setup_config() {
  echo "=== Linode Dynamic DNS Setup ==="
  echo ""
  echo "Your PAT is loaded from environment or .env."
  echo ""

  # Show available domains
  echo "Fetching your Linode domains..."
  if ! list_domains; then
    echo "ERROR: Failed to fetch domains from Linode API."
    exit 1
  fi
  echo ""

  echo "Enter domain/hostname pairs."
  echo "For root domain (e.g. example.com), leave hostname empty."
  echo "For subdomain (e.g. www.example.com), enter the subdomain part (e.g. www)."
  echo "Leave domain empty when finished."
  echo ""

  DOMAINS=()

  while true; do
    DOMAIN=$(prompt "Domain (e.g. example.com)")
    [[ -z "$DOMAIN" ]] && break

    # Validate domain exists in Linode
    echo "Validating domain..."
    DOMAIN_ID=$(validate_domain "$DOMAIN")
    if [[ -z "$DOMAIN_ID" ]]; then
      echo "ERROR: Domain '$DOMAIN' not found in your Linode account."
      echo "Please check the domain name and try again."
      continue
    fi
    echo "✓ Domain found (ID: $DOMAIN_ID)"

    HOSTNAME=$(prompt "Hostname (leave empty for root domain, or enter subdomain like 'www')")
    
    # Empty hostname is valid for root domain records
    if [[ -z "$HOSTNAME" ]]; then
      DOMAINS+=("$DOMAIN,")
      echo "✓ Added root domain $DOMAIN"
    else
      DOMAINS+=("$DOMAIN,$HOSTNAME")
      echo "✓ Added $HOSTNAME.$DOMAIN"
    fi
    echo ""
  done

  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo "No domains configured. Exiting."
    exit 1
  fi

  # Create config directory
  mkdir -p "$CONFIG_DIR"
  
  # Fix permissions if directory exists but is not writable
  if [[ -d "$CONFIG_DIR" ]] && [[ ! -w "$CONFIG_DIR" ]]; then
    echo "Fixing permissions on $CONFIG_DIR..."
    if sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIR" 2>/dev/null; then
      echo "✓ Permissions fixed"
    else
      echo "WARNING: Could not fix permissions automatically."
      echo "Please run: sudo chown -R $(id -u):$(id -g) $CONFIG_DIR"
    fi
  fi

  # Save config
  echo "Saving config to $CONFIG_FILE"
  if ! {
    echo "# Linode DDNS Configuration"
    echo "# Format: DOMAIN,HOSTNAME"
    echo "# Empty HOSTNAME means root domain (e.g. \"example.com,\" for example.com)"
    echo "# Non-empty HOSTNAME means subdomain (e.g. \"example.com,www\" for www.example.com)"
    echo "DOMAINS=("
    for entry in "${DOMAINS[@]}"; do
      echo "  \"$entry\""
    done
    echo ")"
  } > "$CONFIG_FILE"; then
    echo "ERROR: Failed to write config file. Permission denied."
    echo "Please fix permissions: sudo chown -R $(id -u):$(id -g) $CONFIG_DIR"
    exit 1
  fi

  echo "✓ Config saved to $CONFIG_FILE"
  echo ""
}

# ----------------------------
# Docker operations
# ----------------------------
fix_data_permissions() {
  # Ensure data directory exists and has correct permissions
  mkdir -p "$CONFIG_DIR"
  
  # Get current user's UID/GID
  local current_uid=$(id -u)
  local current_gid=$(id -g)
  
  # Container runs as UID 1000, so we need to ensure data is accessible
  # Option 1: Make it owned by UID 1000 (if user is 1000, or use sudo)
  # Option 2: Make it world-writable (less secure but works)
  
  if [[ "$current_uid" == "1000" ]]; then
    # User is already UID 1000, just ensure ownership
    chown -R 1000:1000 "$CONFIG_DIR" 2>/dev/null || true
  else
    # Try to set ownership to 1000:1000 (container user)
    if sudo chown -R 1000:1000 "$CONFIG_DIR" 2>/dev/null; then
      echo "✓ Set data directory ownership to UID 1000 (container user)"
    else
      # Fallback: make directory writable by group/others
      chmod -R 775 "$CONFIG_DIR" 2>/dev/null || true
      echo "⚠ Using group-writable permissions (less secure)"
    fi
  fi
}

build_docker() {
  echo "Building Docker image..."
  if docker build -t "$DOCKER_IMAGE_NAME" .; then
    echo "✓ Docker image built successfully"
    return 0
  else
    echo "ERROR: Docker build failed"
    return 1
  fi
}

start_docker() {
  echo "Starting Docker container..."
  
  # Fix permissions before starting
  echo "Ensuring data directory permissions..."
  fix_data_permissions
  
  # Check if container already exists
  if docker ps -a --format '{{.Names}}' | grep -q "^linode-ddns$"; then
    echo "Container 'linode-ddns' already exists."
    read -r -p "Stop and remove existing container? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      docker stop linode-ddns 2>/dev/null || true
      docker rm linode-ddns 2>/dev/null || true
    else
      echo "Keeping existing container. Use 'docker-compose up -d' to start it."
      return 0
    fi
  fi

  # Start with docker-compose if available, otherwise docker run
  if command -v docker-compose &> /dev/null || command -v docker compose &> /dev/null; then
    echo "Using docker-compose..."
    docker-compose up -d 2>/dev/null || docker compose up -d
    echo "✓ Container started with docker-compose"
  else
    echo "Using docker run..."
    docker run -d \
      --name linode-ddns \
      --restart unless-stopped \
      -e PAT="$PAT" \
      -e CONFIG_DIR=/data \
      -e CHECK_INTERVAL=300 \
      -e CONTINUOUS_MODE=true \
      -v "$(pwd)/$CONFIG_DIR:/data" \
      "$DOCKER_IMAGE_NAME"
    echo "✓ Container started"
  fi
}

# ----------------------------
# Main execution
# ----------------------------
main() {
  # Check if config exists
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Configuration file already exists: $CONFIG_FILE"
    read -r -p "Do you want to reconfigure? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "Using existing configuration."
      echo ""
    else
      setup_config
    fi
  else
    setup_config
  fi

  # Verify config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
  fi

  echo "=== Docker Setup ==="
  echo ""

  # Build Docker image
  if ! build_docker; then
    exit 1
  fi

  echo ""
  read -r -p "Start the Docker container now? [Y/n] " response
  if [[ ! "$response" =~ ^[Nn]$ ]]; then
    start_docker
    echo ""
    echo "✓ Setup complete!"
    echo ""
    echo "To view logs: docker logs -f linode-ddns"
    echo "To stop: docker stop linode-ddns"
  else
    echo ""
    echo "Build complete. Start the container with:"
    echo "  docker-compose up -d"
    echo "or"
    echo "  docker run -d --name linode-ddns --restart unless-stopped \\"
    echo "    -e PAT=\"\$PAT\" -v \$(pwd)/$CONFIG_DIR:/data $DOCKER_IMAGE_NAME"
  fi
}

main "$@"

