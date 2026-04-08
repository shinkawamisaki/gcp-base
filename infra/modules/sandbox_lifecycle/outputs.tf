output "function_uri" {
  description = "ライフサイクル関数の URI"
  value       = google_cloudfunctions2_function.lifecycle_func.service_config[0].uri
}

output "host_name" {
  description = "監視に使用するホスト名"
  value       = replace(google_cloudfunctions2_function.lifecycle_func.service_config[0].uri, "https://", "")
}
