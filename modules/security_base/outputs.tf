output "audit_logs_bucket_name" {
  description = "監査ログを保存しているGCSバケット名"
  value       = google_storage_bucket.audit_logs_archive.name
}
