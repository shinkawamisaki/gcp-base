# ===============================================================
# 0. 物理座標の自動解決 - bootstrap.sh が保存したメタデータを参照
# ===============================================================

# クラウド上の共有メモリ（GCS）から物理座標を取得
data "google_storage_bucket_object_content" "bootstrap_metadata" {
  bucket = "${var.project_id}-tfstate"
  name   = "bootstrap_metadata.json"
}

locals {
  meta = jsondecode(data.google_storage_bucket_object_content.bootstrap_metadata.content)
  infrastructure_folder_id = local.meta.infrastructure_folder_id
  workloads_folder_id      = local.meta.workloads_folder_id
  sandbox_folder_id        = local.meta.sandbox_folder_id

  # フォルダ名（folders/数字）から数字のみを抽出
  workloads_folder_name    = element(split("/", local.workloads_folder_id), length(split("/", local.workloads_folder_id)) - 1)
  sandbox_folder_name      = element(split("/", local.sandbox_folder_id), length(split("/", local.sandbox_folder_id)) - 1)
}

# 管理プロジェクトの情報を取得
data "google_project" "admin" {
  project_id = var.project_id
}

# ===============================================================
# 1. 基盤共通サービスの構築 (監視・請求・セキュリティ)
# ===============================================================

# 1-0. 管理プロジェクトのAPI有効化
module "api_base" {
  source             = "../../../modules/api_base"
  project_id         = data.google_project.admin.project_id
  org_id             = var.org_id
  use_org_level      = var.use_org_level
  billing_account_id = var.billing_account_id
  app_base_name      = var.app_base_name
  env                = var.env
  region             = var.region
  budget_amount      = var.budget_amount
  currency           = var.currency
}

# 1-1. 料金監視・予算アラート
module "billing_base" {
  source             = "../../../modules/billing_base"
  project_id         = data.google_project.admin.project_id
  org_id             = var.org_id
  billing_account_id = var.billing_account_id
  env                = var.env
  region             = var.region
  budget_amount      = var.budget_amount
  currency           = var.currency
  app_base_name      = var.app_base_name
  slack_secret_name  = var.billing_slack_secret_name
  
  depends_on         = [module.api_base]
}

# 1-2. 外勤死活監視・ログアラート
# 注: Factory で作成されるボットのホスト名は Factory 側の State で管理されるため、
# 基盤側ではここでは管理プロジェクト自体の監視のみを行うか、Factory 完了後に更新が必要。
module "monitoring_base" {
  source             = "../../../modules/monitoring_base"
  project_id         = data.google_project.admin.project_id
  monitoring_targets = var.monitoring_targets
  slack_secret_name  = var.monitoring_slack_secret_name
  slack_channel_name = replace(var.monitoring_slack_channel, "#", "")
  
  depends_on         = [module.api_base]
}

# 1-3. セキュリティ基盤（SCC & 組織ログ）
module "security_base" {
  source             = "../../../modules/security_base"
  project_id         = data.google_project.admin.project_id
  org_id             = var.org_id
  billing_account_id = var.billing_account_id
  app_base_name      = var.app_base_name
  use_org_level      = var.use_org_level
  env                = var.env
  region             = var.region
  
  depends_on         = [module.api_base]
}

# ===============================================================
# 4. シークレット & 権限管理 (GitHub Actions 用)
# ===============================================================

data "google_secret_manager_secret" "required_secrets" {
  for_each  = toset([
    var.slack_secret_name,
    var.infra_slack_secret_name,
    var.billing_slack_secret_name,
    var.sandbox_slack_secret_name,
    var.monitoring_slack_secret_name,
    "infra-gemini-api-key"
  ])
  project   = data.google_project.admin.project_id
  secret_id = each.value
}

# GitHub Actions が監視用トークンを読み取れるようにします
resource "google_secret_manager_secret_iam_member" "runner_monitoring_slack_accessor" {
  project   = data.google_project.admin.project_id
  secret_id = data.google_secret_manager_secret.required_secrets[var.monitoring_slack_secret_name].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_service_account.terraform_runner.email}"
}

# GitHub Actions が Gemini API キーを読み取れるようにします
resource "google_secret_manager_secret_iam_member" "runner_gemini_accessor" {
  project   = data.google_project.admin.project_id
  secret_id = data.google_secret_manager_secret.required_secrets["infra-gemini-api-key"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_service_account.terraform_runner.email}"
}

# GitHub Actions が予算通知用 Webhook URL を読み取れるようにします (403 エラー対策)
resource "google_secret_manager_secret_iam_member" "runner_billing_slack_accessor" {
  project   = data.google_project.admin.project_id
  secret_id = data.google_secret_manager_secret.required_secrets[var.billing_slack_secret_name].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_service_account.terraform_runner.email}"
}

# Runner SA が予算を作成・管理できるように、請求アカウントへの権限を付与します
resource "google_billing_account_iam_member" "runner_costs_manager" {
  billing_account_id = var.billing_account_id
  role               = "roles/billing.costsManager"
  member             = "serviceAccount:${data.google_service_account.terraform_runner.email}"
}

# アプリケーションデプロイ用: prd- から始まるシークレットへのアクセスを動的に許可 (IAM Condition)
resource "google_project_iam_member" "runner_prd_secret_accessor" {
  project = data.google_project.admin.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${data.google_service_account.terraform_runner.email}"

  condition {
    title       = "AllowAccessToPrdAndInfraSecrets"
    description = "Runner SA can access secrets starting with prd- or infra- prefix"
    expression  = "resource.name.startsWith(\"projects/${data.google_project.admin.number}/secrets/prd-\") || resource.name.startsWith(\"projects/${data.google_project.admin.number}/secrets/infra-\")"
  }
}

# ===============================================================
# 5. 組織レベルのガバナンス設定
# ===============================================================
resource "google_organization_policy" "restrict_locations" {
  count      = var.security_level == "high" ? 1 : 0
  org_id     = var.org_id
  constraint = "constraints/gcp.resourceLocations"

  list_policy {
    allow {
      values = ["in:asia-northeast1-locations", "in:asia-northeast2-locations"]
    }
  }
}

# ===============================================================
# Outputs (Factory で使用するためにエクスポート)
# ===============================================================

output "admin_project_number" {
  value = data.google_project.admin.number
}

output "workloads_folder_name" {
  value = local.workloads_folder_name
}

output "sandbox_folder_name" {
  value = local.sandbox_folder_name
}

output "budget_notification_topic_id" {
  value = module.billing_base.budget_notification_topic_id
}
