#!/bin/bash
set -e

echo "Starting monitoring and alerting setup..."

# Function to check and kill processes using specific ports
cleanup_port() {
    local port=$1
    local service_name=$2
    
    echo "Checking port $port used by $service_name..."
    if sudo lsof -i ":$port" >/dev/null 2>&1; then
        echo "Port $port is in use. Terminating existing processes..."
        sudo lsof -i ":$port" -t | xargs -r sudo kill -9
        sleep 2
        if sudo lsof -i ":$port" >/dev/null 2>&1; then
            echo "ERROR: Failed to free port $port"
            exit 1
        fi
        echo "Successfully freed port $port"
    else
        echo "Port $port is available"
    fi
}

# Enhanced function to safely stop and clean up a service
cleanup_service() {
    local service_name=$1
    echo "Cleaning up $service_name..."
    
    # Check if service is active before attempting to stop
    if sudo systemctl is-active --quiet $service_name; then
        echo "$service_name is running, stopping it..."
        sudo systemctl stop $service_name
        sleep 2
    else
        echo "$service_name is not running"
    fi
    
    # Check for any remaining processes and kill them
    local process_name=${service_name#prometheus-}
    if pgrep -f $process_name > /dev/null; then
        echo "Found remaining $process_name processes, terminating..."
        sudo pkill -f $process_name || true
        sleep 2
        
        if pgrep -f $process_name > /dev/null; then
            sudo pkill -9 -f $process_name || true
        fi
    fi
    
    # Ensure the service is not running
    if sudo systemctl is-active --quiet $service_name; then
        echo "ERROR: Unable to stop $service_name"
        exit 1
    fi
}

# Install required packages
sudo apt-get update
sudo apt-get install -y prometheus prometheus-node-exporter prometheus-alertmanager

# Clean up ports first
echo "Cleaning up ports..."
cleanup_port 9090 "Prometheus"
cleanup_port 9093 "Alertmanager"
cleanup_port 9094 "Alertmanager cluster"
cleanup_port 9100 "Node Exporter"

# Clean up existing services
echo "Cleaning up existing services..."
cleanup_service prometheus
cleanup_service prometheus-alertmanager
cleanup_service prometheus-node-exporter

# Create necessary directories
echo "Creating configuration directories..."
sudo mkdir -p /etc/prometheus/rules
sudo mkdir -p /etc/alertmanager/templates
sudo mkdir -p /var/log/prometheus
sudo mkdir -p /var/log/alertmanager
sudo mkdir -p /var/lib/alertmanager/data

# Clean up any existing data directories
echo "Cleaning up existing data directories..."
sudo rm -rf /var/lib/alertmanager/data/*

# Copy configurations
echo "Configuring Prometheus and Alertmanager..."
sudo cp /tmp/prometheus.yml /etc/prometheus/
sudo cp /tmp/alerts.yml /etc/prometheus/rules/
sudo cp /tmp/alertmanager.yml /etc/alertmanager/
sudo cp /tmp/email.tmpl /etc/alertmanager/templates/

# Set ownership and permissions
echo "Setting permissions..."
sudo chown -R prometheus:prometheus /etc/prometheus /var/log/prometheus
sudo chown -R prometheus:prometheus /etc/alertmanager /var/log/alertmanager /var/lib/alertmanager

sudo chmod 644 /etc/prometheus/prometheus.yml
sudo chmod 644 /etc/prometheus/rules/alerts.yml
sudo chmod 644 /etc/alertmanager/alertmanager.yml
sudo chmod 644 /etc/alertmanager/templates/email.tmpl
sudo chmod -R 755 /var/lib/alertmanager

# Remove any existing override configurations
echo "Removing existing service overrides..."
sudo rm -rf /etc/systemd/system/prometheus-alertmanager.service.d

# Create new service configuration
echo "Configuring Alertmanager service..."
sudo tee /etc/systemd/system/prometheus-alertmanager.service << EOF
[Unit]
Description=Prometheus Alertmanager
Documentation=https://prometheus.io/docs/alerting/alertmanager/
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
WorkingDirectory=/var/lib/alertmanager
ExecStart=/usr/bin/prometheus-alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager/data \
    --web.listen-address=0.0.0.0:9093 \
    --cluster.listen-address=0.0.0.0:9094 \
    --log.level=debug

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Configure Prometheus service
echo "Configuring Prometheus service..."
sudo tee /etc/default/prometheus << EOF
ARGS="--web.listen-address=0.0.0.0:9090 --storage.tsdb.retention.time=15d --storage.tsdb.path=/var/lib/prometheus/data"
EOF

# Configure Node Exporter
echo "Configuring Node Exporter..."
sudo tee /etc/default/prometheus-node-exporter << EOF
ARGS="--web.listen-address=0.0.0.0:9100"
EOF

# Reload systemd and start services
echo "Starting services..."
sudo systemctl daemon-reload

# Enhanced function to start and verify a service
start_service() {
    local service_name=$1
    local port=$2
    echo "Starting $service_name..."
    
    # Double-check port availability before starting
    cleanup_port $port $service_name
    
    # Ensure service is stopped and disabled before starting
    sudo systemctl disable $service_name || true
    sudo systemctl stop $service_name || true
    sleep 2
    
    # Enable and start the service
    sudo systemctl enable $service_name
    sudo systemctl start $service_name
    
    # Wait for service to start and verify
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if sudo systemctl is-active --quiet $service_name; then
            echo "✓ $service_name started successfully"
            return 0
        fi
        echo "Attempt $attempt of $max_attempts: Waiting for $service_name to start..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    echo "✗ $service_name failed to start. Service status:"
    sudo systemctl status $service_name --no-pager
    sudo journalctl -u $service_name --no-pager -n 50
    exit 1
}

# Start services in sequence with port verification
start_service prometheus 9090
start_service prometheus-alertmanager 9093
start_service prometheus-node-exporter 9100

echo "Setup completed successfully!"
echo "Services are available at:"
echo "- Prometheus: http://localhost:9090"
echo "- Alertmanager: http://localhost:9093"
echo "- Node Exporter: http://localhost:9100/metrics"