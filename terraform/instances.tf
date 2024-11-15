# terraform/instances.tf

resource "google_compute_instance" "db_server" {
  name         = "db-server"
  machine_type = "e2-medium"
  tags         = ["db-server"]
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    enable-oslogin = "TRUE"
    enable-guest-attributes = "TRUE"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      metadata,
      metadata_startup_script,
      attached_disk,
      boot_disk,
      network_interface,
      scheduling,
      service_account,
      shielded_instance_config,
      tags
    ]
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -e

# Install required packages
apt-get update
apt-get install -y postgresql postgresql-contrib prometheus-node-exporter postgres-exporter

# Install Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# Configure PostgreSQL
sudo -u postgres psql -c "CREATE USER django_user WITH PASSWORD '${var.db_password}';"
sudo -u postgres psql -c "CREATE DATABASE django_db OWNER django_user;"

# Configure PostgreSQL networking
echo "host    django_db    django_user    10.0.0.0/24    md5" >> /etc/postgresql/12/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/12/main/postgresql.conf

# Configure exporters
sed -i 's/^ARGS.*/ARGS="--web.listen-address=0.0.0.0:9100"/' /etc/default/prometheus-node-exporter
cat > /etc/default/postgres-exporter <<EOC
DATA_SOURCE_NAME="postgresql://postgres:${var.db_password}@localhost:5432/postgres?sslmode=disable"
ARGS="--web.listen-address=0.0.0.0:9187"
EOC

# Start services
systemctl restart postgresql
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter
systemctl enable postgres-exporter
systemctl start postgres-exporter
EOF

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance" "web_server" {
  name         = "web-server"
  machine_type = "e2-medium"
  tags         = ["web-server", "http-server", "https-server"]
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }
  
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      metadata,
      metadata_startup_script,
      attached_disk,
      boot_disk,
      network_interface,
      scheduling,
      service_account,
      shielded_instance_config,
      tags
    ]
  }

  # Store all configuration in metadata
  metadata = {
    enable-oslogin = "TRUE"
    enable-guest-attributes = "TRUE"
    db_private_ip       = google_compute_instance.db_server.network_interface[0].network_ip
    email_recipients    = join(",", var.alert_email_recipients)
    notification_email  = var.notification_email
    email_app_password = var.notification_email_password
    db_password        = var.db_password
    startup-script-vars = <<EOF
INSTANCE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
DB_PRIVATE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/db_private_ip)
EMAIL_RECIPIENTS=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_recipients)
NOTIFICATION_EMAIL=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/notification_email)
EMAIL_APP_PASSWORD=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_app_password)
DB_PASSWORD=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/db_password)
EOF
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -e

# Get the IPs dynamically
INSTANCE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
DB_PRIVATE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/db_private_ip)
EMAIL_RECIPIENTS=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_recipients)
NOTIFICATION_EMAIL=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/notification_email)
EMAIL_APP_PASSWORD=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_app_password)

# Install required packages
apt-get update
apt-get install -y python3-pip python3-venv prometheus prometheus-node-exporter prometheus-alertmanager openssh-server

# Ensure SSH service is running and enabled
systemctl enable ssh
systemctl start ssh

# Install Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# Setup directories
mkdir -p /etc/prometheus/rules
mkdir -p /var/log/prometheus
mkdir -p /opt/django-app

# Configure Prometheus to listen on all interfaces
cat > /etc/default/prometheus << EOC
ARGS="--web.listen-address=0.0.0.0:9090"
EOC

# Configure Prometheus
cat > /etc/prometheus/prometheus.yml << EOC
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules/*.yml"

scrape_configs:
  - job_name: 'django'
    metrics_path: '/prometheus/metrics'
    scheme: http
    static_configs:
      - targets: ['$EXTERNAL_IP:8000']
        labels:
          instance: 'web-server'
          application: 'django'

  - job_name: 'node'
    static_configs:
      - targets: ['$EXTERNAL_IP:9100']
        labels:
          instance: 'web-server'
      - targets: ['$DB_PRIVATE_IP:9100']
        labels:
          instance: 'db-server'

  - job_name: 'postgres'
    static_configs:
      - targets: ['$DB_PRIVATE_IP:9187']
        labels:
          instance: 'db-server'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['$EXTERNAL_IP:9093']
EOC

# Configure alert rules
cat > /etc/prometheus/rules/alerts.yml << EOC
groups:
- name: django_alerts
  rules:
  - alert: HighCPUUsage
    expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: High CPU Usage
      description: "CPU usage is above 80% on {{ \$labels.instance }}"

  - alert: DiskSpaceLow
    expr: (node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes * 100 > 85
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: Low Disk Space
      description: "Disk usage is above 85% on {{ \$labels.instance }}"

  - alert: PostgresDown
    expr: pg_up == 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: PostgreSQL Server Down
      description: "PostgreSQL server is down on {{ \$labels.instance }}"

  - alert: HighFailedLogins
    expr: rate(django_http_responses_total{status="401"}[5m]) > 1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: High Failed Login Rate
      description: "Unusually high rate of failed login attempts"
EOC

# Configure Alertmanager
cat > /etc/default/alertmanager << EOC
ARGS="--web.listen-address=0.0.0.0:9093"
EOC

# Configure Alertmanager
cat > /etc/alertmanager/alertmanager.yml << EOC
global:
  resolve_timeout: 5m
  smtp_from: '$NOTIFICATION_EMAIL'
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_auth_username: '$NOTIFICATION_EMAIL'
  smtp_auth_password: '$EMAIL_APP_PASSWORD'
  smtp_require_tls: true

route:
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 1h
  receiver: 'email-notifications'

receivers:
  - name: 'email-notifications'
    email_configs:
      - to: '$EMAIL_RECIPIENTS'
        send_resolved: true
EOC

# Configure node_exporter
cat > /etc/default/prometheus-node-exporter << EOC
ARGS="--web.listen-address=0.0.0.0:9100"
EOC

# Start services
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter
systemctl enable prometheus-alertmanager
systemctl start prometheus-alertmanager
EOF

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform", "compute-ro", "storage-ro"]
  }

  depends_on = [
    google_compute_instance.db_server
  ]
}