#プロジェクトID
variable "project_id" {
  description = "プロジェクトID"
}

#組織ID
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

#お支払いアカウントID
variable "billing_account_id" {
  description = "お支払いアカウントID"
}

#環境名
variable "env" {
  description = "環境名"
  default     = "prd"
}
# リージョン
variable "region" {
  description = "デプロイ先のリージョン"
  default     = "asia-northeast1"
}

# 予算額の固定
variable "budget_amount" {
  description = "監視する予算の閾値（円）"
  default     = 10000
}

# 通貨設定（他社展開・海外対応用）
variable "currency" {
  description = "使用する通貨（例: JPY, USD）"
  type        = string
  default     = "JPY"
}

# ログ保存期間（各社のコンプライアンス規定用）
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

# ソースコードの場所（フォルダ名の変更に対応）
variable "source_dir" {
  description = "通知ロボットのソースコードが入っているディレクトリ名"
  type        = string
  default     = "billing_notifier"
}

# 追加で有効にしたいAPIのリスト
variable "extra_apis" {
  description = "基本セット以外に有効化したいAPIのリスト"
  type        = list(string)
  default     = []
}