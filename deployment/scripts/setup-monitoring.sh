#!/bin/bash
set -e

echo "Setting up monitoring..."

# Install packages
sudo apt-get update
sudo apt-get install -y prometheus prometheus-node-exporter

# Copy configs
sudo cp /tmp/prometheus.yml /etc/prometheus/
sudo mkdir -p /etc/prometheus/rules
sudo cp /tmp/alerts.yml /etc/prometheus/rules/

# Set permissions
sudo chown -R prometheus:prometheus /etc/prometheus
sudo chmod 644 /etc/prometheus/prometheus.yml
sudo chmod 644 /etc/prometheus/rules/alerts.yml

# Restart services
sudo systemctl restart prometheus
sudo systemctl restart prometheus-node-exporter

echo "Setup complete! Check http://localhost:9090"