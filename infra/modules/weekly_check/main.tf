# ===============================================================
# GCP 版 週次監査 (weekly_check) モジュール - Cloud Functions Gen2 版
# ===============================================================

# --- 0. 必要な API の有効化 ---
resource "google_project_service" "weekly_audit_apis" {
  for_each = toset([
    "cloudscheduler.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "aiplatform.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- 0-2. Artifact Registry リポジトリを明示的に作成（絶対衝突しない名前） ---
resource "random_id" "repo_suffix" {
  byte_length = 2
}

resource "google_artifact_registry_repository" "gcf_artifacts" {
  project       = var.project_id
  location      = var.region
  repository_id = "audit-repo-${random_id.repo_suffix.hex}"
  format        = "DOCKER"
  description   = "Cloud Functions Gen2 Artifacts (Custom Unique Repo)"
  
  depends_on = [google_project_service.weekly_audit_apis]
}

# 0-3. 【最小権限】ビルド担当 SA にリポジトリ限定の権限を付与
# プロジェクト全体の admin ではなく、このリポジトリ限定の管理権限に絞ります
resource "google_artifact_registry_repository_iam_member" "audit_repo_admin" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.gcf_artifacts.name
  role       = "roles/artifactregistry.repoAdmin"
  member     = "serviceAccount:${google_service_account.audit_build_sa.email}"
  
  depends_on = [google_artifact_registry_repository.gcf_artifacts]
}

# API有効化後のサービスエージェント自動生成待ち
resource "time_sleep" "wait_for_apis" {
  depends_on      = [google_project_service.weekly_audit_apis]
  create_duration = "60s"
}

# プロジェクト情報の取得
data "google_project" "project" {
  project_id = var.project_id
}

# --- 1. 実行用サービスアカウント ---
resource "google_service_account" "audit_sa" {
  project      = var.project_id
  account_id   = "weekly-audit-sa"
  display_name = "Weekly Security Audit Service Account"
  depends_on   = [time_sleep.wait_for_apis]
}

# 1-2. ビルド専用サービスアカウント (最小権限)
resource "google_service_account" "audit_build_sa" {
  project      = var.project_id
  account_id   = "weekly-audit-build-sa"
  display_name = "Weekly Security Audit Build SA"
  depends_on   = [time_sleep.wait_for_apis]
}

# 権限: ビルドログ出力 (Cloud Logging)
resource "google_project_iam_member" "audit_build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.audit_build_sa.email}"
}

# 権限: Cloud Build 実行ログバケットへの書き込み (GCS)
resource "google_project_iam_member" "audit_build_gcs_log_writer" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.audit_build_sa.email}"

  condition {
    title       = "CloudBuildLogsBucketAccess"
    description = "Allows writing to auto-generated Cloud Build logs and staging buckets."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${data.google_project.project.number}.cloudbuild-logs\") || resource.name.startsWith(\"projects/_/buckets/${var.project_id}_cloudbuild\")"
  }
}

# 権限: 自前のソースバケット読み取り
resource "google_storage_bucket_iam_member" "audit_build_source_reader" {
  bucket = google_storage_bucket.audit_source_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.audit_build_sa.email}"
}

# 権限: システムバケット読み取り (条件付き)
resource "google_project_iam_member" "audit_build_system_storage_restricted" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.audit_build_sa.email}"

  condition {
    title       = "GCF_System_Bucket_Only"
    description = "Allows access only to Google-managed source buckets for GCF builds."
    expression  = "resource.name.startsWith(\"projects/_/buckets/gcf-v2-sources-\")"
  }
}

# 権限: Artifact Registry 書き込み
resource "google_project_iam_member" "audit_build_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.audit_build_sa.email}"
}

# 権限: サービスエージェントによる借用
resource "google_service_account_iam_member" "cb_agent_actas" {
  service_account_id = google_service_account.audit_build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "gcf_agent_actas" {
  service_account_id = google_service_account.audit_build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcf-admin-robot.iam.gserviceaccount.com"
}

# 【最重要】IAM 権限が反映されるまで 60 秒待機
resource "time_sleep" "wait_for_audit_iam" {
  create_duration = "60s"
  depends_on = [
    google_project_iam_member.audit_build_log_writer,
    google_project_iam_member.audit_build_gcs_log_writer,
    google_storage_bucket_iam_member.audit_build_source_reader,
    google_project_iam_member.audit_build_system_storage_restricted,
    google_project_iam_member.audit_build_artifact_writer,
    google_service_account_iam_member.cb_agent_actas,
    google_service_account_iam_member.gcf_agent_actas
  ]
}

# --- 2. ソースコードのパッケージング ---
data "archive_file" "audit_source" {
  type        = "zip"
  source_dir  = "${path.module}"
  output_path = "${path.module}/weekly_check.zip"
  excludes    = ["main.tf", "weekly_check.zip", "outputs.tf"]
}

resource "google_storage_bucket" "audit_source_bucket" {
  name                     = "audit-src-${var.project_id}"
  location                 = var.region
  project                  = var.project_id
  force_destroy            = false
  uniform_bucket_level_access = true
  depends_on               = [time_sleep.wait_for_apis]
}

resource "google_storage_bucket_object" "audit_zip" {
  # データの整合性を保証するため、アーカイブの出力ハッシュを直接名前に使用します
  name   = "source-${data.archive_file.audit_source.output_md5}.zip"
  bucket = google_storage_bucket.audit_source_bucket.name
  source = data.archive_file.audit_source.output_path
}

# --- 2-2. 監査レポート保存用バケット ---
resource "google_storage_bucket" "audit_reports" {
  name                     = "audit-reports-${var.project_id}"
  project                  = var.project_id
  location                 = var.region
  force_destroy            = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning { enabled = true }
  retention_policy {
    is_locked        = false
    retention_period = 2592000
  }
}

resource "google_storage_bucket_iam_member" "audit_sa_report_admin" {
  bucket = google_storage_bucket.audit_reports.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.audit_sa.email}"
}

# 権限: シークレット & フォルダ閲覧
resource "google_secret_manager_secret_iam_member" "audit_sa_gemini_key" {
  project   = var.admin_project_id
  secret_id = var.gemini_api_key_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.audit_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "audit_sa_slack_webhook" {
  project   = var.admin_project_id
  secret_id = var.slack_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.audit_sa.email}"
}

resource "google_folder_iam_member" "audit_sa_viewer" {
  for_each = toset(var.scan_folder_ids)
  folder   = each.value
  role     = "roles/iam.securityReviewer"
  member   = "serviceAccount:${google_service_account.audit_sa.email}"
}

# --- 3. Cloud Function 本体 (Gen2) ---
resource "google_cloudfunctions2_function" "weekly_audit_func" {
  name        = "weekly-security-checker"
  project     = var.project_id
  location    = var.region
  description = "Weekly risk scan using Python and Gemini (Gen2)"

  build_config {
    runtime     = "python311"
    entry_point = "run_security_check"
    service_account = google_service_account.audit_build_sa.id

    # 【重要】明示的なリポジトリ指定（409エラー回避の核心）
    docker_repository = google_artifact_registry_repository.gcf_artifacts.id

    source {
      storage_source {
        bucket = google_storage_bucket.audit_source_bucket.name
        object = google_storage_bucket_object.audit_zip.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "512M"
    timeout_seconds    = 300
    service_account_email = google_service_account.audit_sa.email
    environment_variables = {
      PROJECT_ID        = var.project_id
      APP_NAME          = var.app_name
      ENABLE_AI_SUMMARY = var.enable_ai_summary ? "true" : "false"
      SLACK_SECRET_NAME = var.slack_secret_name
      GEMINI_SECRET_NAME = var.gemini_api_key_secret_name
      SANDBOX_SLACK_SECRET_NAME = var.sandbox_slack_secret_name
      SECRET_PROJECT_ID = var.admin_project_id
      REPORT_BUCKET     = google_storage_bucket.audit_reports.name
      SCAN_FOLDER_IDS   = join(",", var.scan_folder_ids)
      # 組織レベルで設定済みの監査ログ（プログラムに教えるためのヒント）
      INHERITED_AUDIT_SERVICES = "iam.googleapis.com,secretmanager.googleapis.com,storage.googleapis.com"
      }
      }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.weekly_audit_trigger.id
    retry_policy   = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.audit_sa.email
  }

  # 待機が終わってからデプロイ
  depends_on = [
    time_sleep.wait_for_audit_iam,
    google_artifact_registry_repository.gcf_artifacts,
    google_artifact_registry_repository_iam_member.audit_repo_admin
  ]
}

resource "google_cloud_run_service_iam_member" "audit_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.weekly_audit_func.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.audit_sa.email}"
}

# --- 4. 実行スケジュール設定 ---
resource "google_pubsub_topic" "weekly_audit_trigger" {
  name    = "weekly-audit-trigger-topic"
  project = var.project_id
}

resource "google_cloud_scheduler_job" "weekly_audit_schedule" {
  name             = "periodic-security-check-job"
  project          = var.project_id
  region           = var.region
  schedule         = var.audit_schedule
  time_zone        = "Asia/Tokyo"

  pubsub_target {
    topic_name = google_pubsub_topic.weekly_audit_trigger.id
    data       = base64encode("start")
  }
}
