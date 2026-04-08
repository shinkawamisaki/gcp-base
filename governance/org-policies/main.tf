# ===============================================================
# 組織ポリシー設定 (Organization Policies) - 組織レベル
# ===============================================================

# 1. 以前のドメイン制限（レガシー制約）
# 新しいマネージド制約にガードレールを移行するため、こちらは「制限なし」にして無力化する
resource "google_org_policy_policy" "legacy_allowed_domains" {
  name   = "organizations/${var.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      allow_all = "TRUE" 
    }
  }
}

# 2. モダンなドメイン制限（マネージド制約）
# 組織のメンバーと、Googleの予算通知SA「だけ」を例外として許可し、他はすべて遮断する
resource "google_org_policy_policy" "managed_policy_members" {
  name   = "organizations/${var.org_id}/policies/iam.managed.allowedPolicyMembers"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
      parameters = jsonencode({
        allowedMemberSubjects = [
          "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
        ]
        allowedPrincipalSets = [
          "//cloudresourcemanager.googleapis.com/organizations/${var.org_id}"
        ]
      })
    }
  }
}

# 3. 監査ログ（データアクセスログ）の組織レベル有効化
# 全てをONにするとコストがかかるため、IPO審査等で重要なサービスに絞って一括有効化します
resource "google_organization_iam_audit_config" "org_audit_config" {
  for_each = toset([
    "iam.googleapis.com",           # 誰が権限を変えたか？
    "secretmanager.googleapis.com", # 誰がシークレットを見たか？
    "storage.googleapis.com"        # 誰がファイルを書き換えたか？
  ])
  org_id  = var.org_id
  service = each.value

  audit_log_config {
    log_type = "DATA_READ"  # 読み取り操作
  }
  audit_log_config {
    log_type = "DATA_WRITE" # 書き込み操作
  }
  audit_log_config {
    log_type = "ADMIN_READ" # 管理情報の読み取り
  }
}
