# プロジェクトID
variable "project_id" {
  description = "プロジェクトID"
}

# 組織ID
variable "org_id" {
  description = "組織ID（組織がない場合は空欄でも可）"
  default     = ""
}

# 組織レベルの機能（SCC通知や組織ログ集約）を使用するかどうか
variable "use_org_level" {
  description = "組織レベルの機能を使用する場合はtrue、プロジェクト単位の場合はfalse"
  type        = bool
  default     = true
}

# 請求先アカウントID
variable "billing_account_id" {
  description = "請求先アカウントID"
}

# 環境名 (prd, stg, dev など)
variable "env" {
  description = "環境名"
  type        = string
}

# デフォルトリージョン
variable "region" {
  description = "デフォルトのリソース作成場所"
  type        = string
  default     = "asia-northeast1"
}

# 予算額
variable "budget_amount" {
  description = "予算監視のしきい値（円）"
  type        = number
  default     = 10000
}

variable "sandbox_budget_amount" {
  description = "サンドボックスプロジェクトの一律予算額（日本円）"
  type        = number
  default     = 5000
}

variable "audit_schedule" {
  description = "セキュリティ監査の実行スケジュール (Cron 形式)。毎日実行する場合は '0 9 * * *' などを指定します。"
  type        = string
  default     = "0 9 * * 1"
}

# 通貨
variable "currency" {
  description = "通貨コード"
  type        = string
  default     = "JPY"
}

# ログ保持期間
variable "log_retention_days" {
  description = "監査ログを保持する日数"
  type        = number
  default     = 400
}

# 新しく作成するアプリケーションのベース名
variable "app_base_name" {
  description = "新しく作成するアプリケーションの名前（プロジェクトIDの一部になります）"
  type        = string
}

# GitHub Actions 連携設定
variable "gh_org_name" {
  description = "信頼するGitHubの組織名またはユーザー名"
  type        = string
}

# 基盤管理者のグループメールアドレス（属人化防止）
variable "admin_group_email" {
  description = "GCP基盤を管理するGoogleグループのメールアドレス（例: gcp-admins@example.com）"
  type        = string
}

# プロジェクトの責任者ラベル（ガバナンス強化）
variable "project_owner" {
  description = "プロジェクトの責任者名または部署名（ラベルとして付与されます）"
  type        = string
}

# 【ガバナンス】WIFでの成り代わりを許可するリポジトリのリスト
variable "allowed_gh_repositories" {
  description = "GitHub Actions からのアクセスを許可するリポジトリ名のリスト"
  type        = list(string)
}

# ソースコードの場所（フォルダ名の変更に対応）
variable "source_dir" {
  description = "通知ロボットのソースコードが入っているディレクトリ名"
  type        = string
  default = "./billing_notifier"
}

# セキュリティレベルの設定 (standard or high)
variable "security_level" {
  description = "セキュリティの強度設定。high にすると組織ポリシー等で強力に制限されます。"
  type        = string
  default     = "standard"
}

# Slack通知用のシークレット名
variable "slack_secret_name" {
  description = "SlackのWebhook URLを格納しているSecret Managerのシークレット名"
  type        = string
  default     = "infra-ops-slack-webhook"
}

# 予算アラート通知用のシークレット名
variable "billing_slack_secret_name" {
  description = "予算アラート通知用の Slack Webhook URL を格納している Secret Manager のシークレット名"
  type        = string
  default     = "infra-billing-slack-webhook"
}

# サンドボックス削除予告用のシークレット名
variable "sandbox_slack_secret_name" {
  description = "サンドボックス削除予告用の Slack Webhook URL を格納している Secret Manager のシークレット名"
  type        = string
  default     = "infra-sandbox-slack-webhook"
}

# インフラデプロイ通知用のシークレット名
variable "infra_slack_secret_name" {
  description = "インフラデプロイ完了通知用の Slack Webhook URL を格納している Secret Manager のシークレット名"
  type        = string
  default     = "infra-deploy-slack-webhook"
}

variable "enable_ai_summary" {
  description = "Gemini による AI 要約を有効にするかどうか"
  type        = bool
  default     = true
}

# 管理リポジトリ名
variable "gh_repo_name" {
  description = "基盤管理用リポジトリ名"
  type        = string
  default     = "gcp-base"
}

# ---------------------------------------------------------------
# 監視 & アラート設定
# ---------------------------------------------------------------
variable "monitoring_targets" {
  description = "死活監視対象の名称とホスト名のマップ"
  type        = map(string)
  default     = {}
}

variable "monitoring_slack_secret_name" {
  description = "監視アラート通知用 Slack Bot トークンを格納しているシークレット名"
  type        = string
  default     = "infra-monitoring-slack-token"
}

variable "monitoring_slack_channel" {
  description = "監視アラート通知先 Slack チャンネル名"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------
# セキュリティ & 統制設定
# ---------------------------------------------------------------
variable "enable_budget_pubsub" {
  description = "予算アラートのPub/Sub通知を有効にするか。初回構築時はfalseにし、SA生成後にtrueにします。"
  type        = bool
  default     = false
}
