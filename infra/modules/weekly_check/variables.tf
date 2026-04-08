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

variable "gemini_api_key_secret_name" {
  description = "Gemini API キーを格納しているシークレット名"
  type        = string
  default     = "infra-gemini-api-key"
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
