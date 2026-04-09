# ===============================================================
# GCP VPC ネットワーク基盤 (VPC Base)
# ===============================================================

# 1. VPC 本体の作成
resource "google_compute_network" "vpc" {
  name                    = "${var.app_name}-${var.environment}-vpc"
  auto_create_subnetworks = false
}

# 2. Subnet (サブネット)
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.app_name}-${var.environment}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
}

# 3. Cloud NAT (【コスト節約】オプションで作成)
# AWS の NAT Gateway に相当するもの。GCP ではゲートウェイ本体は安価です。
resource "google_compute_router" "router" {
  count   = var.enable_nat ? 1 : 0
  name    = "${var.app_name}-${var.environment}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  count                              = var.enable_nat ? 1 : 0
  name                               = "${var.app_name}-${var.environment}-nat"
  router                             = google_compute_router.router[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# 4. Firewall Rules (セキュリティの核心)

# Web 用: 外部からの HTTP/HTTPS のみを許可
resource "google_compute_firewall" "allow_web" {
  name    = "${var.app_name}-${var.environment}-allow-web"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  # 【セキュリティ設計】
  # 初心者向けにデフォルトは "0.0.0.0/0" (全世界) を許可していますが、
  # Series Bレベルの個人情報保護が必要な場合は、Load Balancer の IP レンジ 
  # ("130.211.0.0/22", "35.191.0.0/16") に絞ることを強く推奨します。
  source_ranges = var.web_source_ranges
  target_tags   = ["web-server"] # このタグを持つインスタンスに適用
}

# 内部通信用: VPC 内部（サブネット内）の通信を許可
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.app_name}-${var.environment}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

# DB 用: Web サーバーからのみアクセスを許可
resource "google_compute_firewall" "allow_db" {
  name    = "${var.app_name}-${var.environment}-allow-db"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["3306", "5432"] # MySQL / PostgreSQL
  }

  # source_tags を使うことで「Webサーバーからのみ」という限定が可能
  source_tags = ["web-server"]
  target_tags = ["db-server"]
}

# IAP 用: Google のプロキシ経由での SSH ログインを許可 (ポート22を直接開けずに済む)
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.app_name}-${var.environment}-allow-iap-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google Identity-Aware Proxy (IAP) の IP レンジのみ許可
  source_ranges = ["35.235.240.0/20"]
}

# --- Variables ---
variable "app_name" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "subnet_cidr" { default = "10.0.0.0/24" }
variable "enable_nat" { 
  type    = bool
  default = false 
}

variable "web_source_ranges" {
  description = "Web サーバーへのアクセスを許可する IP レンジのリスト"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
