

# deployment/scripts/init-db.sh
#!/bin/bash
set -e

# Get instance IP
INSTANCE_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

# Install required packages
apt-get update
apt-get install -y postgresql postgresql-contrib prometheus-node-exporter postgres-exporter

# Install Google Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install

# Configure PostgreSQL
sudo -u postgres psql -c "CREATE USER django_user WITH PASSWORD '${DB_PASSWORD}';"
sudo -u postgres psql -c "CREATE DATABASE django_db OWNER django_user;"

echo "host    django_db    django_user    10.0.0.0/24    md5" >> /etc/postgresql/12/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/12/main/postgresql.conf

# Configure node_exporter
cat > /etc/default/prometheus-node-exporter << EOF
ARGS="--web.listen-address=0.0.0.0:9100"
EOF

# Configure postgres_exporter
cat > /etc/default/postgres-exporter << EOF
DATA_SOURCE_NAME="postgresql://postgres:${DB_PASSWORD}@localhost:5432/postgres?sslmode=disable"
ARGS="--web.listen-address=0.0.0.0:9187"
EOF

# Configure Cloud Ops Agent
cat > /etc/google-cloud-ops-agent/config.yaml << EOF
logging:
  receivers:
    postgres:
      type: files
      include_paths:
        - /var/log/postgresql/postgresql-12-main.log
  service:
    pipelines:
      postgres:
        receivers: [postgres]
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
    postgres:
      type: postgresql
      collection_interval: 30s
  service:
    pipelines:
      default:
        receivers: [hostmetrics, postgres]
EOF

# Start services
systemctl daemon-reload
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter
systemctl enable postgres-exporter
systemctl start postgres-exporter
systemctl restart postgresql
systemctl restart google-cloud-ops-agent