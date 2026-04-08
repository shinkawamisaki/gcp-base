# ===============================================================
# GitHub Actions 用 Workload Identity Federation (WIF) 設定
# ===============================================================

# 【卵とにわとり問題の解決】
# bootstrap.sh で作成済みの Identity Pool と Provider を「参照 (data)」します。
# これにより Terraform が重複作成でエラーを吐くのを防ぎます。

data "google_iam_workload_identity_pool" "gh_pool" {
  workload_identity_pool_id = "gh-actions-pool"
  project                   = var.project_id
}

data "google_iam_workload_identity_pool_provider" "gh_provider" {
  workload_identity_pool_id          = data.google_iam_workload_identity_pool.gh_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "gh-provider"
  project                            = var.project_id
}

# 3. サービスアカウント（Runner SA）への紐付け
# ここは「動的に変更（許可リポジトリの追加）」したいため、resource として管理します
resource "google_service_account_iam_member" "wif_runner_binding" {
  for_each           = toset(var.allowed_gh_repositories)
  service_account_id = data.google_service_account.terraform_runner.name
  role               = "roles/iam.workloadIdentityUser"
  
  # 指定されたリポジトリからのアクセスを許可
  member             = "principalSet://iam.googleapis.com/${data.google_iam_workload_identity_pool.gh_pool.name}/attribute.repository/${var.gh_org_name}/${each.value}"
}

# 出力
output "wif_provider_name" {
  value = data.google_iam_workload_identity_pool_provider.gh_provider.name
}

output "wif_pool_name" {
  value = data.google_iam_workload_identity_pool.gh_pool.name
}
