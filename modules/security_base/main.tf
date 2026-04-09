# ===============================================================
# セキュリティ・ガバナンス設定（SCC & 監査ログ）
# ===============================================================

# --- 1. セキュリティ監視（SCC）の通知設定 ---
resource "google_pubsub_topic" "scc_notifications" {
  name       = "${var.env}-scc-notifications-topic"
  project    = var.project_id
}

# 組織レベルの通知設定 (V2 最新形式)
resource "google_scc_v2_organization_notification_config" "scc_config_org" {
  count        = var.use_org_level ? 1 : 0
  config_id    = "${var.env}-scc-config-${var.project_id}"
  organization = var.org_id
  location     = "global"
  description  = "組織全体のセキュリティ異常を通知"
  pubsub_topic = google_pubsub_topic.scc_notifications.id

  streaming_config {
    filter = "state=\"ACTIVE\""
  }
}

# プロジェクト単位の通知設定
resource "google_scc_v2_project_notification_config" "scc_config_project" {
  count        = var.use_org_level ? 0 : 1
  config_id    = "${var.env}-scc-config"
  project      = var.project_id
  location     = "global"
  description  = "このプロジェクト単体のセキュリティ異常を通知"
  pubsub_topic = google_pubsub_topic.scc_notifications.id

  streaming_config {
    filter = "state=\"ACTIVE\""
  }
}

# SCCからのPub/Subパブリッシュ権限
resource "google_pubsub_topic_iam_member" "scc_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.scc_notifications.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.use_org_level ? google_scc_v2_organization_notification_config.scc_config_org[0].service_account : google_scc_v2_project_notification_config.scc_config_project[0].service_account}"
}

# --- 2. 監査ログの長期保管（Cloud Storage & Sink） ---
resource "google_storage_bucket" "audit_logs_archive" {
  name          = "audit-logs-archive-${var.project_id}"
  project       = var.project_id
  location      = var.region
  
  force_destroy               = false
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }

  labels = merge(local.common_labels, {
    service = "security-audit"
  })

  lifecycle_rule {
    condition {
      age = var.log_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# ログ転送
resource "google_logging_organization_sink" "org_audit_logs_sink" {
  count            = var.use_org_level ? 1 : 0
  name             = "${var.env}-org-audit-logs-to-gcs-${var.project_id}"
  description      = "組織全体の全監査ログをCloud Storageに長期保存"
  org_id           = var.org_id
  destination      = "storage.googleapis.com/${google_storage_bucket.audit_logs_archive.name}"
  include_children = true
  filter           = "logName:\"cloudaudit.googleapis.com\""
}

resource "google_logging_project_sink" "project_audit_logs_sink" {
  count            = var.use_org_level ? 0 : 1
  name             = "${var.env}-project-audit-logs-to-gcs"
  description      = "このプロジェクトの全監査ログをCloud Storageに長期保存"
  project          = var.project_id
  destination      = "storage.googleapis.com/${google_storage_bucket.audit_logs_archive.name}"
  filter           = "logName:\"cloudaudit.googleapis.com\""
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit_logs_archive.name
  role   = "roles/storage.objectCreator" 
  member = var.use_org_level ? google_logging_organization_sink.org_audit_logs_sink[0].writer_identity : google_logging_project_sink.project_audit_logs_sink[0].writer_identity
}

# --- 3. 監査ログ（データアクセスログ）の有効化設定 ---
# 全てをONにするとコストがかかるため、重要なサービスに絞ります。
locals {
  audit_services = [
    "iam.googleapis.com",           # 誰が権限を変えたか？
    "secretmanager.googleapis.com", # 誰がシークレットを見たか？
    "storage.googleapis.com"        # 誰がファイルを書き換えたか？
  ]
}

# 組織レベルでの有効化 (組織管理者権限が必要)
resource "google_organization_iam_audit_config" "org_config" {
  count   = var.use_org_level ? length(local.audit_services) : 0
  org_id  = var.org_id
  service = local.audit_services[count.index]

  audit_log_config {
    log_type = "DATA_READ"  # 読み取り操作 (IAMやSecretManagerで重要)
  }
  audit_log_config {
    log_type = "DATA_WRITE" # 書き込み操作 (全てのサービスで重要)
  }
}

# プロジェクトレベルでの有効化 (組織レベルを使わない場合、または特定のプロジェクトのみ)
resource "google_project_iam_audit_config" "project_config" {
  count   = var.use_org_level ? 0 : length(local.audit_services)
  project = var.project_id
  service = local.audit_services[count.index]

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
