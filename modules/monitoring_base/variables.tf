variable "project_id" {
  description = "監視設定を配置するプロジェクトID"
  type        = string
}

variable "monitoring_targets" {
  description = "監視対象の名称とURL（ホスト名）のマップ"
  type        = map(string)
  default     = {}
}

variable "slack_secret_name" {
  description = "Slack 通知用トークンを格納している Secret Manager のシークレット名"
  type        = string
}

variable "slack_channel_name" {
  description = "通知先の Slack チャンネル名"
  type        = string
}
