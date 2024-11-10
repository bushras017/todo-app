# terraform/variables.tf
variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "notification_email" {
  type = string
}

variable "notification_email_password" {
  type      = string
  sensitive = true
}

variable "alert_email_recipients" {
  type = list(string)
}