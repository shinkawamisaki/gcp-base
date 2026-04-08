# ===============================================================
# 自動化・CI/CD用 サービスアカウント (職務分掌に基づく分離)
# ===============================================================

# ---------------------------------------------------------------
# 1. 通常 SA: Terraform Runner (プロジェクト/実務管理用)
# ---------------------------------------------------------------
# bootstrap.sh で作成済みの SA を「参照 (data)」します。
data "google_service_account" "terraform_runner" {
  account_id = "prd-terraform-runner-sa"
  project    = var.project_id
}

# 管理プロジェクト内での権限 (Editor & IAM Admin)
resource "google_project_iam_member" "runner_admin_privileges" {
  for_each = toset([
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${data.google_service_account.terraform_runner.email}"
}

# ---------------------------------------------------------------
# 2. 特権 SA: Org Policy Admin (組織ポリシー/ガードレール管理用)
# ---------------------------------------------------------------
resource "google_service_account" "org_policy_admin" {
  project      = var.project_id
  account_id   = "prd-org-policy-sa"
  display_name = "Organization Policy Administrator (CI/CD)"
}

# 【特権】組織レベルでのポリシー管理権限
resource "google_organization_iam_member" "org_policy_privilege" {
  org_id = var.org_id
  role   = "roles/orgpolicy.policyAdmin"
  member = "serviceAccount:${google_service_account.org_policy_admin.email}"
}

# 【最小権限】State 管理用の権限
resource "google_storage_bucket_iam_member" "org_policy_state_viewer" {
  bucket = "${var.project_id}-tfstate"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.org_policy_admin.email}"
}

resource "google_storage_bucket_iam_member" "org_policy_state_admin" {
  bucket = "${var.project_id}-tfstate"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.org_policy_admin.email}"

  condition {
    title       = "StrictOrgPolicyStateAccess"
    description = "Only allow write access to its own prefix"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.project_id}-tfstate/objects/terraform/org-policies/\")"
  }
}

# 【Quota】API 利用枠の消費許可 (組織レベルの操作に必須)
resource "google_project_iam_member" "org_policy_quota_user" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.org_policy_admin.email}"
}

# WIF 連携の設定 (deploy_governance.yml からの認証を許可)
resource "google_service_account_iam_member" "wif_binding_org" {
  service_account_id = google_service_account.org_policy_admin.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/gh-actions-pool/attribute.repository/${var.gh_org_name}/${var.gh_repo_name}"
}

# ---------------------------------------------------------------
# 3. 共通: なり代わり（Impersonate）許可
# ---------------------------------------------------------------
resource "google_service_account_iam_member" "impersonate_runner" {
  service_account_id = data.google_service_account.terraform_runner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_group_email}"
}

resource "google_service_account_iam_member" "impersonate_org" {
  service_account_id = google_service_account.org_policy_admin.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_group_email}"
}

# プロジェクト情報の取得用
data "google_project" "current" {
  project_id = var.project_id
}
