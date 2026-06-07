variable "project_id" {
  description = "ボットをデプロイするプロジェクトID (auditプロジェクト)"
  type        = string
}

variable "admin_project_id" {
  description = "シークレットが格納されている Admin プロジェクトID"
  type        = string
}

variable "scan_folder_id" {
  description = "スキャン対象の Sandboxes フォルダID"
  type        = string
}

variable "region" {
  description = "デプロイリージョン"
  type        = string
}

variable "sandbox_slack_secret_name" {
  description = "通知用 Slack Webhook のシークレット名"
  type        = string
}

variable "gh_org_name" {
  description = "GitHub Organization name"
  type        = string
}

variable "gh_repo_name" {
  description = "GitHub Repository name"
  type        = string
}

variable "github_token_secret_name" {
  description = "GitHub 認証用シークレット名 (PAT または GitHub App 認証情報)"
  type        = string
  default     = "infra-github-token"
}

variable "lifecycle_schedule" {
  description = <<-EOT
    サンドボックスのライフサイクルチェック（期限切れ削除トリガー＋カウントダウン警告通知）の実行スケジュール（cron 形式・time_zone は Asia/Tokyo）。
    既定は日次・朝7時（"0 7 * * *"）。expiry_date は日単位（YYYY-MM-DD）のため判定は日付境界でしか変わらず、毎時実行は不要。
    朝7時は (1) 期限切れ削除を当日中に確実に実行しつつ、(2) 「あと N 日」の警告 Slack を始業前に人へ届けるための既定値。
    注意: 警告通知は「実行ごと」に送られる設計のため、頻度を上げる（例: 毎時）と警告も同回数だけ送られる（日次運用前提）。
  EOT
  type        = string
  default     = "0 7 * * *"
}
