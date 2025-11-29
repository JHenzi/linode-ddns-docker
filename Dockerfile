FROM alpine:latest

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    tzdata \
    procps

# Create non-root user (UID 1000, GID 1000 - common default)
RUN addgroup -g 1000 ddns && \
    adduser -D -u 1000 -G ddns ddns

# Create data directory with proper ownership
RUN mkdir -p /data && \
    chown -R ddns:ddns /data

# Copy script
COPY update.sh /usr/local/bin/update.sh
RUN chmod +x /usr/local/bin/update.sh

# Set working directory
WORKDIR /app

# Switch to non-root user
USER ddns

# Default command (runs in continuous mode)
CMD ["/usr/local/bin/update.sh", "--continuous"]

