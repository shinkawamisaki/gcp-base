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

# 【許可リポジトリの単一真実源 = 台帳(inventory.json)】
# ハードコード排除(.clinerules 3「全リソース定義は inventory.json に集約」)のため、
# 許可リストをワークフロー直書きではなく factory の台帳から導出する。
# factory が払い出す各アプリのリポを、prd デプロイの Handover 先である
# 中央 Runner SA へ自動で WIF 許可する（台帳にアプリを足せば自動認可＝
# 新アプリで prd デプロイが getAccessToken 403 になるのを繰り返さない）。
locals {
  app_inventory = jsondecode(file("${path.module}/../factory/inventory.json"))
  # github_repo は "org/repo" 形式。WIF member 側で org を別途付与するため repo 名(basename)のみ取る。
  app_repos = [for a in local.app_inventory.apps : split("/", a.github_repo)[1]]
  # admin 自身のリポ（ワークフロー注入値）とアプリ台帳を結合し重複排除。
  allowed_repos = distinct(concat(var.allowed_gh_repositories, local.app_repos))
}

# 3. サービスアカウント（Runner SA）への紐付け
# ここは「動的に変更（許可リポジトリの追加）」したいため、resource として管理します
resource "google_service_account_iam_member" "wif_runner_binding" {
  for_each           = toset(local.allowed_repos)
  service_account_id = data.google_service_account.terraform_runner.name
  role               = "roles/iam.workloadIdentityUser"

  # 指定されたリポジトリからのアクセスを許可
  member = "principalSet://iam.googleapis.com/${data.google_iam_workload_identity_pool.gh_pool.name}/attribute.repository/${var.gh_org_name}/${each.value}"
}

# 出力
output "wif_provider_name" {
  value = data.google_iam_workload_identity_pool_provider.gh_provider.name
}

output "wif_pool_name" {
  value = data.google_iam_workload_identity_pool.gh_pool.name
}
