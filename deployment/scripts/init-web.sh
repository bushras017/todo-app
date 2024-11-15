# deployment/scripts/init-web.sh
#!/bin/bash
set -e

# Get instance IPs
INSTANCE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

# Install required packages
apt-get update
apt-get install -y python3-pip python3-venv prometheus prometheus-node-exporter prometheus-alertmanager

# Install Google Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# Setup directories
mkdir -p /etc/prometheus/rules
mkdir -p /var/log/prometheus
mkdir -p /opt/django-app

# Configure Prometheus
cat > /etc/default/prometheus << EOF
ARGS="--web.listen-address=0.0.0.0:9090"
EOF

# Setup Prometheus config
cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules/*.yml"

scrape_configs:
  - job_name: 'django'
    static_configs:
      - targets: ['${EXTERNAL_IP}:8000']
        labels:
          instance: 'web-server'

  - job_name: 'node'
    static_configs:
      - targets: ['${EXTERNAL_IP}:9100']
        labels:
          instance: 'web-server'
      - targets: ['${DB_PRIVATE_IP}:9100']
        labels:
          instance: 'db-server'

  - job_name: 'postgres'
    static_configs:
      - targets: ['${DB_PRIVATE_IP}:9187']
        labels:
          instance: 'db-server'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['${EXTERNAL_IP}:9093']
EOF

# Configure alert rules
cat > /etc/prometheus/rules/alerts.yml << EOF
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
EOF

# Configure Alertmanager
cat > /etc/default/alertmanager << EOF
ARGS="--web.listen-address=0.0.0.0:9093"
EOF

cat > /etc/alertmanager/alertmanager.yml << EOF
global:
  resolve_timeout: 5m
  smtp_from: '${NOTIFICATION_EMAIL}'
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_auth_username: '${NOTIFICATION_EMAIL}'
  smtp_auth_password: '${EMAIL_APP_PASSWORD}'
  smtp_require_tls: true

route:
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 1h
  receiver: 'email-notifications'
  routes:
    - match:
        severity: critical
      group_wait: 10s
      repeat_interval: 30m
      receiver: 'email-notifications'

receivers:
  - name: 'email-notifications'
    email_configs:
      - to: '${EMAIL_RECIPIENTS}'
        send_resolved: true
EOF

# Configure node_exporter
cat > /etc/default/prometheus-node-exporter << EOF
ARGS="--web.listen-address=0.0.0.0:9100"
EOF

# Configure Cloud Ops Agent
cat > /etc/google-cloud-ops-agent/config.yaml << EOF
logging:
  receivers:
    django_app:
      type: files
      include_paths:
        - /var/log/django.log
  service:
    pipelines:
      django:
        receivers: [django_app]
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
    prometheus:
      type: prometheus
      collection_interval: 30s
      endpoints:
        - http://${INSTANCE_IP}:9090/metrics
        - http://${INSTANCE_IP}:9100/metrics  # Node Exporter metrics
  service:
    pipelines:
      default:
        receivers: [hostmetrics, prometheus]
EOF

# Start services
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter
systemctl enable prometheus-alertmanager
systemctl start prometheus-alertmanager
systemctl restart google-cloud-ops-agent