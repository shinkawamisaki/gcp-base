variable "app_base_name" {
  description = "アプリケーションのベース名"
  type        = string
}

variable "org_id" {
  description = "組織ID"
  type        = string
}

variable "billing_account_id" {
  description = "お支払いアカウントID"
  type        = string
}

variable "folder_id" {
  description = "プロジェクトを作成するフォルダのID (例: folders/12345)"
  type        = string
  default     = null
}

variable "common_labels" {
  description = "全プロジェクトに共通して付与するラベル"
  type        = map(string)
}

# 作成したい環境のデフォルトセット
variable "environments" {
  description = "作成する環境のリスト"
  type        = list(string)
  default     = ["prd", "stg"]
}

variable "deletion_policy" {
  description = "プロジェクト削除の保護設定 (DELETE, ABANDON, PREVENT)。誤削除を防ぐためにデフォルトは PREVENT です。"
  type        = string
  default     = "PREVENT"
}

# 各プロジェクトでデフォルトで有効にするAPI
variable "default_apis" {
  description = "新しく作成されるプロジェクトで自動的に有効化する API リスト"
  type        = list(string)
  default     = [
    "compute.googleapis.com",
    "storage.googleapis.com",
    "sqladmin.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "billingbudgets.googleapis.com"
  ]
}

# 追加のラベル (サンドボックス用)
variable "custom_labels" {
  description = "プロジェクトに個別に追加するラベルのマップ"
  type        = map(string)
  default     = {}
}

variable "owner_email" {
  description = "プロジェクトの所有者（開発者）のメールアドレス。Editor権限の付与に使用します。"
  type        = string
  default     = ""
}

variable "is_sandbox" {
  description = "サンドボックスプロジェクトとして作成するかどうか（ガードレールを強化します）"
  type        = bool
  default     = false
}

variable "budget_amount" {
  description = "このプロジェクトに設定する月額予算（日本円）"
  type        = number
  default     = 10000
}

variable "billing_alert_topic" {
  description = "予算アラートを送信する Pub/Sub トピックのフルパス (例: projects/my-project/topics/my-topic)"
  type        = string
  default     = ""
}

variable "admin_project_id" {
  description = "管理用（Admin）プロジェクトのID。シークレット権限の逆引き設定に使用します。"
  type        = string
  default     = ""
}

variable "admin_project_number" {
  description = "管理用（Admin）プロジェクトの番号。WIF設定のパスに使用します。"
  type        = string
  default     = ""
}

variable "wif_pool_name" {
  description = "WIF プールのフルパス名 (projects/...)"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "The GitHub repository name in 'org/repo' format (e.g., your-org/your-repo). This is used for WIF authorization."
  type        = string
  default     = ""
}
variable "gh_org_name" {
  description = "The GitHub organization or owner name. Can be used for organizational level WIF attribute conditions."
  type        = string
  default     = ""
}

variable "terraform_runner_email" {
  description = "CI/CDを実行するTerraform Runner SAのメールアドレス。継承ラグを回避するために各プロジェクトで明示的に権限を付与します。"
  type        = string
  default     = ""
}

variable "enable_budget_pubsub" {
  description = "予算アラートのPub/Sub通知を有効にするか。初回構築時はfalseにし、SA生成後にtrueにします。"
  type        = bool
  default     = false
}
