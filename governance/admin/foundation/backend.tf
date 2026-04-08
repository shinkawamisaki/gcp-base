terraform {
  backend "gcs" {
    # 実際の設定は terraform init -backend-config=... で動的に注入されます
    # bucket = "..."
    # prefix = "terraform/admin/foundation/state"
  }
}
