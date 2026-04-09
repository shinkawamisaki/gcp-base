# ===============================================================
# 0. 依存関係の解決 - Foundation State から情報を取得
# ===============================================================

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "${var.project_id}-tfstate"
    prefix = "terraform/admin/foundation/state"
  }
}

locals {
  admin_project_number         = data.terraform_remote_state.foundation.outputs.admin_project_number
  wif_pool_name                = data.terraform_remote_state.foundation.outputs.wif_pool_name
  workloads_folder_name        = data.terraform_remote_state.foundation.outputs.workloads_folder_name
  sandbox_folder_name          = data.terraform_remote_state.foundation.outputs.sandbox_folder_name
  budget_notification_topic_id = data.terraform_remote_state.foundation.outputs.budget_notification_topic_id
}

# 1. サービスアカウントの参照
data "google_service_account" "terraform_runner" {
  account_id = "prd-terraform-runner-sa"
  project    = var.project_id
}

# 2. プロジェクト台帳 (inventory.json) の読み込み
locals {
  inventory = jsondecode(file("${path.module}/inventory.json"))
}

# 管理プロジェクトの情報を取得
data "google_project" "admin" {
  project_id = var.project_id
}

# ===============================================================
# 2. アプリケーション・サンドボックスの払い出し (Project Factory)
# ===============================================================

# A. 通常アプリケーションプロジェクト
module "project_factory_apps" {
  for_each           = local.inventory.apps
  source             = "../../../modules/project_factory"
  folder_id          = local.workloads_folder_name
  org_id             = var.org_id
  billing_account_id = var.billing_account_id
  app_base_name      = each.key
  environments       = each.value.environments
  deletion_policy    = var.deletion_policy
  admin_project_number = local.admin_project_number
  wif_pool_name      = local.wif_pool_name
  github_repo        = each.value.github_repo
  common_labels      = { owner = var.project_owner }
  admin_project_id   = data.google_project.admin.project_id
  
  budget_amount      = lookup(each.value, "budget_amount", var.budget_amount)
  owner_email        = var.admin_group_email
  is_sandbox         = false
  terraform_runner_email = data.google_service_account.terraform_runner.email
  
  # Pub/Sub 連携設定
  billing_alert_topic  = local.budget_notification_topic_id
  enable_budget_pubsub = var.enable_budget_pubsub
}

# B. サンドボックス用プロジェクト
module "project_factory_sandboxes" {
  for_each           = local.inventory.sandboxes
  source             = "../../../modules/project_factory"
  folder_id          = local.sandbox_folder_name
  org_id             = var.org_id
  billing_account_id = var.billing_account_id
  app_base_name      = each.key
  environments       = ["dev"]
  deletion_policy    = "DELETE"
  common_labels      = { owner = var.project_owner }
  admin_project_number = local.admin_project_number
  wif_pool_name      = local.wif_pool_name
  github_repo        = each.value.github_repo

  owner_email        = lookup(each.value, "owner_email", var.admin_group_email)
  is_sandbox         = true

  budget_amount      = lookup(each.value, "budget_amount", var.sandbox_budget_amount)
  terraform_runner_email = data.google_service_account.terraform_runner.email

  # Pub/Sub 連携設定
  billing_alert_topic  = local.budget_notification_topic_id
  enable_budget_pubsub = var.enable_budget_pubsub
}

# ===============================================================
# 3. インフラ・自動化 (週次監査・ライフサイクル)
# ===============================================================

locals {
  audit_host_pj = [for k, v in local.inventory.apps : module.project_factory_apps[k].project_ids["audit"] if lookup(v, "is_audit_host", false)][0]
}

# 3-1. 週次セキュリティ監査 (Gemini 版)
module "weekly_check" {
  source             = "../../../infra/modules/weekly_check"
  project_id         = local.audit_host_pj
  admin_project_id   = data.google_project.admin.project_id
  org_id             = var.org_id
  scan_folder_ids    = [
    "folders/${local.workloads_folder_name}",
    "folders/${local.sandbox_folder_name}"
  ]
  app_name           = var.app_base_name
  region             = var.region
  gh_org_name        = var.gh_org_name
  gh_repo_name       = var.gh_repo_name
  enable_ai_summary  = var.enable_ai_summary
  slack_secret_name  = var.slack_secret_name
  sandbox_slack_secret_name = var.sandbox_slack_secret_name
  audit_schedule     = var.audit_schedule
  
  depends_on         = [module.project_factory_apps]
}

# 3-2. サンドボックス・ライフサイクル管理
module "sandbox_lifecycle" {
  source             = "../../../infra/modules/sandbox_lifecycle"
  project_id         = local.audit_host_pj
  region             = var.region
  admin_project_id   = data.google_project.admin.project_id
  scan_folder_id     = "folders/${local.sandbox_folder_name}"
  sandbox_slack_secret_name = var.sandbox_slack_secret_name
  gh_org_name        = var.gh_org_name
  gh_repo_name       = var.gh_repo_name
  github_token_secret_name = "infra-github-token"
  
  depends_on         = [module.project_factory_apps]
}

output "created_project_ids" {
  value = {
    apps      = { for k, v in module.project_factory_apps : k => v.project_ids }
    sandboxes = { for k, v in module.project_factory_sandboxes : k => v.project_ids["dev"] }
  }
}

output "weekly_check_host" {
  value = module.weekly_check.host_name
}

output "lifecycle_bot_host" {
  value = module.sandbox_lifecycle.host_name
}
