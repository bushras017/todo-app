# terraform/outputs.tf

output "web_server_public_ip" {
  value = google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip
  description = "The public IP address of the web server"
}

output "db_server_private_ip" {
  value = google_compute_instance.db_server.network_interface[0].network_ip
  description = "The private IP address of the database server"
}

output "prometheus_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:9090"
  description = "The URL for accessing Prometheus"
}

output "alertmanager_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:9093"
  description = "The URL for accessing Alertmanager"
}

output "django_url" {
  value = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}:8000"
  description = "The URL for accessing the Django application"
}

output "function_name" {
  value = google_cloudfunctions_function.alert_handler.name
  description = "The name of the deployed Cloud Function"
}

output "bigquery_dataset" {
  value = google_bigquery_dataset.security_logs.dataset_id
  description = "The ID of the BigQuery dataset for security logs"
}