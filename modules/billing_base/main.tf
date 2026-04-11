# ===============================================================
# 予算監視・アラート設定 (Pub/Sub 通知方式)
# ===============================================================

# プロジェクト情報の取得 (プロジェクト番号を使用するため)
data "google_project" "current" {
  project_id = var.project_id
}

# サービスアカウントの定義
locals {
  cloudbuild_sa = "${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
  compute_sa    = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# --- 0. 必要な API の有効化 ---
resource "google_project_service" "billing_notifier_apis" {
  for_each = toset([
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 【重要】API 有効化直後はサービスエージェントが生成されるまでラグがあるため、600秒（10分）待機します (OSSとしての堅牢性)
resource "time_sleep" "wait_for_billing_apis" {
  depends_on      = [google_project_service.billing_notifier_apis]
  create_duration = "600s"
}

# --- 1. 通知用 Pub/Sub トピックの作成 ---
resource "google_pubsub_topic" "budget_notification_topic" {
  project = var.project_id
  name    = "${var.app_base_name}-budget-notifications"
  
  depends_on = [google_project_service.billing_notifier_apis]
}

# --- 2. 権限設定 ---
# 請求システムが Pub/Sub にメッセージを投げられるようにします。
resource "google_pubsub_topic_iam_member" "billing_pubsub_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.budget_notification_topic.name
  role    = "roles/pubsub.publisher"
  
  # 確認済みの実在するグローバル SA を指定します
  member = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"

  # 予算作成を待ってから権限を付与します
  depends_on = [google_billing_budget.total_budget]
}

# --- 3. 予算設定の更新 (Pub/Sub 連携) ---
resource "google_billing_budget" "total_budget" {
  billing_account = var.billing_account_id
  display_name    = "Total Org Budget: ${var.app_base_name}"

  budget_filter {
    projects = []
  }

  amount {
    specified_amount {
      currency_code = var.currency
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    pubsub_topic = google_pubsub_topic.budget_notification_topic.id
  }

  depends_on = [
    time_sleep.wait_for_billing_apis
  ]
}

# --- 4. 通知用 Cloud Functions (Pub/Sub トリガー) ---

# 4a. サービスアカウント (実行用 & ビルド用)
resource "google_service_account" "budget_notifier_sa" {
  project      = var.project_id
  account_id   = "${var.app_base_name}-budget-notifier"
  display_name = "Budget Notifier SA (Pub/Sub Triggered)"
}

resource "google_service_account" "billing_build_sa" {
  project      = var.project_id
  account_id   = "${var.app_base_name}-billing-build-sa"
  display_name = "Budget Notifier Build SA (Least Privilege)"
}

# 4b. Artifact Registry リポジトリ (専用)
resource "random_id" "repo_suffix" {
  byte_length = 2
}

resource "google_artifact_registry_repository" "gcf_artifacts" {
  project       = var.project_id
  location      = var.region
  repository_id = "billing-repo-${random_id.repo_suffix.hex}"
  format        = "DOCKER"
  description   = "Cloud Functions Gen2 Artifacts for Billing Notifier"
  
  depends_on = [google_project_service.billing_notifier_apis]
}

# 4c. 最小権限設定 (IAM)

# ビルド SA への権限付与
resource "google_project_iam_member" "build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.billing_build_sa.email}"
}

resource "google_artifact_registry_repository_iam_member" "build_artifact_admin" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.gcf_artifacts.name
  role       = "roles/artifactregistry.repoAdmin"
  member     = "serviceAccount:${google_service_account.billing_build_sa.email}"
}

resource "google_storage_bucket_iam_member" "build_source_reader" {
  bucket = google_storage_bucket.function_source_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.billing_build_sa.email}"
}

# ビルド SA が実行用 SA になり代わる権限 (Gen2 デプロイに必須)
resource "google_service_account_iam_member" "build_acts_as_notifier" {
  service_account_id = google_service_account.budget_notifier_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.billing_build_sa.email}"
}

# ビルド SA が Cloud Build のシステムバケット等を使えるようにする最低限の権限
resource "google_project_iam_member" "build_gcs_admin_restricted" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.billing_build_sa.email}"
  
  condition {
    title       = "CloudBuildLogsBucketAccess"
    description = "Allows writing to auto-generated Cloud Build logs and staging buckets."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${data.google_project.current.number}.cloudbuild-logs\") || resource.name.startsWith(\"projects/_/buckets/${var.project_id}_cloudbuild\")"
  }
}

# システムバケット（Google管理）への読み取り権限を一括付与 (Gen2 ビルド成功の鍵)
resource "google_project_iam_member" "build_system_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.billing_build_sa.email}"
}

# 実行用 SA へのシークレット参照権限
resource "google_secret_manager_secret_iam_member" "notifier_secret_accessor" {
  project   = var.project_id
  secret_id = var.slack_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.budget_notifier_sa.email}"
}

# IAM 権限の伝搬を確実に待つタイマー
resource "time_sleep" "wait_for_notifier_iam" {
  depends_on = [
    google_project_iam_member.build_log_writer,
    google_artifact_registry_repository_iam_member.build_artifact_admin,
    google_storage_bucket_iam_member.build_source_reader,
    google_service_account_iam_member.build_acts_as_notifier,
    google_project_iam_member.build_gcs_admin_restricted,
    google_project_iam_member.build_system_storage_viewer,
    google_secret_manager_secret_iam_member.notifier_secret_accessor
  ]
  create_duration = "120s"
}

# 4d. Cloud Functions 本体の定義 (Gen2)
resource "google_cloudfunctions2_function" "budget_notifier" {
  project     = var.project_id
  location    = var.region
  name        = "${var.app_base_name}-budget-notifier"
  description = "Slack notifier for budget alerts via Pub/Sub (Least Privilege Build)"

  build_config {
    runtime     = "python311"
    entry_point = "notify_slack"
    service_account = google_service_account.billing_build_sa.id
    docker_repository = google_artifact_registry_repository.gcf_artifacts.id

    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.source_archive.name
      }
    }
  }

  service_config {
    max_instance_count = 3
    available_memory   = "256Mi"
    timeout_seconds    = 60
    service_account_email = google_service_account.budget_notifier_sa.email
    environment_variables = {
      SLACK_SECRET_ID         = var.slack_secret_name
      PROJECT_ID              = var.project_id
      GCP_CONSOLE_URL_BILLING = var.gcp_console_billing_url_template
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_notification_topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.budget_notifier_sa.email
  }

  depends_on = [
    google_pubsub_topic_iam_member.billing_pubsub_publisher,
    time_sleep.wait_for_notifier_iam
  ]
}

# 最小権限設定 1: 予算通知ボットが自分自身の Cloud Run サービスを呼び出せるようにする
resource "google_cloud_run_service_iam_member" "budget_notifier_invoker" {
  project  = var.project_id
  location = google_cloudfunctions2_function.budget_notifier.location
  service  = google_cloudfunctions2_function.budget_notifier.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.budget_notifier_sa.email}"
}

# 最小権限設定 2: Eventarc サービスエージェントに「このボットのみ」の呼び出し権限を付与
resource "google_cloud_run_service_iam_member" "eventarc_invoker" {
  project  = var.project_id
  location = google_cloudfunctions2_function.budget_notifier.location
  service  = google_cloudfunctions2_function.budget_notifier.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-eventarc.iam.gserviceaccount.com"
}

# 最小権限設定 3: Pub/Sub サービスエージェントに「この通知用 SA のみ」のトークン作成権限を付与
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.budget_notifier_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# --- 5. ソースコード転送用バケット ---
resource "google_storage_bucket" "function_source_bucket" {
  project                     = var.project_id
  name                        = "${var.project_id}-budget-notifier-source"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

data "archive_file" "source" {
  type        = "zip"
  output_path = "${path.module}/function.zip"
  source_dir  = "${path.module}/billing_notifier/"
}

resource "google_storage_bucket_object" "source_archive" {
  name   = "source-${data.archive_file.source.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.source.output_path
}
