#!/bin/bash
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

# Verify required files
verify_files() {
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
}

# Setup Prometheus
setup_prometheus() {
    log "Setting up Prometheus..."
    
    # Setup directories
    sudo mkdir -p /etc/prometheus/rules /var/lib/prometheus
    sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
    
    # Copy configs
    sudo cp /tmp/prometheus.yml /etc/prometheus/
    sudo cp /tmp/alerts.yml /etc/prometheus/rules/
    sudo cp /tmp/prometheus.service /etc/systemd/system/
    
    # Set permissions
    sudo chmod 644 /etc/prometheus/prometheus.yml
    sudo chmod 644 /etc/prometheus/rules/alerts.yml
    sudo chmod 755 /etc/prometheus/rules
    sudo chmod 644 /etc/systemd/system/prometheus.service
    
    # Validate config
    if ! sudo -u prometheus promtool check config /etc/prometheus/prometheus.yml; then
        log "ERROR: Prometheus config validation failed"
        exit 1
    fi
}

# Setup Alertmanager
setup_alertmanager() {
    log "Setting up Alertmanager..."
    
    # Verify alertmanager binary
    if [ -f "/usr/bin/alertmanager" ]; then
        ALERTMANAGER_BIN="/usr/bin/alertmanager"
    elif [ -f "/usr/bin/prometheus-alertmanager" ]; then
        ALERTMANAGER_BIN="/usr/bin/prometheus-alertmanager"
    else
        log "ERROR: Alertmanager binary not found"
        exit 1
    fi
    
    # Setup directories
    sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
    sudo chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager
    
    # Copy configs
    sudo cp /tmp/alertmanager.yml /etc/alertmanager/
    sudo cp /tmp/alertmanager.service /etc/systemd/system/
    
    # Update service file with correct binary path
    sudo sed -i "s|ExecStart=/usr/bin/alertmanager|ExecStart=${ALERTMANAGER_BIN}|g" /etc/systemd/system/alertmanager.service
    
    # Set permissions
    sudo chmod 644 /etc/alertmanager/alertmanager.yml
    sudo chmod 644 /etc/systemd/system/alertmanager.service
    sudo chmod 755 /var/lib/alertmanager
    
    # Validate config
    if ! sudo -u prometheus $ALERTMANAGER_BIN \
        --config.file=/etc/alertmanager/alertmanager.yml \
        --check-config; then
        log "ERROR: Alertmanager config validation failed"
        exit 1
    fi
}

# Setup Node Exporter
setup_node_exporter() {
    log "Setting up Node Exporter..."
    
    sudo cp /tmp/node-exporter.service /etc/systemd/system/prometheus-node-exporter.service
    sudo chmod 644 /etc/systemd/system/prometheus-node-exporter.service
}

# Start services
start_services() {
    log "Starting services..."
    
    sudo systemctl daemon-reload
    
    declare -A services=(
        ["prometheus"]="9090"
        ["alertmanager"]="9093"
        ["prometheus-node-exporter"]="9100"
    )
    
    for service in "${!services[@]}"; do
        log "Starting $service..."
        sudo systemctl enable $service
        sudo systemctl restart $service
        sleep 3
        
        if ! sudo systemctl is-active --quiet $service; then
            log "ERROR: $service failed to start"
            sudo systemctl status $service --no-pager
            sudo journalctl -u $service --no-pager -n 50
            
            # Additional debugging for alertmanager
            if [ "$service" == "alertmanager" ]; then
                log "Alertmanager troubleshooting info:"
                ls -l $ALERTMANAGER_BIN 2>/dev/null
                ls -l /etc/alertmanager/
                ls -l /var/lib/alertmanager/
                sudo -u prometheus $ALERTMANAGER_BIN --version
            fi
            
            exit 1
        fi
        
        port="${services[$service]}"
        local check_url="http://0.0.0.0:$port"
        [ "$service" == "prometheus" -o "$service" == "alertmanager" ] && check_url="${check_url}/-/healthy"
        [ "$service" == "prometheus-node-exporter" ] && check_url="${check_url}/metrics"
        
        verify_endpoint "$check_url" "$service" || {
            log "ERROR: $service not responding on port $port"
            exit 1
        }
    done
}

# Main setup function
setup_monitoring() {
    local WEB_IP=$1
    [ -z "$WEB_IP" ] && { log "ERROR: WEB_IP is required"; exit 1; }
    
    log "Starting monitoring setup with WEB_IP: $WEB_IP"
    
    # Verify files
    verify_files
    
    # Install packages
    log "Installing packages..."
    sudo apt-get update
    sudo apt-get install -y prometheus prometheus-alertmanager prometheus-node-exporter
    
    # Stop services
    log "Stopping services..."
    sudo systemctl stop prometheus alertmanager prometheus-node-exporter || true
    
    # Setup components
    setup_prometheus
    setup_alertmanager
    setup_node_exporter
    
    # Start services
    start_services
    
    # Verify external access
    log "Verifying external access..."
    services=(
        "Prometheus:9090:-/healthy"
        "Alertmanager:9093:-/healthy"
        "Node Exporter:9100:metrics"
    )

    for service in "${services[@]}"; do
        IFS=':' read -r name port path <<< "$service"
        verify_endpoint "http://$WEB_IP:$port/$path" "$name (external)" || {
            log "ERROR: $name not externally accessible"
            exit 1
        }
    done

    # Show service status summary
    log "Service status summary:"
    for service in prometheus alertmanager prometheus-node-exporter; do
        echo "=== $service status ==="
        sudo systemctl status $service --no-pager | head -n 3
    done

    log "All services are running and verified!"
}

# Main execution
if [ -z "$1" ]; then
    log "Usage: $0 <web-ip>"
    exit 1
fi

setup_monitoring "$1"