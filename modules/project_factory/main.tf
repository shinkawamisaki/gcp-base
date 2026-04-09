# ===============================================================
# 0. 準備: プロジェクトIDの衝突を避けるためのランダムサフィックス
# ===============================================================
resource "random_id" "suffix" {
  byte_length = 2
}

# ===============================================================
# 1. プロジェクト本体の作成
# ===============================================================
resource "google_project" "apps" {
  for_each        = toset(var.environments)
  name            = "${var.app_base_name}-${each.key}"
  project_id      = "${each.key}-${var.app_base_name}-${random_id.suffix.hex}"
  folder_id       = var.folder_id
  billing_account = var.billing_account_id
  
  labels = merge(var.common_labels, {
    env      = each.key
    managed  = var.is_sandbox ? "terraform-sandbox" : "terraform-project-factory"
    app_base = var.app_base_name
  })

  # サンドボックスの場合は削除を許可、それ以外は Lien で保護
  deletion_policy = var.deletion_policy
}

# ===============================================================
# 2. サービスアカウントの作成 (各プロジェクトの管理者 SA)
# ===============================================================
resource "google_service_account" "manager_sas" {
  for_each     = google_project.apps
  project      = each.value.project_id
  account_id   = "${each.key}-manager-sa"
  display_name = "[${each.key}] Project Manager SA"
}

# ===============================================================
# 3. 必要な API の有効化
# ===============================================================
resource "google_project_service" "app_apis" {
  for_each = {
    for pair in flatten([
      for env in var.environments : [
        for api in var.default_apis : {
          env = env
          api = api
        }
      ]
    ]) : "${pair.env}-${pair.api}" => pair
  }

  project = google_project.apps[each.value.env].project_id
  service = each.value.api
  disable_on_destroy = false
}

# 【重要】プロジェクト作成（請求紐付け）が完全に伝搬されるのを待ちます (120s)
resource "time_sleep" "wait_for_project_billing" {
  for_each        = google_project.apps
  depends_on      = [google_project.apps]
  create_duration = "120s"
}

# API 反映待ち (初回作成時は IAM 設定失敗を防ぐためさらに 180秒待機)
resource "time_sleep" "wait_for_project_init" {
  for_each        = google_project.apps
  depends_on      = [google_project_service.app_apis, time_sleep.wait_for_project_billing]
  create_duration = "180s"
}

# ===============================================================
# 4. 予算管理・通知設定
# ===============================================================

# 5-1. 個別プロジェクト予算の監視
resource "google_billing_budget" "budget" {
  for_each        = google_project.apps
  billing_account = var.billing_account_id
  display_name    = "Project Budget: ${google_project.apps[each.key].project_id}"

  budget_filter {
    # プロジェクト作成が完全に終わってから着手させるためにリソースから参照
    projects = ["projects/${google_project.apps[each.key].number}"]
  }

  amount {
    specified_amount {
      currency_code = "JPY"
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  # Pub/Sub 通知の動的設定
  dynamic "all_updates_rule" {
    for_each = var.enable_budget_pubsub ? [1] : []
    content {
      pubsub_topic = var.billing_alert_topic
    }
  }

  # プロジェクト紐付け完了の待機タイマーを待ってから予算を作る
  depends_on = [
    time_sleep.wait_for_project_billing,
    time_sleep.wait_for_project_init
  ]
}

# (中略: 5 以降は変更なし)

# 5-3. 最小権限の付与 (Manager SA)
resource "google_project_iam_member" "manager_sa_privilege" {
  for_each = google_project.apps
  project  = each.value.project_id
  # 【設計思想】検証環境(stg/audit)は開発効率のため Editor、本番(prd)は事故防止のため Viewer を付与
  role     = (each.key == "prd") ? "roles/viewer" : "roles/editor"
  member   = "serviceAccount:${google_service_account.manager_sas[each.key].email}"
}

# 5-4. WIF 連携の設定 (リポジトリ完全一致による最小権限)
resource "google_service_account_iam_member" "wif_binding" {
  for_each           = google_project.apps
  service_account_id = google_service_account.manager_sas[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  
  # inventory.json に記載されたリポジトリ名 (org/repo) に完全一致する場合のみ許可
  member             = "principalSet://iam.googleapis.com/${var.wif_pool_name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "token_creator_binding" {
  for_each           = google_project.apps
  service_account_id = google_service_account.manager_sas[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${var.wif_pool_name}/attribute.repository/${var.github_repo}"
}

# 5-5. Runner SA へのリソース操作権限付与 (GitHub Actions 用)
locals {
  runner_roles = [
    "roles/resourcemanager.projectIamAdmin",
    "roles/resourcemanager.projectDeleter",
    "roles/compute.admin",
    "roles/storage.admin",
    "roles/pubsub.admin",
    "roles/cloudfunctions.admin",
    "roles/cloudfunctions.viewer",
    "roles/run.admin",
    "roles/cloudscheduler.admin",
    "roles/monitoring.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser"
  ]

  project_runner_roles = flatten([
    for proj_key, proj in google_project.apps : [
      for role in local.runner_roles : {
        project_id = proj.project_id
        role       = role
        key        = "${proj_key}-${role}"
      }
    ]
  ])
}

resource "google_project_iam_member" "runner_project_privilege" {
  for_each = { for pr in local.project_runner_roles : pr.key => pr }

  project = each.value.project_id
  role    = each.value.role
  member  = "serviceAccount:${var.terraform_runner_email}"
}

# 5-6. Cloud Build サービスエージェントへのデプロイ権限付与
resource "google_project_service_identity" "cloudbuild_sa" {
  for_each = google_project.apps
  provider = google-beta
  project  = each.value.project_id
  service  = "cloudbuild.googleapis.com"
}

resource "google_project_iam_member" "build_capabilities" {
  for_each = {
    for pair in flatten([
      for pj_key, pj in google_project.apps : [
        for role in ["roles/logging.logWriter", "roles/artifactregistry.admin", "roles/cloudfunctions.admin", "roles/run.admin"] : {
          pj_key = pj_key
          pj_id  = pj.project_id
          role   = role
        }
      ]
    ]) : "${pair.pj_key}-cb-${pair.role}" => pair
  }

  project = each.value.pj_id
  role    = each.value.role
  member  = "serviceAccount:${var.admin_project_number}@cloudbuild.gserviceaccount.com"

  depends_on = [google_project_service_identity.cloudbuild_sa]
}

# 5-7. 誤削除防止ロック (本番・検証用)
resource "google_resource_manager_lien" "project_lock" {
  for_each     = { for k, v in google_project.apps : k => v if var.is_sandbox == false }
  parent       = "projects/${each.value.number}"
  restrictions = ["resourcemanager.projects.delete"]
  origin       = "terraform-project-factory"
  reason       = "Mission-critical project protected by Enterprise Governance Policy."
  depends_on   = [time_sleep.wait_for_project_init]
}
