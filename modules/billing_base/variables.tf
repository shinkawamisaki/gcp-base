variable "project_id" {
  description = "プロジェクトID"
}

variable "org_id" {
  description = "組織ID（請求サービスエージェントの特定に使用）"
  type        = string
}

variable "billing_account_id" {
  description = "お支払いアカウントID"
}

variable "env" {
  description = "環境名"
}

variable "region" {
  description = "リージョン"
}

variable "budget_amount" {
  description = "予算額"
}

variable "currency" {
  description = "通貨"
}

variable "app_base_name" {
  description = "アプリケーションのベース名"
}

variable "slack_secret_name" {
  description = "予算アラート通知用の Slack Webhook URL を格納している Secret Manager のシークレット名"
  type        = string
  default     = "infra-billing-slack-webhook"
}
