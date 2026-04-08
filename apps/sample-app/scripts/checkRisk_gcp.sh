#!/bin/bash
# ===============================================================
# checkRisk_gcp.sh: GCP 基盤横断セキュリティ監査スクリプト (AI連携版)
# ===============================================================

# 色の設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OUTPUT_DIR="output"
mkdir -p $OUTPUT_DIR
TEMP_REPORT="$OUTPUT_DIR/raw_audit_data.md"
FINAL_REPORT="$OUTPUT_DIR/SecurityAuditReport_$(date +%Y%m%d_%H%M%S).md"

echo -e "${GREEN}>>> Starting Local Security Audit...${NC}"

# 1. Gemini API キーの取得
TFVARS="governance/admin/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
    echo -e "${RED}[Error] terraform.tfvars が見つかりません。${NC}"
    exit 1
fi
ADMIN_PJ=$(grep "project_id" "$TFVARS" | cut -d'"' -f2)

echo -e "Fetching Gemini API Key from Admin Project (${YELLOW}$ADMIN_PJ${NC})..."
API_KEY=$(gcloud secrets versions access latest --secret="gemini-api-key" --project="$ADMIN_PJ" 2>/dev/null || echo "")

# 2. 監査対象プロジェクトの自動取得
echo -e "Searching for managed projects..."
PROJECTS=$(gcloud projects list --filter="labels.managed=terraform-project-factory" --format="value(project_id)")

if [ -z "$PROJECTS" ]; then
    PROJECTS=$(gcloud config get-value project)
    echo "⚠️ 管理ラベル付きプロジェクトが見つからないため、現在のプロジェクトのみをスキャンします。" > $TEMP_REPORT
else
    echo "# 🛡️ GCP 基盤セキュリティ監査レポート" > $TEMP_REPORT
    echo "実行日: $(date)" >> $TEMP_REPORT
    echo "" >> $TEMP_REPORT
fi

# 3. スキャン実行
for PJ in $PROJECTS; do
    echo -e "\nScanning Project: ${YELLOW}$PJ${NC}"
    echo "---" >> $TEMP_REPORT
    echo "## Project: $PJ" >> $TEMP_REPORT
    
    # --- ① Firewall ---
    echo -n "  [1/5] Scanning Firewall... "
    echo "### Firewall (0.0.0.0/0 開放)" >> $TEMP_REPORT
    echo "| Rule | Port | Protocol | Risk | Priority |" >> $TEMP_REPORT
    echo "|---|---|---|---|---|" >> $TEMP_REPORT
    FW_DATA=$(gcloud compute firewall-rules list --project=$PJ --filter="sourceRanges:0.0.0.0/0 AND action:ALLOW" --format="csv[no-heading](name,allowed[].map().list().join('/'))" 2>/dev/null || echo "")
    if [ -n "$FW_DATA" ]; then
        while IFS=',' read -r name ports; do
            echo "| $name | $ports | TCP/UDP | ⚠️ 全開放 | High |" >> $TEMP_REPORT
        done <<< "$FW_DATA"
    else
        echo "| 該当なし | – | – | – | – |" >> $TEMP_REPORT
    fi
    echo -e "${GREEN}Done${NC}"

    # --- ② Storage ---
    echo -n "  [2/5] Scanning Storage... "
    echo "### Storage (公開バケット)" >> $TEMP_REPORT
    echo "| Bucket | Risk | Priority |" >> $TEMP_REPORT
    echo "|---|---|---|" >> $TEMP_REPORT
    BUCKETS=$(gcloud storage buckets list --project=$PJ --format="value(name)" 2>/dev/null || echo "")
    PB_FOUND=0
    for B in $BUCKETS; do
        IS_PB=$(gcloud storage buckets get-iam-policy gs://$B --project=$PJ --filter="bindings.members:allUsers OR bindings.members:allAuthenticatedUsers" --format="value(name)" 2>/dev/null || echo "")
        if [ -n "$IS_PB" ]; then
            echo "| $B | 🚨 公開中 | Critical |" >> $TEMP_REPORT
            PB_FOUND=$((PB_FOUND + 1))
        fi
    done
    [ $PB_FOUND -eq 0 ] && echo "| 該当なし | – | – |" >> $TEMP_REPORT
    echo -e "${GREEN}Done${NC}"

    # --- ③ IAM ---
    echo -n "  [3/5] Scanning IAM Keys (this may take time)... "
    echo "### IAM (手動発行キー)" >> $TEMP_REPORT
    echo "| SA Name | Key ID | Risk | Priority |" >> $TEMP_REPORT
    echo "|---|---|---|---|" >> $TEMP_REPORT
    IAM_COUNT=0
    SAS=$(gcloud iam service-accounts list --project=$PJ --format="value(email)" 2>/dev/null || echo "")
    for SA in $SAS; do
        KEYS=$(gcloud iam service-accounts keys list --iam-account=$SA --project=$PJ --filter="keyType=USER_MANAGED" --format="value(name)" 2>/dev/null || echo "")
        if [ -n "$KEYS" ]; then
            while read -r line; do
                KEY_ID=$(basename $line | cut -c1-8)
                echo "| ${SA%@*} | $KEY_ID | ⚠️ 漏洩リスク | High |" >> $TEMP_REPORT
                IAM_COUNT=$((IAM_COUNT + 1))
            done <<< "$KEYS"
        fi
    done
    [ $IAM_COUNT -eq 0 ] && echo "| 該当なし | – | – | – |" >> $TEMP_REPORT
    echo -e "${GREEN}Done${NC}"

    # --- ④ VM ---
    echo -n "  [4/5] Scanning Compute Engine... "
    echo "### Compute Engine (外部IP)" >> $TEMP_REPORT
    echo "| Instance | Zone | Public IP | Risk | Priority |" >> $TEMP_REPORT
    echo "|---|---|---|---|---|" >> $TEMP_REPORT
    VM_DATA=$(gcloud compute instances list --project=$PJ --filter="networkInterfaces[0].accessConfigs[0].natIP:*" --format="csv[no-heading](name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "")
    if [ -n "$VM_DATA" ]; then
        while IFS=',' read -r name zone ip; do
            echo "| $name | $zone | $ip | ⚠️ 露出 | Medium |" >> $TEMP_REPORT
        done <<< "$VM_DATA"
    else
        echo "| 該当なし | – | – | – | – |" >> $TEMP_REPORT
    fi
    echo -e "${GREEN}Done${NC}"

    # --- ⑤ SQL ---
    echo -n "  [5/5] Scanning Cloud SQL... "
    echo "### Cloud SQL (パブリックIP)" >> $TEMP_REPORT
    echo "| Instance | Version | Risk | Priority |" >> $TEMP_REPORT
    echo "|---|---|---|---|" >> $TEMP_REPORT
    SQL_DATA=$(gcloud sql instances list --project=$PJ --filter="settings.ipConfiguration.ipv4Enabled=true" --format="csv[no-heading](name,databaseVersion)" 2>/dev/null || echo "")
    if [ -n "$SQL_DATA" ]; then
        while IFS=',' read -r name ver; do
            echo "| $name | $ver | 🚨 露出 | High |" >> $TEMP_REPORT
        done <<< "$SQL_DATA"
    else
        echo "| 該当なし | – | – | – |" >> $TEMP_REPORT
    fi
    echo -e "${GREEN}Done${NC}"
    echo "" >> $TEMP_REPORT
done

# 4. Gemini による AI 解析 (オプション)
if [ -n "$API_KEY" ]; then
    echo -e "Analyzing results with Gemini AI..."
    
    SYS_PROMPT="あなたは冷徹なセキュリティ監査員です。以下の指示を厳守してください:
1. 渡された監査対象レポート内の表から『🚨』や『⚠️』の項目のみを抽出してください。
2. 重要: データにない不備を絶対に創作しないでください。創作は厳禁です。
3. 指摘事項には、必ず元のデータにある『Project名』と『リソース名』を併記してください。
4. 冒頭に『### 🔴 今すぐ対応（Top5）』を作り、不備がなければ『現在、緊急の対応を要する不備は検出されていません。』と1行だけ書いてください。
5. 最後に『📝 総評』として、事実のみを2行以内で記述してください。"

    # RAW_CONTENT を確実に読み込む
    RAW_CONTENT=$(cat $TEMP_REPORT)
    
    # jq を使って安全に JSON を組み立てる
    JSON_PAYLOAD=$(jq -n \
        --arg sys "$SYS_PROMPT" \
        --arg data "$RAW_CONTENT" \
        '{ contents: [{ parts: [{ text: ($sys + "\n\n### 監査対象データここから ###\n" + $data + "\n### 監査対象データここまで ###") }] }] }')
    
    # モデル名を最新の gemini-2.5-flash に固定 (戻さないこと)
    API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$API_KEY"
    
    # 構築した JSON をファイル経由で curl に渡す
    RESPONSE=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    # デバッグ用に生レスポンスを確認 (コメントアウト解除で表示可能)
    # echo "$RESPONSE"

    AI_TEXT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)

    if [ -n "$AI_TEXT" ] && [ "$AI_TEXT" != "null" ]; then
        echo -e "$AI_TEXT" > $FINAL_REPORT
        echo -e "\n---\n" >> $FINAL_REPORT
        cat $TEMP_REPORT >> $FINAL_REPORT
    else
        echo -e "${RED}AI analysis failed or returned null. Saving raw report only.${NC}"
        cat $TEMP_REPORT > $FINAL_REPORT
    fi
else
    cat $TEMP_REPORT > $FINAL_REPORT
fi

rm $TEMP_REPORT
echo -e "\n${GREEN}================================================================${NC}"
echo -e "🎉 Audit Complete! Report saved to: ${YELLOW}$FINAL_REPORT${NC}"
echo -e "${GREEN}================================================================${NC}"
