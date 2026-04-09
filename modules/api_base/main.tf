# ===============================================================
# プロジェクト全体の基盤設定（API有効化の一元管理）
# ===============================================================

# 1. 有効化するAPIのリスト
locals {
  activate_apis = [
    "securitycenter.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "pubsub.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "cloudbilling.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
  ]
}

# 2. リストにあるAPIをループで一括有効化
resource "google_project_service" "apis" {
  for_each = toset(concat(local.activate_apis, var.extra_apis))

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 【最重要】Billing Budget API は有効化から「実際に予算を作成できるまで」に
# Google 内部で数分の伝播ラグが発生します。
# OSS として初見の環境でも 100% 成功させるため、ここでは 300秒（5分）の待機を強制します。
resource "time_sleep" "wait_for_apis" {
  depends_on      = [google_project_service.apis]
  create_duration = "120s"
}

# 後続モジュールが依存するためのダミー出力
output "api_ready" {
  value      = time_sleep.wait_for_apis.id
  depends_on = [time_sleep.wait_for_apis]
}
