# ===============================================================
# 🏗️ サンドボックス（実験場）払い出し用 Terraform
# ===============================================================

terraform {
  # GCSバックエンドを明示的に定義 (bucket名は init 時に -backend-config で指定)
  backend "gcs" {
    prefix = "terraform/sandbox/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- 変数定義 ---
variable "project_id" {
  description = "管理用（Admin）プロジェクトID"
}

variable "region" {
  description = "デフォルトリージョン"
  default     = "asia-northeast1"
}

variable "sandbox_id" {
  description = "サンドボックスの識別名"
}

variable "owner" {
  description = "所有者名"
}

variable "expiry_date" {
  description = "有効期限 (YYYY-MM-DD)"

  validation {
    # YYYY-MM-DD 形式に一致するかを正規表現でチェック
    condition     = can(regex("^20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$", var.expiry_date))
    error_message = "The expiry_date must be in YYYY-MM-DD format."
  }
}

variable "budget_amount" {
  description = "サンドボックスの月額予算"
  type        = number
  default     = 5000
}

# 管理プロジェクトのプロジェクト番号を取得 (モジュールで必要)
data "google_project" "admin" {
  project_id = var.project_id
}

# bootstrap.sh が保存したメタデータを参照
data "google_storage_bucket_object_content" "bootstrap_metadata" {
  name   = "bootstrap_metadata.json"
  bucket = "${var.project_id}-tfstate"
}

locals {
  bootstrap_meta      = jsondecode(data.google_storage_bucket_object_content.bootstrap_metadata.content)
  sandbox_folder_name = local.bootstrap_meta.sandbox_folder_id
  billing_account_id  = local.bootstrap_meta.billing_account_id
  org_id              = local.bootstrap_meta.org_id
}

# --- 1. サンドボックスプロジェクトの作成 ---
module "sandbox_project" {
  source             = "../../modules/project_factory"
  folder_id          = local.sandbox_folder_name
  org_id             = local.org_id
  billing_account_id = local.billing_account_id
  app_base_name      = "sandbox-${var.sandbox_id}"
  admin_project_number = data.google_project.admin.number
  
  # サンドボックス環境のみ作成
  environments = ["sandbox"]
  is_sandbox   = true

  # 予算設定
  budget_amount       = var.budget_amount
  billing_alert_topic = "projects/${var.project_id}/topics/admin-test-app-billing-alert-topic"

  # サンドボックス特有のラベルを刻印
  custom_labels = {
    managed     = "terraform-sandbox"
    owner       = var.owner
    expiry_date = var.expiry_date
  }

  common_labels = {
    project_type = "sandbox"
  }
}

# 2. 成果物の出力 (GitHub Actions で使用)
output "sandbox_project_id" {
  value = module.sandbox_project.project_ids["sandbox"]
}
