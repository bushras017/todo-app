
# terraform/instances.tf
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
    access_config {}  # This will create an ephemeral external IP
  }

  metadata = {
    db-private-ip = google_compute_instance.db_server.network_interface[0].network_ip
    email-recipients = jsonencode(var.alert_email_recipients)
    notification-email = var.notification_email
    email-app-password = var.notification_email_password
  }

  metadata_startup_script = templatefile("${path.module}/../deployment/scripts/init-web.sh", {
    DB_PRIVATE_IP = google_compute_instance.db_server.network_interface[0].network_ip
    EMAIL_RECIPIENTS = join(",", var.alert_email_recipients)
    NOTIFICATION_EMAIL = var.notification_email
    EMAIL_APP_PASSWORD = var.notification_email_password
    PROJECT_ID = var.project_id
  })

  service_account {
    scopes = ["cloud-platform"]
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

  metadata_startup_script = templatefile("${path.module}/../deployment/scripts/init-db.sh", {
    DB_PASSWORD = var.db_password
    PROJECT_ID = var.project_id
  })

  service_account {
    scopes = ["cloud-platform"]
  }
}




