#!/bin/bash
set -e

# Get instance IPs and metadata
INSTANCE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
DB_PRIVATE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/db_private_ip)
EMAIL_RECIPIENTS=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_recipients)
NOTIFICATION_EMAIL=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/notification_email)
EMAIL_APP_PASSWORD=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/email_app_password)

# Install required packages
apt-get update
apt-get install -y python3-pip python3-venv prometheus prometheus-node-exporter prometheus-alertmanager git nginx supervisor

# Install Google Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# Setup directories
mkdir -p /etc/prometheus/rules
mkdir -p /var/log/prometheus
mkdir -p /var/log/django
mkdir -p /opt/django-app

# Create django user
useradd -r -s /bin/false django

# Clone and setup Django application with proper permissions
git clone https://github.com/bushras017/django-todo.git /opt/django-app
cd /opt/django-app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install gunicorn  # Add gunicorn for production serving

# Set proper ownership
chown -R django:django /opt/django-app
chown -R django:django /var/log/django

# Create supervisor configuration for Django
cat > /etc/supervisor/conf.d/django.conf << EOL
[program:django]
command=/opt/django-app/venv/bin/gunicorn --workers 3 --bind unix:/tmp/django.sock todoApp.wsgi:application
directory=/opt/django-app
user=django
group=django
autostart=true
autorestart=true
stderr_logfile=/var/log/django/gunicorn.err.log
stdout_logfile=/var/log/django/gunicorn.out.log
environment=PATH="/opt/django-app/venv/bin"
EOL

# Configure Nginx
cat > /etc/nginx/sites-available/django << EOL
server {
    listen 8000;
    server_name _;

    access_log /var/log/nginx/django_access.log;
    error_log /var/log/nginx/django_error.log;

    location /static/ {
        alias /opt/django-app/staticfiles/;
    }

    location / {
        proxy_pass http://unix:/tmp/django.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Enable Nginx site
ln -sf /etc/nginx/sites-available/django /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create Django environment file
cat > /opt/django-app/.env << EOL
DEBUG=False
DJANGO_SECRET_KEY='$(openssl rand -hex 32)'
ALLOWED_HOSTS=${EXTERNAL_IP},localhost,127.0.0.1
DB_NAME=django_db
DB_USER=django_user
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_PRIVATE_IP}
DB_PORT=5432
EOL

# Set proper permissions for .env file
chown django:django /opt/django-app/.env
chmod 600 /opt/django-app/.env

# Collect static files
cd /opt/django-app
source venv/bin/activate
python manage.py collectstatic --noinput

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
systemctl enable nginx
systemctl start nginx
systemctl enable supervisor
systemctl start supervisor

# Restart Nginx and Supervisor
systemctl restart nginx
supervisorctl reread
supervisorctl update
supervisorctl restart django

# Restart Cloud Ops Agent
systemctl restart google-cloud-ops-agent

# Set up logrotate for Django logs
cat > /etc/logrotate.d/django << EOL
/var/log/django/*.log {
    daily
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 django django
    sharedscripts
    postrotate
        supervisorctl restart django
    endscript
}
EOL