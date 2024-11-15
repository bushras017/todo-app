# terraform/instances.tf

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
  # Simple metadata startup script
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

# Install required packages
apt-get update
apt-get install -y python3-pip python3-venv prometheus prometheus-node-exporter prometheus-alertmanager

# Install Cloud Ops Agent
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install
EOF

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform", "compute-ro", "storage-ro"]
  }

  depends_on = [
    google_compute_instance.db_server
  ]
}