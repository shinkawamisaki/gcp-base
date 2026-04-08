provider "google" {
  # 組織レベルの操作には Quota プロジェクトの明示が必要です
  user_project_override = true
  billing_project       = var.billing_project_id
}

provider "google-beta" {
  user_project_override = true
  billing_project       = var.billing_project_id
}

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0.0"
    }
  }
}
