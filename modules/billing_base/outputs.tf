output "budget_notification_topic_id" {
  description = "予算アラート通知用の Pub/Sub トピック ID"
  value       = google_pubsub_topic.budget_notification_topic.id
}
