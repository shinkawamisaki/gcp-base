# ===============================================================
# AI受電 → App-Service 連携ツール用インフラ基盤
# ===============================================================

# 1. ツール専用の身分証（サービスアカウント）
resource "google_service_account" "ai_tool_sa" {
  account_id   = "${var.env}-ai-reception-bot"
  display_name = "[${var.env}] AI受電連携ツール専用アカウント"
}

# 2. 金庫A: App-ServiceのAPIキーを入れる箱
resource "google_secret_manager_secret" "app-service_key" {
  secret_id = "${var.env}-app-service-api-key"
  
  labels = merge(local.common_labels, {
    service = "ai-reception"
  })

  replication {
    auto {}
  }
}

# 3. 金庫B: Slack通知用のWebhook URLを入れる箱
resource "google_secret_manager_secret" "slack_webhook" {
  secret_id = var.slack_secret_name
  
  labels = merge(local.common_labels, {
    service = "ai-reception"
  })

  replication {
    auto {}
  }
}

# 4. 金庫C: 予算通知用のWebhook URLを入れる箱 (新規追加)
resource "google_secret_manager_secret" "billing_slack_webhook" {
  secret_id = var.billing_slack_secret_name
  
  labels = merge(local.common_labels, {
    service = "monitoring"
  })

  replication {
    auto {}
  }
}

# 5. 権限付与 (リソースレベル IAM)
resource "google_secret_manager_secret_iam_member" "sa_can_read_app_service" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.app-service_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ai_tool_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "sa_can_read_slack" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.slack_webhook.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ai_tool_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "sa_can_read_billing_slack" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.billing_slack_webhook.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ai_tool_sa.email}"
}
