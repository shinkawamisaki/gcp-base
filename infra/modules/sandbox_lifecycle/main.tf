# ===============================================================
# サンドボックス・ライフサイクル管理 (sandbox_lifecycle) モジュール
# ===============================================================

# --- 0. 必要な API の有効化 ---
resource "google_project_service" "lifecycle_apis" {
  for_each = toset([
    "cloudscheduler.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# API有効化後の待機
resource "time_sleep" "wait_for_apis" {
  depends_on      = [google_project_service.lifecycle_apis]
  create_duration = "60s"
}

# プロジェクト情報の取得
data "google_project" "project" {
  project_id = var.project_id
}

# --- 1. 実行用サービスアカウント ---
resource "google_service_account" "lifecycle_sa" {
  project      = var.project_id
  account_id   = "sandbox-lifecycle-bot"
  display_name = "Sandbox Lifecycle Management Bot"
  depends_on   = [time_sleep.wait_for_apis]
}

# 1-2. ビルド専用サービスアカウント (最小権限)
resource "google_service_account" "lifecycle_build_sa" {
  project      = var.project_id
  account_id   = "sandbox-lifecycle-build-sa"
  display_name = "Sandbox Lifecycle Build SA"
  depends_on   = [time_sleep.wait_for_apis]
}

# 権限: ビルドログ出力 (Cloud Logging)
resource "google_project_iam_member" "lifecycle_build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.lifecycle_build_sa.email}"
}

# 権限: Cloud Build 実行ログバケットへの書き込み (GCS)
resource "google_project_iam_member" "lifecycle_build_gcs_log_writer" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.lifecycle_build_sa.email}"

  condition {
    title       = "CloudBuildLogsBucketAccess"
    description = "Allows writing to auto-generated Cloud Build logs and staging buckets."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${data.google_project.project.number}.cloudbuild-logs\") || resource.name.startsWith(\"projects/_/buckets/${var.project_id}_cloudbuild\")"
  }
}

# 権限: 自前のソースバケット読み取り
resource "google_storage_bucket_iam_member" "lifecycle_build_source_reader" {
  bucket = google_storage_bucket.lifecycle_source_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.lifecycle_build_sa.email}"
}

# 権限: システムバケット読み取り (条件付き)
resource "google_project_iam_member" "lifecycle_build_system_storage_restricted" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.lifecycle_build_sa.email}"

  condition {
    title       = "GCF_System_Bucket_Only"
    description = "Allows access only to Google-managed source buckets for GCF builds."
    expression  = "resource.name.startsWith(\"projects/_/buckets/gcf-v2-sources-\")"
  }
}

# --- 0-2. Artifact Registry リポジトリを明示的に作成（絶対衝突しない名前） ---
resource "random_id" "repo_suffix" {
  byte_length = 2
}

resource "google_artifact_registry_repository" "gcf_artifacts" {
  project       = var.project_id
  location      = var.region
  repository_id = "lifecycle-repo-${random_id.repo_suffix.hex}"
  format        = "DOCKER"
  description   = "Cloud Functions Gen2 Artifacts (Custom Unique Repo)"
  
  depends_on = [google_project_service.lifecycle_apis]
}

# 権限: Artifact Registry 書き込み
resource "google_project_iam_member" "lifecycle_build_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.lifecycle_build_sa.email}"
}

# 権限: サービスエージェントによる借用
resource "google_service_account_iam_member" "cb_agent_actas" {
  service_account_id = google_service_account.lifecycle_build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "gcf_agent_actas" {
  service_account_id = google_service_account.lifecycle_build_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcf-admin-robot.iam.gserviceaccount.com"
}

# 【最重要】IAM 権限およびリポジトリ作成が反映されるまで 60 秒待機
resource "time_sleep" "wait_for_lifecycle_iam" {
  create_duration = "60s"
  depends_on = [
    google_project_iam_member.lifecycle_build_log_writer,
    google_project_iam_member.lifecycle_build_gcs_log_writer,
    google_storage_bucket_iam_member.lifecycle_build_source_reader,
    google_project_iam_member.lifecycle_build_system_storage_restricted,
    google_project_iam_member.lifecycle_build_artifact_writer,
    google_service_account_iam_member.cb_agent_actas,
    google_service_account_iam_member.gcf_agent_actas,
    google_artifact_registry_repository.gcf_artifacts
  ]
}

# 権限: 指定フォルダ内のプロジェクト管理
resource "google_folder_iam_member" "lifecycle_viewer" {
  folder = var.scan_folder_id
  role   = "roles/resourcemanager.folderAdmin"
  member = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

resource "google_folder_iam_member" "lifecycle_deleter" {
  folder = var.scan_folder_id
  role   = "roles/resourcemanager.projectDeleter"
  member = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

resource "google_folder_iam_member" "lifecycle_lien_modifier" {
  folder = var.scan_folder_id
  role   = "roles/resourcemanager.lienModifier"
  member = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "lifecycle_secret_accessor" {
  project   = var.admin_project_id
  secret_id = var.sandbox_slack_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "github_token_accessor" {
  project   = var.admin_project_id
  secret_id = "infra-github-token"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

# --- 2. Cloud Function 本体 (Gen2) ---
data "archive_file" "lifecycle_source" {
  type        = "zip"
  source_dir  = path.module
  output_path = "${path.module}/sandbox_lifecycle.zip"
  excludes    = ["main.tf", "variables.tf", "sandbox_lifecycle.zip", "outputs.tf"]
}

resource "google_storage_bucket" "lifecycle_source_bucket" {
  name                     = "sandbox-lifecycle-src-${var.project_id}"
  location                 = var.region
  project                  = var.project_id
  force_destroy            = false
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_object" "lifecycle_zip" {
  # ZIPファイルのMD5ハッシュをオブジェクト名に含めることで、コード変更時に確実に再デプロイされるようにします
  # data.archive_file の output_md5 を使用することで、Terraform の整合性エラーを回避します
  name   = "source-${data.archive_file.lifecycle_source.output_md5}.zip"
  bucket = google_storage_bucket.lifecycle_source_bucket.name
  source = data.archive_file.lifecycle_source.output_path
}

resource "google_cloudfunctions2_function" "lifecycle_func" {
  name        = "sandbox-lifecycle-bot"
  project     = var.project_id
  location    = var.region
  description = "Daily sandbox expiry check and notification"

  build_config {
    runtime     = "python310"
    entry_point = "run_lifecycle_check"
    service_account = google_service_account.lifecycle_build_sa.id
    
    # 【重要】明示的なリポジトリ指定（409エラー回避の核心）
    docker_repository = google_artifact_registry_repository.gcf_artifacts.id

    source {
      storage_source {
        bucket = google_storage_bucket.lifecycle_source_bucket.name
        object = google_storage_bucket_object.lifecycle_zip.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 60
    service_account_email = google_service_account.lifecycle_sa.email
    environment_variables = {
      PROJECT_ID        = var.project_id
      SECRET_PROJECT_ID          = var.admin_project_id
      SCAN_FOLDER_ID             = var.scan_folder_id
      SANDBOX_SLACK_SECRET_NAME  = var.sandbox_slack_secret_name
      GH_ORG_NAME                = var.gh_org_name
      GH_REPO_NAME               = var.gh_repo_name
      GH_TOKEN_SECRET_NAME       = var.github_token_secret_name

    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.lifecycle_trigger.id
    retry_policy   = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.lifecycle_sa.email
  }

  # 待機が終わってからデプロイ
  depends_on = [
    time_sleep.wait_for_lifecycle_iam
  ]
}

resource "google_cloud_run_service_iam_member" "lifecycle_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.lifecycle_func.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.lifecycle_sa.email}"
}

# --- 3. 実行スケジュール設定 ---
resource "google_pubsub_topic" "lifecycle_trigger" {
  name    = "sandbox-lifecycle-trigger-topic"
  project = var.project_id
}

resource "google_cloud_scheduler_job" "lifecycle_schedule" {
  name             = "hourly-sandbox-lifecycle-job"
  project          = var.project_id
  region           = var.region
  schedule         = "0 * * * *"
  time_zone        = "Asia/Tokyo"

  pubsub_target {
    topic_name = google_pubsub_topic.lifecycle_trigger.id
    data       = base64encode("start")
  }
}
