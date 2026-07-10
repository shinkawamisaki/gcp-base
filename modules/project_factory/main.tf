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
  auto_create_network = false

  # checkov:skip=CKV_GCP_27: "auto_create_network is false"
  
  labels = merge(var.common_labels, {
    env         = each.key
    managed     = var.is_sandbox ? "terraform-sandbox" : "terraform-project-factory"
    app_base    = var.app_base_name
    expiry_date = var.expiry_date
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

  # Handover 戦略の例外（グローバル skip ではなくこのリソース限定で許容する）
  # checkov:skip=CKV_GCP_118: "roles/editor is allowed for Manager SA"
  # checkov:skip=CKV_GCP_41: "roles/editor is allowed for Manager SA"
  # checkov:skip=CKV_GCP_117: "Basic role (editor/viewer) is the documented Handover design for Manager SA (judgments.md)"
  # checkov:skip=CKV_GCP_49: "Manager SA role grant is intentional per Handover strategy (judgments.md)"
}

# 5-3b. Manager SA 追加権限: editor に無い「*.setIamPolicy と Firestore 作成」だけを
#       外科的に補う最小カスタムロール（実アプリの deploy に必須・sample-app では露見せず）。
#   - 背景: roles/editor は resource/project の setIamPolicy と datastore.databases.create を
#     持たない。そのため Cloud Functions の invoker(allUsers)付与・Pub/Sub publisher付与・
#     secret/SA/bucket の IAM 設定・Firestore(default) 作成が deploy 時に 403 になる。
#   - 最小権限: 広い *.admin ロールを積むのではなく、欠けている権限だけを列挙したカスタムロール。
#   - 職務分掌: prd は Runner SA が deploy するため付与しない（非prd=manager-sa deploy のみ）。
#     付与しても影響範囲は各アプリの「自プロジェクト内」に限定される。
# Runner SA が custom role を作るには iam.roles.create が要る（projectIamAdmin は binding 管理のみ）。
# 下の runner_roles に roles/iam.roleAdmin を足した上で、その付与の伝播を待ってから作成する
# （同一 apply 内で自分に付けた権限は即時には効かないため）。
resource "time_sleep" "wait_for_runner_role_admin" {
  depends_on      = [google_project_iam_member.runner_project_privilege]
  create_duration = "90s"
}

resource "google_project_iam_custom_role" "app_deployer" {
  depends_on  = [time_sleep.wait_for_runner_role_admin]
  for_each    = { for k, v in google_project.apps : k => v if k != "prd" }
  project     = each.value.project_id
  role_id     = "appDeployer"
  title       = "App Deployer (Factory)"
  description = "editor に無い *.setIamPolicy と datastore.databases.create のみを補う最小デプロイ用ロール"
  permissions = [
    "resourcemanager.projects.getIamPolicy",
    "resourcemanager.projects.setIamPolicy",
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.setIamPolicy",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "cloudfunctions.functions.getIamPolicy",
    "cloudfunctions.functions.setIamPolicy",
    "pubsub.topics.getIamPolicy",
    "pubsub.topics.setIamPolicy",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
    "datastore.databases.create",
    "datastore.databases.get",
    "datastore.databases.list",
    # Firestore(default) 作成は長時間オペレーション(LRO)。provider が完了を poll するため operations 権限が要る。
    "datastore.operations.get",
    "datastore.operations.list",
  ]
}

resource "google_project_iam_member" "manager_sa_deployer" {
  for_each = google_project_iam_custom_role.app_deployer
  project  = google_project.apps[each.key].project_id
  role     = each.value.id
  member   = "serviceAccount:${google_service_account.manager_sas[each.key].email}"
}

# 5-3c. Manager SA へ tfstate バケットの「自アプリ prefix 限定」アクセス（terraform init 用）。
#   - editor はバケットアクセスを含まないため manager-sa は init が 403 になる。
#   - 共有 tfstate バケットへフルアクセスさせると他アプリ/foundation の state が
#     読めてしまうため、IAM 条件で terraform/state/<app_base_name>/ 配下だけに絞る。
#   - 注意: objects.list はオブジェクト名条件(resource.name)では許可できない（バケット単位で判定）。
#     そのため list 用に objectListPrefix リクエスト属性の節を OR で併記する（両方揃って init が通る）。
resource "google_storage_bucket_iam_member" "manager_sa_state_access" {
  # admin_project_id 未指定（例: sandbox 呼び出し）の時は tfstate バケット名を組み立てられないため付与しない。
  for_each = var.admin_project_id != "" ? google_project_iam_custom_role.app_deployer : {}
  bucket   = "${var.admin_project_id}-tfstate"
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.manager_sas[each.key].email}"
  condition {
    title       = "AppStateOnly-${each.key}-${var.app_base_name}"
    description = "自アプリ(${var.app_base_name})の state prefix のみ許可（list は objectListPrefix / object は resource.name）"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.admin_project_id}-tfstate/objects/terraform/state/${var.app_base_name}/\") || api.getAttribute(\"storage.googleapis.com/objectListPrefix\", \"\").startsWith(\"terraform/state/${var.app_base_name}/\")"
  }
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
    "roles/iam.serviceAccountUser",
    # factory が app-deployer カスタムロールを各 app PJ に「作る」ため、Runner SA に
    # ロール定義権限を付与する（projectIamAdmin は binding 管理のみでロール定義は作れない）。
    # ※ prd 経路(Runner SA が deploy)の secret IAM / Firestore 作成の権限補完は、
    #   secretmanager.admin(=値読取内包)/datastore.owner(=データ平面)が過剰なため、
    #   prd cutover 時に最小カスタムロール化して別途対応する（今回は非prd=manager-sa 経路に集中）。
    "roles/iam.roleAdmin"
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
