#!/bin/bash
set -e

# ==============================================================================
# GCP Foundation: Secret Setup Script
# 
# [目的]
# Secret Manager に保存する機密情報を Admin プロジェクトに集約して登録します。
# 単一行の値は read -s で非表示入力、複数行の鍵はファイルパス指定で、
# 値を端末に一切表示せずに登録します。
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
        # 複数行の秘密鍵を端末に貼り付けると、入力内容がそのままエコーされ
        # スクロールバック・画面共有・録画に残るため、値を端末に通さない
        # 「ファイルパス指定」方式とする（中身は gcloud が直接読む）。
        echo -e "${YELLOW}Wait: This secret is MULTI-LINE. Enter the path to the key file.${NC}"
        echo -e "${YELLOW}(File content is sent directly to Secret Manager and never echoed.)${NC}"
        read -r -p "Path to key file for $NAME (empty to skip): " KEY_FILE
        if [ -z "$KEY_FILE" ]; then
            echo -e "${YELLOW}Skipped: No file specified.${NC}"
            return
        fi
        if [ ! -f "$KEY_FILE" ]; then
            echo -e "${RED}Error: File not found: $KEY_FILE${NC}"
            return
        fi
        gcloud secrets versions add "$NAME" --data-file="$KEY_FILE" --project="$PJ" --quiet
        echo -e "${GREEN}Successfully updated $NAME!${NC}"
        echo -e "${YELLOW}Reminder: delete the local key file when no longer needed.${NC}"
        return
    fi

    # -s: 入力を画面にエコーしない（シークレットを端末表示・記録に残さない）
    echo -e "${YELLOW}Wait: Paste your value below and press Enter (input is hidden).${NC}"
    read -rs -p "Value for $NAME: " SECRET_VALUE
    echo "" # read -s は改行を出力しないため明示

    if [ -z "$SECRET_VALUE" ]; then
        echo -e "${YELLOW}Skipped: Value is empty.${NC}"
        return
    fi

    # パイプ渡し: CLI 引数だと ps で他プロセスから値が見えるため stdin で渡す
    printf '%s' "$SECRET_VALUE" | gcloud secrets versions add "$NAME" --data-file=- --project="$PJ" --quiet
    echo -e "${GREEN}Successfully updated $NAME!${NC}"
    unset SECRET_VALUE
}

# 2. 各シークレットの設定
echo -e "${YELLOW}Hint: 登録済みの値を変更しない場合は、何も入力せず Enter を押してください。${NC}"

# Admin (Infra) プロジェクトに全ての鍵を集約
# 注: infra-gemini-api-key は完全撤去済み（bootstrap.sh の作成・foundation の参照/付与も削除）。
#     AI 要約/検閲は Vertex AI を ADC（roles/aiplatform.user）で呼ぶ鍵レス構成へ移行したため不要。
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
set_secret "$ADMIN_PJ" "github-token-pr-reviewer" "Cloud Build が PR にコメントを書き込むための GitHub PAT"
set_secret "$ADMIN_PJ" "infra-datadog-api-key" "Datadog API Key (オプション: AI検閲結果のメトリクス送信)"

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}🎉 All secrets have been processed safely in Admin project!${NC}"
echo -e "${GREEN}================================================================${NC}\n"
