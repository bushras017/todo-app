#!/bin/bash
set -e

echo "Starting monitoring and alerting setup..."

# Install required packages
sudo apt-get update
sudo apt-get install -y prometheus prometheus-node-exporter prometheus-alertmanager

# Create necessary directories
echo "Creating configuration directories..."
sudo mkdir -p /etc/prometheus/rules
sudo mkdir -p /etc/alertmanager/templates
sudo mkdir -p /var/log/prometheus
sudo mkdir -p /var/log/alertmanager

# Copy configurations
echo "Configuring Prometheus and Alertmanager..."
sudo cp /tmp/prometheus.yml /etc/prometheus/
sudo cp /tmp/alerts.yml /etc/prometheus/rules/
sudo cp /tmp/alertmanager.yml /etc/alertmanager/
sudo cp /tmp/email.tmpl /etc/alertmanager/templates/

# Set ownership and permissions
echo "Setting permissions..."
sudo chown -R prometheus:prometheus /etc/prometheus /var/log/prometheus
# For Alertmanager, we'll use the prometheus user since it's already set up
sudo chown -R prometheus:prometheus /etc/alertmanager /var/log/alertmanager

sudo chmod 644 /etc/prometheus/prometheus.yml
sudo chmod 644 /etc/prometheus/rules/alerts.yml
sudo chmod 644 /etc/alertmanager/alertmanager.yml
sudo chmod 644 /etc/alertmanager/templates/email.tmpl

# Configure services
echo "Configuring services..."
sudo tee /etc/default/prometheus << EOF
ARGS="--web.listen-address=0.0.0.0:9090 --storage.tsdb.retention.time=15d --storage.tsdb.path=/var/lib/prometheus/data"
EOF

sudo tee /etc/default/alertmanager << EOF
ARGS="--web.listen-address=0.0.0.0:9093 --storage.path=/var/lib/alertmanager/data --cluster.listen-address=0.0.0.0:9094"
EOF

sudo tee /etc/default/prometheus-node-exporter << EOF
ARGS="--web.listen-address=0.0.0.0:9100"
EOF

# Restart services
echo "Restarting services..."
sudo systemctl daemon-reload

sudo systemctl enable prometheus
sudo systemctl restart prometheus
sudo systemctl enable prometheus-alertmanager
sudo systemctl restart prometheus-alertmanager
sudo systemctl enable prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter

# Verify services
echo "Verifying services..."
services=("prometheus" "prometheus-alertmanager" "prometheus-node-exporter")
for service in "${services[@]}"; do
    if sudo systemctl is-active --quiet "$service"; then
        echo "✓ $service is running"
    else
        echo "✗ $service failed to start"
        sudo systemctl status "$service"
        exit 1
    fi
done

# Validate configurations
echo "Testing configurations..."
if sudo prometheus --config.file=/etc/prometheus/prometheus.yml --check-config; then
    echo "✓ Prometheus configuration is valid"
else
    echo "✗ Prometheus configuration check failed"
    exit 1
fi

if sudo alertmanager --config.file=/etc/alertmanager/alertmanager.yml --check-config; then
    echo "✓ Alertmanager configuration is valid"
else
    echo "✗ Alertmanager configuration check failed"
    exit 1
fi

echo "Setup completed successfully!"
echo "You can access the following URLs:"
echo "- Prometheus UI: http://localhost:9090"
echo "- Alertmanager UI: http://localhost:9093"
echo "- Node Exporter metrics: http://localhost:9100/metrics"