output "function_uri" {
  description = "監査関数の URI"
  value       = google_cloudfunctions2_function.weekly_audit_func.service_config[0].uri
}

output "host_name" {
  description = "監視に使用するホスト名"
  value       = replace(google_cloudfunctions2_function.weekly_audit_func.service_config[0].uri, "https://", "")
}
