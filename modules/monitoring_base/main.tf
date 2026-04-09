# ===============================================================
# 統合監視モジュール (Uptime Check & Log Alert)
# ===============================================================

# --- 0. 準備: プロジェクト情報の取得 ---
data "google_project" "current" {
  project_id = var.project_id
}

# --- 0b. 監視サービスアイデンティティの作成 ---
resource "google_project_service_identity" "monitoring_sa" {
  provider = google-beta
  project  = var.project_id
  service  = "monitoring.googleapis.com"
}

# 【最重要】Identity 作成直後は IAM への反映にラグがあるため、60秒待機します (OSSとしての堅牢性)
resource "time_sleep" "wait_for_monitoring_id" {
  depends_on      = [google_project_service_identity.monitoring_sa]
  create_duration = "60s"
}

# --- 1. Slack 通知チャンネルの設定 ---

# シークレットの最新バージョンから「実際の値」を取得
data "google_secret_manager_secret_version" "slack_token" {
  project = var.project_id
  secret  = var.slack_secret_name
  version = "latest"
}

resource "google_monitoring_notification_channel" "slack" {
  project      = var.project_id
  display_name = "Slack Notification Channel"
  type         = "slack"

  labels = {
    "channel_name" = var.slack_channel_name != "" ? var.slack_channel_name : "general"
  }

  sensitive_labels {
    # 読み取った最新の「値そのもの」を、改行を除去して渡す
    auth_token = trimspace(data.google_secret_manager_secret_version.slack_token.secret_data)
  }
}


# --- 1b. 監視サービスへのシークレット読み取り権限付与 ---
resource "google_secret_manager_secret_iam_member" "monitoring_secret_accessor" {
  project   = var.project_id
  secret_id = var.slack_secret_name
  role      = "roles/secretmanager.secretAccessor"
  
  # 待機後の Identity を使用
  member  = "serviceAccount:${google_project_service_identity.monitoring_sa.email}"

  depends_on = [time_sleep.wait_for_monitoring_id]
}

# 2. HTTP 死活監視 (外勤の監視)
resource "google_monitoring_uptime_check_config" "http_check" {
  for_each = var.monitoring_targets

  project      = var.project_id
  display_name = "Uptime Check: ${each.key}"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = "443"
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = each.value
    }
  }
}

# 3. 死活監視用アラートポリシー
resource "google_monitoring_alert_policy" "uptime_alert" {
  for_each = var.monitoring_targets

  project      = var.project_id
  display_name = "Uptime Alert Policy: ${each.key}"
  combiner     = "OR"
  
  conditions {
    display_name = "Uptime check failure"
    condition_threshold {
      filter     = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND resource.label.\"host\"=\"${each.value}\""
      duration   = "60s" 
      comparison = "COMPARISON_GT"
      threshold_value = 1
      aggregations {
        alignment_period   = "1200s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.slack.name]
  enabled = true
}

# 4. ログベース・アラート (内勤の監視)
resource "google_monitoring_alert_policy" "log_error_alert" {
  project      = var.project_id
  display_name = "Critical Error Log Alert"
  combiner     = "OR"

  conditions {
    display_name = "Error log detected"
    condition_matched_log {
      filter = "severity >= ERROR"
    }
  }

  notification_channels = [google_monitoring_notification_channel.slack.name]

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
  }

  enabled = true
}
