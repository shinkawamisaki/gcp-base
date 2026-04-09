# ===============================================================
# 共通変数の定義（他ファイルから local.common_labels で参照）
# ===============================================================
locals {
  common_labels = {
    env      = var.env
    managed  = "terraform"
    project  = var.project_id
  }
}
