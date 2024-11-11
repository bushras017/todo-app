# terraform/monitoring.tf

# BigQuery dataset for logs
data "google_bigquery_dataset" "security_logs" {
  dataset_id = "security_logs"
  project    = var.project_id
}

data "google_bigquery_table" "alerts" {
  dataset_id = google_bigquery_dataset.security_logs.dataset_id
  table_id   = "alerts"
  project    = var.project_id
  depends_on = [google_bigquery_dataset.security_logs]
}

# PubSub topic for alerts
resource "google_pubsub_topic" "prometheus_alerts" {
  name = "prometheus-alerts"
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      labels,
      message_retention_duration
    ]
  }
}

# Cloud Function
resource "google_storage_bucket" "function_bucket" {
  name     = "${var.project_id}-functions"
  location = var.region
  uniform_bucket_level_access = true
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      labels,
      force_destroy,
      uniform_bucket_level_access,
      versioning
    ]
  }
}

resource "google_storage_bucket_object" "function_archive" {
  name   = "function-${timestamp()}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/function.zip"
  lifecycle {
    prevent_destroy = false  # Allow updates for function deployments
    ignore_changes = [
      detect_md5hash,
      metadata
    ]
  }
}

# Added IAM binding for function service account
resource "google_project_iam_binding" "function_invoker" {
  project = var.project_id
  role    = "roles/cloudfunctions.invoker"
  members = ["serviceAccount:${var.service_account_email}"]
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      members
    ]
  }
}

resource "google_cloudfunctions_function" "alert_handler" {
  name        = "alert-handler"
  description = "Handles Prometheus alerts"
  runtime     = "python39"

  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.function_archive.name
  
  entry_point = "alert_handler"

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.prometheus_alerts.name
  }

  environment_variables = {
    PROJECT_ID = var.project_id
  }

  # Add service account
  service_account_email = var.service_account_email
  lifecycle {
    ignore_changes = [
      available_memory_mb,
      description,
      environment_variables,
      labels,
      max_instances,
      runtime,
      service_account_email,
      source_archive_bucket,
      source_archive_object,
      timeout,
      event_trigger 
    ]
  }
}

# Log sink with explicit permission
resource "google_logging_project_sink" "security_sink" {
  name        = "security-logs-sink"
  description = "Security logs export to BigQuery"
  
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${data.google_bigquery_dataset.security_logs.dataset_id}"
  
  filter = <<-EOT
    resource.type="gce_instance" AND
    (
      jsonPayload.event_type="security_event" OR
      jsonPayload.type="high_cpu" OR
      jsonPayload.type="disk_space_low" OR
      jsonPayload.type="failed_logins" OR
      severity>=WARNING
    )
  EOT

  unique_writer_identity = true

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      description,
      filter,
      exclusions
    ]
  }
}

# Add IAM binding for the log sink service account
resource "google_project_iam_binding" "log_sink_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  members = [google_logging_project_sink.security_sink.writer_identity]
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      members
    ]
  }
}