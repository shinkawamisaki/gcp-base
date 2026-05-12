variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "asia-northeast1"
}

variable "env" {
  description = "The environment name (e.g. prd, stg)"
  type        = string
}

variable "source_object_name" {
  description = "The Cloud Storage object name of the function source archive"
  type        = string
}