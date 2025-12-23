# Linode Dynamic DNS Updater

**Want a Docker container to update your Linode Dynamic DNS entries?** This lightweight service automatically keeps your Linode DNS A records in sync with your changing public IP address. Perfect for home servers, VPNs, and any service with a dynamic IP that needs reliable Linode Dynamic DNS updates.

A simple, automated solution for managing Linode Dynamic DNS records when your IP address changes. No manual DNS updates required - this Docker container handles everything automatically.

## Features

- ✅ **Automatic IP Detection** - Monitors your public IP using multiple reliable sources
- ✅ **Auto-Discovery** - Automatically discover and configure Linode Dynamic DNS records matching your current IP
- ✅ **Smart Baseline** - On first run, fetches current DNS IP to avoid unnecessary updates
- ✅ **Root Domain Support** - Update root domains (example.com) or subdomains (www.example.com)
- ✅ **Lightweight** - Minimal Alpine-based Docker image (~15MB)
- ✅ **Non-Root Container** - Runs securely as non-root user (UID 1000)
- ✅ **Continuous Monitoring** - Configurable check interval (default: 5 minutes)
- ✅ **Error Handling** - Proper logging, retries, and graceful error recovery
- ✅ **Health Checks** - Built-in Docker healthcheck monitoring
- ✅ **Easy Setup** - Interactive setup script with domain validation

## Quick Start

1. **Set your Linode API token:**
   ```bash
   # Option 1: Environment variable
   export PAT="your_linode_api_token_here"
   
   # Option 2: Create .env file
   echo 'PAT="your_linode_api_token_here"' > .env
   ```

2. **Run the setup script:**
   ```bash
   ./setup.sh
   ```
   
   The setup script will:
   - Fetch and display your Linode domains
   - Prompt you to configure domain/hostname pairs
   - Validate domains exist in your Linode account
   - Build the Docker image
   - Optionally start the container

   **Or auto-discover domains matching your current IP:**
   ```bash
   ./setup.sh --discover
   ```
   This automatically finds all Linode Dynamic DNS A records pointing to your current public IP and updates the config file.

3. **That's it!** The service automatically updates your Linode Dynamic DNS records when your IP changes.

## Configuration

### Environment Variables

- `PAT` (required): Your Linode API Personal Access Token
- `CONFIG_DIR` (default: `/data`): Directory for config and state files
- `CHECK_INTERVAL` (default: `300`): Seconds between IP checks in continuous mode (must be positive integer)
- `CONTINUOUS_MODE` (default: `true`): Run continuously vs. one-time execution

### Config File Format

The config file (`data/linode-ddns.conf`) is created by the setup script or auto-discovered with `./setup.sh --discover`:

```bash
DOMAINS=(
  "example.com,"           # Root domain (example.com)
  "example.com,www"        # Subdomain (www.example.com)
  "another.com,api"        # Subdomain (api.another.com)
)
```

**Format:** `"DOMAIN,HOSTNAME"` where:
- `DOMAIN` is your Linode domain (e.g., `example.com`)
- `HOSTNAME` is the subdomain part (e.g., `www` for `www.example.com`)
- **Empty HOSTNAME** (trailing comma) means root domain (e.g., `"example.com,"` for `example.com`)

**Manual Editing:** You can also manually edit `data/linode-ddns.conf` to add or remove Linode Dynamic DNS entries. The container will pick up changes on the next check cycle (or restart the container to apply immediately).

## Usage

### Docker Compose (Recommended)

```bash
# Start service
docker-compose up -d

# View logs
docker-compose logs -f linode-ddns

# Stop service
docker-compose down
```

### Manual Docker Run

```bash
docker run -d \
  --name linode-ddns \
  --restart unless-stopped \
  -e PAT="your_token" \
  -v $(pwd)/data:/data \
  linode-ddns
```

### One-time Execution

```bash
# Run once (not in continuous mode)
docker run --rm \
  -e PAT="your_token" \
  -v $(pwd)/data:/data \
  linode-ddns \
  /usr/local/bin/update.sh
```

## How It Works

The Linode Dynamic DNS updater works by continuously monitoring your public IP address and automatically updating your Linode DNS A records when changes are detected.

1. **First Run:**
   - Fetches current DNS IP from Linode API as baseline
   - If DNS already matches current public IP → skips update
   - If DNS differs → updates all configured Linode Dynamic DNS records

2. **Subsequent Runs:**
   - Compares current public IP with last known IP (from `lastip` file)
   - If unchanged → skips update
   - If changed → updates all configured Linode Dynamic DNS A records via Linode API

3. **Continuous Mode:**
   - Repeats check every `CHECK_INTERVAL` seconds
   - Handles errors gracefully and continues running
   - Ensures your Linode Dynamic DNS stays in sync with IP changes

## Files

- `setup.sh` - Interactive setup script (run this first!)
- `update.sh` - Main update script (runs inside container)
- `Dockerfile` - Lightweight Alpine-based image
- `docker-compose.yml` - Docker Compose configuration
- `data/linode-ddns.conf` - Domain configuration (created by setup.sh)
- `data/linode-ddns.lastip` - Last known IP address (auto-created)

## Troubleshooting

### Permission Issues

If you get "Permission denied" errors when running `setup.sh`:

```bash
# Fix data directory permissions (container runs as UID 1000)
sudo chown -R 1000:1000 data/

# Or if your user is UID 1000:
chown -R 1000:1000 data/

# Alternative: Make directory group-writable
chmod -R 775 data/
```

### Check Container Status

```bash
# View logs
docker-compose logs -f linode-ddns

# Check if running as non-root
docker exec linode-ddns id
# Should show: uid=1000(ddns) gid=1000(ddns)

# Check health status
docker ps --filter "name=linode-ddns"
```

### Verify Configuration

```bash
# View config
cat data/linode-ddns.conf

# View last known IP
cat data/linode-ddns.lastip
```

### Reconfigure

```bash
# Run setup again to add/change domains manually
./setup.sh

# Or auto-discover domains matching your current IP
./setup.sh --discover
```

The `--discover` option is perfect for quickly syncing your Linode Dynamic DNS configuration with existing A records that point to your current IP address. It scans all your Linode domains and finds matching A records automatically.

### Test Manually

```bash
# Test update script directly
docker run --rm \
  -e PAT="your_token" \
  -v $(pwd)/data:/data \
  linode-ddns \
  /usr/local/bin/update.sh
```

## Security Notes

- ✅ Container runs as **non-root user** (UID 1000)
- ✅ Never commit `.env` files or API tokens to version control
- ✅ The `PAT` environment variable contains sensitive credentials
- ✅ Consider using Docker secrets or a secrets manager in production
- ✅ API tokens are only used for Linode DNS API calls

## Use Cases

This Linode Dynamic DNS updater is perfect for:

- **Home Servers** - Keep your home server accessible via domain name even with dynamic IP
- **VPN Services** - Automatically update DNS for VPN endpoints
- **Remote Access** - Maintain reliable access to services behind dynamic IPs
- **Self-Hosted Services** - Keep your self-hosted applications accessible via Linode Dynamic DNS
- **Development/Testing** - Quickly sync DNS for development environments

## Requirements

- Docker and Docker Compose (or just Docker)
- Linode account with API Personal Access Token
- Domains managed in Linode DNS Manager
- IPv4 public IP address (IPv6 not currently supported)

## License

This project is provided as-is for personal use and is released under the GNU GPL.

It is **not affiliated with The Henzi Foundation/The Frankie Fund**, a charitable organization dedicated to providing financial support to families facing the unexpected loss of a child.

If you are looking for more information on the foundation or would like to support its mission of covering funeral and final expenses for children, please visit: [https://henzi.org](https://henzi.org)
