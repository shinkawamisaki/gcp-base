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
  description = "GitHub PAT (Personal Access Token) のシークレット名"
  type        = string
  default     = "infra-github-token"
}
