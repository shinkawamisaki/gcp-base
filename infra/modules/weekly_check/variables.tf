# ===============================================================
# Weekly Check Module: Variables
# ===============================================================

variable "project_id" {
  description = "監査プログラムを実行するプロジェクトID"
  type        = string
}

variable "admin_project_id" {
  description = "管理用（Admin）プロジェクトID"
  type        = string
}

variable "org_id" {
  description = "GCP 組織 ID"
  type        = string
}

variable "scan_folder_ids" {
  description = "スキャン対象となるフォルダIDのリスト (例: ['folders/123', 'folders/456'])"
  type        = list(string)
}

variable "app_name" {
  description = "アプリケーションのベース名"
  type        = string
}

variable "region" {
  description = "デプロイ先のリージョン"
  type        = string
}

variable "gh_org_name" {
  description = "GitHub の組織名またはオーナー名"
  type        = string
}

variable "gh_repo_name" {
  description = "GitHub のリポジトリ名"
  type        = string
}

variable "enable_ai_summary" {
  description = "Gemini による AI 要約を有効にするかどうか"
  type        = bool
  default     = true
}

variable "slack_secret_name" {
  description = "Slack 通知 URL を格納しているシークレット名"
  type        = string
}

# Vertex AI 経由で Gemini を呼ぶため、API キー（Secret Manager）は不要になった。
# 認証は監査 SA の ADC（IAM: roles/aiplatform.user）で行う。
variable "vertex_location" {
  description = "Vertex AI のロケーション（Gemini 呼び出し先リージョン）。Vertex 対応リージョンを指定すること（例: asia-northeast1）"
  type        = string
  default     = "asia-northeast1"
}

variable "gemini_model" {
  description = "AI 要約に使用する Gemini モデル ID"
  type        = string
  default     = "gemini-2.5-flash"
}

variable "sandbox_slack_secret_name" {
  description = "サンドボックス用 Slack 通知 URL を格納しているシークレット名"
  type        = string
}

variable "audit_schedule" {
  description = "監査の実行スケジュール (Cron 形式)。毎日実行する場合は '0 9 * * *' などを指定します。"
  type        = string
  default     = "0 9 * * 1"
}

variable "gcp_console_storage_url_template" {
  description = "GCSブラウザのURLテンプレート"
  type        = string
  default     = "https://console.cloud.google.com/storage/browser/_details/{bucket}/{filename}?project={project_id}"
}
