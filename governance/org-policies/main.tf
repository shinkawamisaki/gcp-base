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

# 3. サービスアカウントキーの作成禁止（組織レベル）
# 本基盤は WIF による完全鍵レス運用（リポジトリ内に google_service_account_key はゼロ）。
# このポリシーにより「手動での SA キー発行」という鍵レス設計の唯一の抜け道を
# 組織レベルで封鎖し、設計を不可逆な統制に昇格させる。
# 長命クレデンシャルの排除は PII 取扱・IPO 監査（アクセス経路の説明責任）の基本要件。
# 例外が必要になった場合は、フォルダ単位の override で限定的に許可すること。
#
# 注: 組織側に既存ポリシーがあると初回 apply で 409 (Already Exists) になる場合がある。
# その場合は README の手順に従い `terraform import` で既存ポリシーを state に取り込むこと。
resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# 3-2. サービスアカウントキーのアップロード禁止（組織レベル）
# 作成禁止だけでは「外部で生成した鍵ペアの公開鍵を持ち込む」経路が残るため、
# アップロードも併せて遮断して初めて鍵レスが完結する。
resource "google_org_policy_policy" "disable_sa_key_upload" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyUpload"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# 4. 監査ログ（データアクセスログ）の所有権について
#
# 組織監査ログ（google_organization_iam_audit_config）は、この org-policies 領域では
# 宣言しない。foundation/security_base（Runner SA 管轄）で一元管理する。
# 理由: 本リソースは (組織,サービス) ごとに authoritative（上書き型）で、複数の state が
# 宣言すると取り合いになる。また org-policy SA は orgpolicy.policyAdmin のみで組織レベル
# setIamPolicy を持たず apply できない。必要権限（iam.securityAdmin）は Runner SA が
# 保有しており、foundation 側が正しい所有者。特権 SA に setIamPolicy を与えると自己昇格でき
# 職務分掌（物理隔離）を壊すため与えない。監査範囲（ADMIN_READ/DATA_READ/DATA_WRITE）は
# security_base 側で定義する。
