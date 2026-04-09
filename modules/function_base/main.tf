# ===============================================================
# アプリケーション共通部品 (Cloud Functions, Secrets, Storage)
# ===============================================================

locals {
  activate_apis = [
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com"
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.activate_apis)
  project  = var.project_id
  service  = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "app_source" {
  project  = var.project_id
  name     = "app-source-${var.project_id}"
  location = var.region
  
  uniform_bucket_level_access = true
  force_destroy               = false

  labels = {
    env     = var.env
    managed = "terraform"
    service = "ai-reception"
  }
}

resource "google_secret_manager_secret" "app-service_key" {
  project   = var.project_id
  secret_id = "app-service-api-key"
  
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "slack_webhook" {
  project   = var.project_id
  secret_id = "slack-webhook-url"
  
  replication {
    auto {}
  }
}

resource "google_service_account" "app_sa" {
  project      = var.project_id
  account_id   = "${var.env}-app-runner-sa"
  display_name = "[${var.env}] App Runner Service Account"
}

resource "google_secret_manager_secret_iam_member" "sa_secret_access" {
  for_each  = toset([google_secret_manager_secret.app-service_key.id, google_secret_manager_secret.slack_webhook.id])
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_sa.email}"
}

resource "google_cloudfunctions_function" "app_function" {
  project     = var.project_id
  region      = var.region
  name        = "${var.env}-ai-reception-bot"
  runtime     = "python310"
  description = "AI受電連携ツールのメインプログラム"

  source_archive_bucket = google_storage_bucket.app_source.name
  source_archive_object = var.source_object_name
  
  entry_point           = "handler"
  trigger_http          = true
  
  service_account_email = google_service_account.app_sa.email

  environment_variables = {
    PROJECT_ID = var.project_id
    ENV        = var.env
  }

  labels = {
    env     = var.env
    managed = "terraform"
    service = "ai-reception"
  }
}

output "function_url" {
  value = google_cloudfunctions_function.app_function.https_trigger_url
}

output "source_bucket_name" {
  value = google_storage_bucket.app_source.name
}
