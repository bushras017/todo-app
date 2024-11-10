# terraform/outputs.tf
output "web_server_public_ip" {
  value = google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip
}

output "db_server_private_ip" {
  value = google_compute_instance.db_server.network_interface[0].network_ip
}

output "prometheus_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:9090"
}

output "alertmanager_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:9093"
}

output "django_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:8000"
}