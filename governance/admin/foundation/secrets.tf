# ===============================================================
# Secrets for Cloud Build & AI Verifier
# ===============================================================

# GitHub PR Reviewer Token
# Cloud BuildがPRに自動コメントを行うためのパーソナルアクセストークン
resource "google_secret_manager_secret" "github_token_pr_reviewer" {
  project   = var.project_id
  secret_id = "github-token-pr-reviewer"

  replication {
    auto {}
  }
}

# Datadog API Key
# AI検閲結果のメトリクスやログをDatadogへ送信するためのAPIキー
resource "google_secret_manager_secret" "datadog_api_key" {
  project   = var.project_id
  secret_id = "infra-datadog-api-key"

  replication {
    auto {}
  }
}
