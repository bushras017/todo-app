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

  metadata_startup_script = data.template_file.init_web.rendered

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_compute_instance.db_server
  ]
}