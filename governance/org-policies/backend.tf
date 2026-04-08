terraform {
  backend "gcs" {
    # バケット名は terraform init 時に -backend-config=backend.hcl で渡すことを想定します
  }
}
