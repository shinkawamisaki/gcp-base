# ===============================================================
# Project Factory: Outputs
# ===============================================================

output "project_ids" {
  description = "作成されたプロジェクトのIDマップ"
  value       = { for k, v in google_project.apps : k => v.project_id }
}

output "project_numbers" {
  description = "作成されたプロジェクトの番号マップ"
  value       = { for k, v in google_project.apps : k => v.number }
}

output "deployment_service_accounts" {
  description = "各プロジェクトのマネージャーサービスアカウントのメールアドレス"
  value       = { for k, v in google_service_account.manager_sas : k => v.email }
}

output "handover_info" {
  description = "開発チームへの引き継ぎ用情報"
  value = {
    for env, pid in { for k, v in google_project.apps : k => v.project_id } : env => {
      project_id         = pid
      service_account    = google_service_account.manager_sas[env].email
    }
  }
}
