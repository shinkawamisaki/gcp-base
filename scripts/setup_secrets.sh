#!/bin/bash
set -e

# ==============================================================================
# GCP Foundation: Secret Setup Script
# 
# [目的] 
# Secret Manager に保存する機密情報を Admin プロジェクトに集約して登録します。
# 入力内容は画面に表示されませんが、確実に登録されます。
# ==============================================================================

# 色の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}>>> Starting Secure Secret Setup (Centralized)...${NC}"

# 1. 実行場所に関わらずプロジェクトのルートを特定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$PROJECT_ROOT/governance/admin/terraform.tfvars"

if [ ! -f "$TFVARS" ]; then
    echo -e "${RED}[Error] $TFVARS が見つかりません。${NC}"
    exit 1
fi

ADMIN_PJ=$(grep "project_id" "$TFVARS" | cut -d'"' -f2)

echo -e "Target Central Project : ${YELLOW}$ADMIN_PJ${NC}"
echo -e "------------------------------------------------"

# シークレット登録用関数
set_secret() {
    local PJ=$1
    local NAME=$2
    local DESC=$3

    echo -e "\n[Setting up: ${GREEN}$NAME${NC}] ($DESC)"
    
    if ! gcloud secrets describe "$NAME" --project="$PJ" &>/dev/null; then
        echo -e "${RED}Error: Secret '$NAME' does not exist in Admin project.${NC}"
        return
    fi

    if [[ "$NAME" == *"private-key"* ]]; then
        echo -e "${YELLOW}Wait: This secret supports MULTI-LINE input.${NC}"
        echo -e "${YELLOW}1. Paste your Private Key below.${NC}"
        echo -e "${YELLOW}2. Press [Enter] then [Ctrl+D] to save.${NC}"
        SECRET_VALUE=$(cat)
    else
        echo -e "${YELLOW}Wait: Paste your value below and press Enter.${NC}"
        read -p "Value for $NAME: " SECRET_VALUE
    fi
    echo "" # 改行用

    if [ -z "$SECRET_VALUE" ]; then
        echo -e "${YELLOW}Skipped: Value is empty.${NC}"
        return
    fi

    echo -n "$SECRET_VALUE" | gcloud secrets versions add "$NAME" --data-file=- --project="$PJ" --quiet
    echo -e "${GREEN}Successfully updated $NAME!${NC}"
    unset SECRET_VALUE
}

# 2. 各シークレットの設定
echo -e "${YELLOW}Hint: 登録済みの値を変更しない場合は、何も入力せず Enter を押してください。${NC}"

# Admin (Infra) プロジェクトに全ての鍵を集約
set_secret "$ADMIN_PJ" "infra-gemini-api-key" "週次セキュリティ監査の要約（AI解析）に使用する Gemini API キー"
set_secret "$ADMIN_PJ" "infra-audit-slack-webhook" "週次セキュリティ監査レポートの通知先 (#gcp-security)"
set_secret "$ADMIN_PJ" "infra-ops-slack-webhook" "全般的な運用・システムアラート用 (#gcp-ops)"
set_secret "$ADMIN_PJ" "infra-deploy-slack-webhook" "プロジェクト作成・削除等のインフラ構築通知用 (#gcp-infra)"
set_secret "$ADMIN_PJ" "infra-billing-slack-webhook" "予算超過・コストアラート通知用 (#gcp-billing)"
set_secret "$ADMIN_PJ" "infra-sandbox-slack-webhook" "サンドボックス環境のライフサイクル通知用 (#gcp-sandbox)"
set_secret "$ADMIN_PJ" "infra-monitoring-slack-token" "外観監視 (Uptime Check) の Slack 通知用ボットトークン (xoxb-...)"
set_secret "$ADMIN_PJ" "infra-github-token" "サンドボックスの自動削除（台帳更新）に使用する GitHub Fine-grained PAT"
set_secret "$ADMIN_PJ" "infra-github-app-id" "GitHub App の App ID"
set_secret "$ADMIN_PJ" "infra-github-app-private-key" "GitHub App の Private Key (-----BEGIN RSA PRIVATE KEY----- ...)"
set_secret "$ADMIN_PJ" "infra-github-app-installation-id" "GitHub App の Installation ID"

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}🎉 All secrets have been processed safely in Admin project!${NC}"
echo -e "${GREEN}================================================================${NC}\n"
