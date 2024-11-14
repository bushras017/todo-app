# terraform/instances.tf

# Read init scripts from files
data "template_file" "init_web" {
  template = file("${path.module}/../deployment/scripts/init-web.sh")
  
  vars = {
    NOTIFICATION_EMAIL    = var.notification_email
    EMAIL_APP_PASSWORD   = var.notification_email_password
    EMAIL_RECIPIENTS     = join(",", var.alert_email_recipients)
  }
}

data "template_file" "init_db" {
  template = file("${path.module}/../deployment/scripts/init-db.sh")
  
  vars = {
    DB_PASSWORD = var.db_password
  }
}

resource "google_compute_instance" "db_server" {
  name         = "db-server"
  machine_type = "e2-medium"
  tags         = ["db-server"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
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

  metadata_startup_script = data.template_file.init_db.rendered

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance" "web_server" {
  name         = "web-server"
  machine_type = "e2-medium"
  tags         = ["web-server"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
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

  metadata = {
    db_private_ip       = google_compute_instance.db_server.network_interface[0].network_ip
    email_recipients    = join(",", var.alert_email_recipients)
    notification_email  = var.notification_email
    email_app_password = var.notification_email_password
  }

  metadata_startup_script = <<EOF
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
sudo apt-get update
sudo apt-get install -y python3-pip python3-venv prometheus prometheus-node-exporter prometheus-alertmanager git nginx supervisor

# Install Google Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install

# Setup directories
sudo mkdir -p /etc/prometheus/rules
sudo mkdir -p /var/log/prometheus
sudo mkdir -p /var/log/django
sudo mkdir -p /opt/django-app

# Create django user
sudo useradd -r -s /bin/false django

# Clone and setup Django application with proper permissions
sudo git clone https://github.com/bushras017/django-todo.git /opt/django-app
cd /opt/django-app
sudo python3 -m venv venv
source venv/bin/activate
sudo pip install -r requirements.txt
sudo pip install gunicorn

# Set proper ownership
sudo chown -R django:django /opt/django-app
sudo chown -R django:django /var/log/django

# Create supervisor configuration for Django
sudo tee /etc/supervisor/conf.d/django.conf << 'SUPCONF'
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
SUPCONF

# Configure Nginx
sudo tee /etc/nginx/sites-available/django << 'NGINX'
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
NGINX

# Enable Nginx site
sudo ln -sf /etc/nginx/sites-available/django /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Create Django environment file
sudo tee /opt/django-app/.env << 'ENVFILE'
DEBUG=False
DJANGO_SECRET_KEY='$(openssl rand -hex 32)'
ALLOWED_HOSTS=\${EXTERNAL_IP},localhost,127.0.0.1
DB_NAME=django_db
DB_USER=django_user
DB_PASSWORD=\${DB_PASSWORD}
DB_HOST=\${DB_PRIVATE_IP}
DB_PORT=5432
ENVFILE

# Set proper permissions for .env file
sudo chown django:django /opt/django-app/.env
sudo chmod 600 /opt/django-app/.env

# Collect static files
cd /opt/django-app
source venv/bin/activate
sudo python manage.py collectstatic --noinput

# Configure Prometheus
sudo tee /etc/default/prometheus << 'PROMCONF'
ARGS="--web.listen-address=0.0.0.0:9090"
PROMCONF

# Setup Prometheus config
sudo tee /etc/prometheus/prometheus.yml << 'PROMYML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules/*.yml"

scrape_configs:
  - job_name: 'django'
    static_configs:
      - targets: ['\${EXTERNAL_IP}:8000']
        labels:
          instance: 'web-server'

  - job_name: 'node'
    static_configs:
      - targets: ['\${EXTERNAL_IP}:9100']
        labels:
          instance: 'web-server'
      - targets: ['\${DB_PRIVATE_IP}:9100']
        labels:
          instance: 'db-server'

  - job_name: 'postgres'
    static_configs:
      - targets: ['\${DB_PRIVATE_IP}:9187']
        labels:
          instance: 'db-server'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['\${EXTERNAL_IP}:9093']
PROMYML

# Configure alert rules
sudo tee /etc/prometheus/rules/alerts.yml << 'ALERTS'
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
ALERTS

# Configure Alertmanager
sudo tee /etc/default/alertmanager << 'AMCONF'
ARGS="--web.listen-address=0.0.0.0:9093"
AMCONF

sudo tee /etc/alertmanager/alertmanager.yml << 'AMYML'
global:
  resolve_timeout: 5m
  smtp_from: '\${NOTIFICATION_EMAIL}'
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_auth_username: '\${NOTIFICATION_EMAIL}'
  smtp_auth_password: '\${EMAIL_APP_PASSWORD}'
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
      - to: '\${EMAIL_RECIPIENTS}'
        send_resolved: true
AMYML

# Configure node_exporter
sudo tee /etc/default/prometheus-node-exporter << 'NODEEXP'
ARGS="--web.listen-address=0.0.0.0:9100"
NODEEXP

# Configure Cloud Ops Agent
sudo tee /etc/google-cloud-ops-agent/config.yaml << 'OPSCONF'
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
        - http://\${INSTANCE_IP}:9090/metrics
        - http://\${INSTANCE_IP}:9100/metrics  # Node Exporter metrics
  service:
    pipelines:
      default:
        receivers: [hostmetrics, prometheus]
OPSCONF

# Start services
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus
sudo systemctl enable prometheus-node-exporter
sudo systemctl start prometheus-node-exporter
sudo systemctl enable prometheus-alertmanager
sudo systemctl start prometheus-alertmanager
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl enable supervisor
sudo systemctl start supervisor

# Restart Nginx and Supervisor
sudo systemctl restart nginx
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart django

# Restart Cloud Ops Agent
sudo systemctl restart google-cloud-ops-agent

# Set up logrotate for Django logs
sudo tee /etc/logrotate.d/django << 'LOGROT'
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
LOGROT
EOF

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_compute_instance.db_server
  ]
}