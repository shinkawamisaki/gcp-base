# ===============================================================
# 📦 アプリ個別リソースの定義 (Template)
# ===============================================================

variable "project_id" { description = "デプロイ先のプロジェクトID" }
variable "env"        { description = "環境名 (stg, prd, sandbox)" }
variable "region"     { default = "asia-northeast1" }

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- ここから下に Cloud Run や Cloud SQL などのリソースを追加してください ---

# バケット名の一意性を担保するためのランダムID
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 例: サンプルバケット
resource "google_storage_bucket" "app_data" {
  name          = "${var.project_id}-data-bucket-${random_id.bucket_suffix.hex}"
  location      = var.region
  force_destroy = var.env == "sandbox" # サンドボックスなら削除可能に
  uniform_bucket_level_access = true
}

# ---------------------------------------------------------------
# 監視設定のサンプル (死活監視を行う場合はコメントアウトを外してください)
# ---------------------------------------------------------------

# A. 通知先の定義 (Slack 等)
# resource "google_monitoring_notification_channel" "slack" {
#   display_name = "App Alerts (${var.env})"
#   type         = "slack"
#   labels = {
#     "auth_token"   = "YOUR_SLACK_TOKEN" # Secret Manager からの取得を推奨
#     "channel_name" = "#your-alert-channel"
#   }
# }

# B. HTTP 死活監視 (Uptime Check)
# resource "google_monitoring_uptime_check_config" "http_check" {
#   display_name = "Service Liveness Check (${var.env})"
#   timeout      = "10s"
#   period       = "60s" # 1分おきにチェック

#   http_check {
#     path         = "/"
#     port         = "443"
#     use_ssl      = true
#     validate_ssl = true
#   }

#   monitored_resource {
#     type = "uptime_url"
#     labels = {
#       project_id = var.project_id
#       host       = "your-app-url.a.run.app" # 監視対象のURL
#     }
#   }
# }

# C. アラートポリシー (落ちた時に通知を送る)
# resource "google_monitoring_alert_policy" "uptime_alert" {
#   display_name = "Uptime Alert Policy (${var.env})"
#   combiner     = "OR"
#   conditions {
#     display_name = "Uptime check failure"
#     condition_threshold {
#       filter     = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\""
#       duration   = "60s" # 1分間連続で失敗したら発報
#       comparison = "COMPARISON_GT"
#       threshold_value = 1
#       aggregations {
#         alignment_period   = "60s"
#         per_series_aligner = "ALIGN_FRACTION_TRUE"
#       }
#     }
#   }
#   notification_channels = [google_monitoring_notification_channel.slack.name]
# }
