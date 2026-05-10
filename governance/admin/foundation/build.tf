# ===============================================================
# Artifact Registry for Infrastructure Tools
# ===============================================================
resource "google_artifact_registry_repository" "infra_tools" {
  location      = var.region
  repository_id = "infra-tools"
  description   = "Docker repository for infrastructure and CI/CD tools"
  format        = "DOCKER"
  project       = var.project_id
}

# ===============================================================
# Cloud Build Service Account
# ===============================================================
resource "google_service_account" "cloudbuild_runner" {
  project      = var.project_id
  account_id   = "prd-cloudbuild-runner-sa"
  display_name = "Cloud Build Runner SA for AI Verifier"
}

# 逆引き仕様書（Changelogs）保存バケットへの書き込み権限
# ※ google_storage_bucket.changelogs は main.tf で定義されています
resource "google_storage_bucket_iam_member" "cloudbuild_changelog_admin" {
  bucket = google_storage_bucket.changelogs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# Vertex AI (Gemini) の利用権限
resource "google_project_iam_member" "cloudbuild_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# ログ書き込み権限
resource "google_project_iam_member" "cloudbuild_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# Artifact Registry 読み取り権限
resource "google_artifact_registry_repository_iam_member" "cloudbuild_artifact_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.infra_tools.location
  repository = google_artifact_registry_repository.infra_tools.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# Secret Manager アクセス権限
resource "google_secret_manager_secret_iam_member" "cloudbuild_github_token_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.github_token_pr_reviewer.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

resource "google_secret_manager_secret_iam_member" "cloudbuild_datadog_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.datadog_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudbuild_runner.email}"
}

# ===============================================================
# Cloud Build Trigger
# ===============================================================
# ※ GitHub App の接続が GCP 側で手動設定されている前提の構成です
resource "google_cloudbuild_trigger" "pr_reviewer" {
  project     = var.project_id
  name        = "ai-pr-reviewer"
  description = "Trigger AI reviewer on Pull Requests"
  location    = "global"

  github {
    owner = var.gh_org_name
    name  = var.gh_repo_name
    pull_request {
      branch          = "^main$"
      comment_control = "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY"
    }
  }

  service_account = google_service_account.cloudbuild_runner.id

  filename = "cloudbuild-pr.yaml"
}
