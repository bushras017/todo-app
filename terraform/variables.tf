# terraform/variables.tf

variable "project_id" {
  type = string
  description = "The GCP project ID"
}

variable "region" {
  type    = string
  default = "us-central1"
  description = "The GCP region for resources"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
  description = "The GCP zone for resources"
}

variable "db_password" {
  type      = string
  sensitive = true
  description = "Password for the database user"
}

variable "notification_email" {
  type = string
  description = "Email address for sending notifications"
}

variable "notification_email_password" {
  type      = string
  sensitive = true
  description = "App password for the notification email account"
}

variable "alert_email_recipients" {
  type = list(string)
  description = "List of email addresses to receive alerts"
}

variable "service_account_email" {
  type = string
  description = "The email of the service account used for deployments"
}