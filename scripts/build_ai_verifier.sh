#!/bin/bash
set -euo pipefail

# ==============================================================================
# AI検閲官イメージの ブートストラップ build & push スクリプト
#
# [目的 / なぜ必要か]
# PR 検閲用 Cloud Build（cloudbuild-pr.yaml / build.tf の pr_reviewer トリガー）は
# 起動時に infra-tools/ai-verifier:latest を pull して実行する。つまり「PR を検閲
# する Cloud Build」を動かすには、その前段で一度イメージを焼いて push しておく
# 初期化（ブートストラップ）が要る ＝ 鶏と卵。この工程がコード化されていないと、
# GCP 接続直後の最初の PR で「イメージ不在」によりビルドが pull に失敗する
# （実際に派生先で顕在化した）。本スクリプトはその工程を再現可能な形に固定する。
#
# [なぜ Cloud Build でなくローカル build か]
# イメージ焼きは PR ごとのホットパスではなく、Dockerfile / requirements.txt を
# 変更したときだけ実行する低頻度のブートストラップ操作。ここに専用 SA・logs
# バケット・追加 IAM を足すのは過剰（org policy で Cloud Build は user-managed SA
# 必須のため）。実行者の Owner / artifactregistry.writer 権限とローカル Docker で
# 完結する本スクリプトが、低頻度のブートストラップに比例した最小構成である。
# 将来「ローカル Docker 不要・完全 SA 化」が必要になったら、その時点で専用 SA と
# logs バケットを設計して Cloud Build 方式へ移行すること。
#
# [使い方]
#   ./scripts/build_ai_verifier.sh            # tfvars から PROJECT_ID/REGION を読んで build & push
#   ./scripts/build_ai_verifier.sh --dry-run  # 実行せず対象とコマンドだけ表示
#   PROJECT_ID=my-pj REGION=asia-northeast1 ./scripts/build_ai_verifier.sh  # 環境変数で上書き
#   IMAGE_TAG=v1 ./scripts/build_ai_verifier.sh   # タグを上書き（既定: latest）
# ==============================================================================

# 色の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. 実行場所に関わらずプロジェクトのルートを特定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$PROJECT_ROOT/governance/admin/terraform.tfvars"
DOCKER_CONTEXT="$PROJECT_ROOT/docker/ai-verifier"

DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage:
  scripts/build_ai_verifier.sh [options]

Options:
  --dry-run     対象とコマンドを表示するだけで build / push しない
  -y, --yes     push 前の確認プロンプトをスキップする（CI / 非対話向け）
  -h, --help    このヘルプを表示する

Env overrides:
  PROJECT_ID    GCP プロジェクトID（既定: governance/admin/terraform.tfvars から取得）
  REGION        Artifact Registry のロケーション（既定: tfvars の region、無ければ asia-northeast1）
  IMAGE_TAG     イメージタグ（既定: latest）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    -y|--yes)  ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}[Error] 不明なオプション: $1${NC}"; usage; exit 1 ;;
  esac
  shift
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}[Error] 必要なコマンドが見つかりません: $1${NC}"
    exit 1
  fi
}

# tfvars から `key = "value"` 形式の値を 1 件読む（行頭アンカーで誤マッチ防止）
read_tfvar() {
  local key="$1"
  [ -f "$TFVARS" ] || return 1
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" | head -n1 | cut -d'"' -f2
}

require_cmd docker
require_cmd gcloud

# 2. PROJECT_ID / REGION の決定（環境変数 > tfvars > 既定）
PROJECT_ID="${PROJECT_ID:-$(read_tfvar project_id || true)}"
REGION="${REGION:-$(read_tfvar region || true)}"
REGION="${REGION:-asia-northeast1}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

if [ -z "${PROJECT_ID:-}" ]; then
  echo -e "${RED}[Error] PROJECT_ID を特定できません。${NC}"
  echo -e "${YELLOW}  $TFVARS に project_id を定義するか、環境変数 PROJECT_ID で指定してください。${NC}"
  exit 1
fi

REGISTRY_HOST="${REGION}-docker.pkg.dev"
IMAGE="${REGISTRY_HOST}/${PROJECT_ID}/infra-tools/ai-verifier:${IMAGE_TAG}"

echo -e "${GREEN}>>> AI検閲官イメージのブートストラップ build & push${NC}"
echo -e "Target Project  : ${YELLOW}${PROJECT_ID}${NC}"
echo -e "Region (AR loc) : ${YELLOW}${REGION}${NC}"
echo -e "Image           : ${YELLOW}${IMAGE}${NC}"
echo -e "Build context   : ${YELLOW}${DOCKER_CONTEXT}${NC}"
echo -e "------------------------------------------------"

if [ ! -f "$DOCKER_CONTEXT/Dockerfile" ]; then
  echo -e "${RED}[Error] Dockerfile が見つかりません: $DOCKER_CONTEXT/Dockerfile${NC}"
  exit 1
fi

# build / push で実行するコマンド。
# --platform linux/amd64 : Apple Silicon 等の arm64 開発機でも、Cloud Build 実行基盤
#   （amd64）で動くイメージを焼くため明示する。これが無いと arm64 イメージが push され、
#   pull 側で "exec format error" になる。
# --provenance=false : buildx 既定の provenance/SBOM 添付が OCI image index（多アーキ
#   マニフェスト）を生成し、Artifact Registry からの単純 pull が manifest 解決でこける
#   ケースを避けるため、単一マニフェストの素のイメージとして push する。
BUILD_CMD=(docker build --provenance=false --platform linux/amd64 -t "$IMAGE" "$DOCKER_CONTEXT")
PUSH_CMD=(docker push "$IMAGE")

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}[dry-run] 以下を実行します（実際には実行しません）:${NC}"
  echo "  gcloud auth configure-docker ${REGISTRY_HOST} --quiet"
  echo "  ${BUILD_CMD[*]}"
  echo "  ${PUSH_CMD[*]}"
  exit 0
fi

# 3. push 先がインフラ（Artifact Registry）への書き込みなので、誤操作防止に一度確認する
if [ "$ASSUME_YES" != true ]; then
  read -r -p "$(echo -e "${YELLOW}上記イメージを build して push します。続行しますか? [y/N]: ${NC}")" REPLY
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo -e "${YELLOW}中止しました。${NC}"; exit 0 ;;
  esac
fi

# 4. Artifact Registry への Docker 認証（push に必要）
echo -e "\n${GREEN}[1/3] Artifact Registry への Docker 認証を設定...${NC}"
gcloud auth configure-docker "$REGISTRY_HOST" --quiet

# 5. レジストリ（箱）の存在確認（Terraform 未 apply のままだと push が失敗するため、
#    原因を分かりやすく案内する。describe は read-only で副作用なし）
echo -e "${GREEN}[2/3] infra-tools リポジトリの存在を確認...${NC}"
if ! gcloud artifacts repositories describe infra-tools \
      --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  echo -e "${RED}[Error] Artifact Registry リポジトリ 'infra-tools' が見つかりません。${NC}"
  echo -e "${YELLOW}  先に governance/admin/foundation を terraform apply して箱を作成してください${NC}"
  echo -e "${YELLOW}  （定義: governance/admin/foundation/build.tf の google_artifact_registry_repository.infra_tools）。${NC}"
  exit 1
fi

# 6. build & push
echo -e "${GREEN}[3/3] イメージを build して push...${NC}"
"${BUILD_CMD[@]}"
"${PUSH_CMD[@]}"

echo -e "\n${GREEN}>>> 完了: ${IMAGE} を push しました。${NC}"
echo -e "${YELLOW}    これで PR 検閲用 Cloud Build がこのイメージを pull して起動できます。${NC}"
