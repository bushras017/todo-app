#!/bin/bash
# deployment/scripts/setup-monitoring.sh
set -e

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Verify endpoint function
verify_endpoint() {
    local url=$1
    local name=$2
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        if curl -s -f "$url" > /dev/null; then
            log "✅ $name is responding"
            return 0
        fi
        retry=$((retry + 1))
        log "Retry $retry/$max_retries for $name..."
        sleep 2
    done
    
    log "❌ $name failed to respond after $max_retries attempts"
    return 1
}

# Setup monitoring services
setup_monitoring() {
    local WEB_IP=$1
    [ -z "$WEB_IP" ] && { log "ERROR: WEB_IP is required"; exit 1; }
    
    log "Starting monitoring setup with WEB_IP: $WEB_IP"

    # Verify all required files
    local required_files=(
        "/tmp/prometheus.yml"
        "/tmp/alerts.yml"
        "/tmp/alertmanager.yml"
        "/tmp/prometheus.service"
        "/tmp/alertmanager.service"
        "/tmp/node-exporter.service"
    )

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log "ERROR: Required file $file not found"
            exit 1
        fi
    done

    # Install packages
    log "Installing packages..."
    sudo apt-get update
    sudo apt-get install -y prometheus prometheus-alertmanager prometheus-node-exporter

    # Stop services
    log "Stopping services..."
    sudo systemctl stop prometheus prometheus-alertmanager prometheus-node-exporter || true

    # Setup directories
    log "Setting up directories..."
    sudo mkdir -p /etc/prometheus/rules /etc/alertmanager
    sudo mkdir -p /var/lib/prometheus /var/lib/alertmanager

    # Copy files
    log "Copying configuration files..."
    sudo cp /tmp/prometheus.yml /etc/prometheus/
    sudo cp /tmp/alerts.yml /etc/prometheus/rules/
    sudo cp /tmp/alertmanager.yml /etc/alertmanager/
    sudo cp /tmp/prometheus.service /etc/systemd/system/
    sudo cp /tmp/alertmanager.service /etc/systemd/system/
    sudo cp /tmp/node-exporter.service /etc/systemd/system/prometheus-node-exporter.service

    # Set permissions
    log "Setting permissions..."
    sudo chown -R prometheus:prometheus /etc/prometheus /etc/alertmanager /var/lib/prometheus /var/lib/alertmanager
    sudo chmod 644 /etc/prometheus/prometheus.yml
    sudo chmod 644 /etc/prometheus/rules/alerts.yml
    sudo chmod 644 /etc/alertmanager/alertmanager.yml
    sudo chmod 755 /etc/prometheus/rules
    sudo chmod 644 /etc/systemd/system/{prometheus,alertmanager}.service
    sudo chmod 644 /etc/systemd/system/prometheus-node-exporter.service

    # Reload and restart services
    log "Starting services..."
    sudo systemctl daemon-reload
    
    declare -A service_ports=(
        ["prometheus"]="9090"
        ["alertmanager"]="9093"
        ["prometheus-node-exporter"]="9100"
    )

    for service in "${!service_ports[@]}"; do
        log "Starting $service..."
        sudo systemctl enable $service
        sudo systemctl restart $service
        sleep 3

        if ! sudo systemctl is-active --quiet $service; then
            log "ERROR: $service failed to start"
            sudo systemctl status $service --no-pager
            sudo journalctl -u $service --no-pager -n 50
            exit 1
        fi

        port="${service_ports[$service]}"
        verify_endpoint "http://0.0.0.0:$port/-/healthy" "$service" || {
            log "ERROR: $service not responding on port $port"
            exit 1
        }
    done

    log "All services started successfully"

    # Verify external access
    log "Verifying external access..."
    services=(
        "Prometheus:9090:-/healthy"
        "Alertmanager:9093:-/healthy"
        "Node Exporter:9100:metrics"
    )

    for service in "${services[@]}"; do
        IFS=':' read -r name port path <<< "$service"
        verify_endpoint "http://$WEB_IP:$port/$path" "$name" || {
            log "ERROR: $name not externally accessible"
            exit 1
        }
    done

    log "External access verified successfully"
}

# Main execution
if [ -z "$1" ]; then
    log "Usage: $0 <web-ip>"
    exit 1
fi

setup_monitoring "$1"
log "Monitoring setup completed successfully"