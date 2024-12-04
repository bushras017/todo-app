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
sudo mkdir -p /var/lib/alertmanager

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

# Configure Alertmanager service override
echo "Configuring Alertmanager service..."
sudo mkdir -p /etc/systemd/system/prometheus-alertmanager.service.d
sudo tee /etc/systemd/system/prometheus-alertmanager.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=:9093
User=prometheus
Group=prometheus
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

# Restart services
echo "Restarting services..."
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl restart prometheus
sudo systemctl enable prometheus-alertmanager
sudo systemctl restart prometheus-alertmanager
sudo systemctl enable prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter

# Verify services with detailed error reporting
echo "Verifying services..."
services=("prometheus" "prometheus-alertmanager" "prometheus-node-exporter")
for service in "${services[@]}"; do
    echo "Checking $service..."
    if sudo systemctl is-active --quiet "$service"; then
        echo "✓ $service is running"
    else
        echo "✗ $service failed to start. Service status:"
        sudo systemctl status "$service" --no-pager
        sudo journalctl -u "$service" --no-pager -n 50
        exit 1
    fi
done

echo "Setup completed successfully!"
echo "Services are available at:"
echo "- Prometheus: http://localhost:9090"
echo "- Alertmanager: http://localhost:9093"
echo "- Node Exporter: http://localhost:9100/metrics"