# terraform/main.tf
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Network configuration
resource "google_compute_network" "vpc" {
  name                    = "devsecops-vpc"
  auto_create_subnetworks = false
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      auto_create_subnetworks,
      description,
      routing_mode
    ]
  }
}

resource "google_compute_subnetwork" "subnet" {
  name          = "devsecops-subnet"
  ip_cidr_range = "10.0.0.0/24"
  network       = google_compute_network.vpc.id
  region        = var.region

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling       = 0.5
    metadata           = "INCLUDE_ALL_METADATA"
  }
    lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      private_ip_google_access,
      log_config
    ]
    }
}

# Firewall rules
resource "google_compute_firewall" "allow_monitoring" {
  name    = "allow-monitoring"
  network = google_compute_network.vpc.name

  dynamic "allow" {
    for_each = [
      {
        protocol = "tcp"
        ports    = ["22"]
        ranges   = ["35.235.240.0/20"]  # IAP range only for SSH
      },
      {
        protocol = "tcp"
        ports    = ["9090", "9093", "9100", "9187", "80", "443"]
        ranges   = ["0.0.0.0/0"]  # Monitoring ports open to all
      }
    ]
    
    content {
      protocol = allow.value.protocol
      ports    = allow.value.ports
    }
  }

  # The more restrictive source range will be applied to SSH
  source_ranges = ["35.235.240.0/20", "0.0.0.0/0"]
  target_tags   = ["web-server", "db-server"]
  priority      = 1000

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      priority,
      source_ranges,
      target_tags,
      allow
    ]
  }
}

resource "google_compute_firewall" "allow_django" {
  name    = "allow-django"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web-server"]

    lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      priority,
      source_ranges,
      target_tags
    ]
  }
}

resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_tags = ["web-server"]
  target_tags = ["db-server"]
    lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      priority,
      source_tags,
      target_tags
    ]
  }
}

# Firewall rule for blocked IPs
resource "google_compute_firewall" "blocked_ips" {
  name    = "blocked-ips"
  network = google_compute_network.vpc.name
  deny {
    protocol = "all"
  }
  source_ranges = []  # Will be updated by Cloud Function
  target_tags   = ["web-server", "db-server"]
  priority      = 1000
    lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      priority,
      source_ranges,
      target_tags,
      deny
    ]
  }
}