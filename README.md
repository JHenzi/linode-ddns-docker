# Linode Dynamic DNS Updater

A lightweight Docker service that automatically updates Linode DNS A records when your public IP address changes.

## Features

- ✅ Automatic IP detection and DNS updates
- ✅ Lightweight Alpine-based Docker image
- ✅ Continuous monitoring mode
- ✅ Proper error handling and logging
- ✅ Graceful shutdown handling
- ✅ Health checks

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
   - Fetch your Linode domains
   - Prompt you to configure domain/hostname pairs
   - Validate domains exist in your Linode account
   - Build the Docker image
   - Optionally start the container

That's it! The service will automatically update your DNS records when your IP changes.

## Configuration

### Environment Variables

- `PAT` (required): Your Linode API Personal Access Token
- `CONFIG_DIR` (default: `/data`): Directory for config and state files
- `CHECK_INTERVAL` (default: `300`): Seconds between IP checks in continuous mode
- `CONTINUOUS_MODE` (default: `true`): Run continuously vs. one-time execution

### Config File Format

The config file (`linode-ddns.conf`) should contain:
```bash
DOMAINS=(
  "domain.com,hostname1"
  "domain.com,hostname2"
  "another.com,subdomain"
)
```

Format: `"DOMAIN,HOSTNAME"` where:
- `DOMAIN` is your Linode domain (e.g., `example.com`)
- `HOSTNAME` is the subdomain (e.g., `www` for `www.example.com`)

## Usage

### Docker Compose (Recommended)

```bash
# Start service
docker-compose up -d

# View logs
docker-compose logs -f

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

## Files

- `setup.sh` - Interactive setup script (run this first!)
- `update.sh` - Main update script (runs inside container)
- `Dockerfile` - Lightweight Alpine-based image
- `docker-compose.yml` - Docker Compose configuration
- `data/linode-ddns.conf` - Domain configuration (created by setup.sh)
- `data/linode-ddns.lastip` - Last known IP address (auto-created)

## How It Works

1. Script checks your public IP using multiple reliable sources
2. Compares with last known IP (stored in `lastip` file)
3. If IP changed, updates all configured DNS A records via Linode API
4. In continuous mode, repeats every `CHECK_INTERVAL` seconds

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

### Check logs
```bash
docker-compose logs -f linode-ddns
```

### Verify configuration
```bash
cat data/linode-ddns.conf
```

### Reconfigure
```bash
# Run setup again to add/change domains
./setup.sh
```

### Test manually
```bash
docker run --rm \
  -e PAT="your_token" \
  -v $(pwd)/data:/data \
  linode-ddns \
  /usr/local/bin/update.sh
```

## Security Notes

- Never commit `.env` files or API tokens to version control
- The `PAT` environment variable contains sensitive credentials
- Consider using Docker secrets or a secrets manager in production

