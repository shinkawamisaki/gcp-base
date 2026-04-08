#!/bin/bash
set -e

# ==============================================================================
# GCP-base: Bootstrap Script 
# 
# 1. 物理隔離: Organization直下ではなく Folder 階層を強制し、被害半径を最小化。
# 2. 最小権限: Runner SA の権限範囲を適切に分離（作業領域は管理権限を付与、管理領域は隔離）。
# 3. 統制完遂: 組織レベルの権限を自動付与。
# =============================================================================

# --- 0. 設定の読み込み ---
SCRIPT_DIR=$(cd $(dirname $0); pwd)
PROJECT_ROOT=$(cd $SCRIPT_DIR/..; pwd)
VARS_FILE="$PROJECT_ROOT/governance/admin/terraform.tfvars"

if [ ! -f "$VARS_FILE" ]; then
  echo -e "\033[31m[ERROR] terraform.tfvars が見つかりません。example をコピーして作成してください。\033[0m"
  exit 1
fi

get_var() {
  grep "^$1" "$VARS_FILE" | sed -E 's/.*=[[:space:]]*"?([^"]*)"?/\1/' | sed 's/[[:space:]]*$//'
}

PROJECT_ID=$(get_var "project_id")
ORG_ID=$(get_var "org_id")
BILLING_ID=$(get_var "billing_account_id")
REGION=$(get_var "region")
GH_ORG_NAME=$(get_var "gh_org_name")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  GCP-base: 全自動ブートストラップ を開始します${NC}"
echo -e "${BLUE}================================================================${NC}"

if [ -z "$GH_ORG_NAME" ]; then echo -e "${RED}[ERROR] gh_org_name が未定義です${NC}"; exit 1; fi

# --- 1. フォルダ階層の作成 ---
echo -e "${YELLOW}[1/6] フォルダ階層を構築中...${NC}"
ALL_FOLDERS=$(gcloud resource-manager folders list --organization="$ORG_ID" --format="value(name,displayName)")

INFRA_FOLDER_ID=$(echo "$ALL_FOLDERS" | grep "Infrastructure-Admin" | awk '{print $1}' || true)
if [ -z "$INFRA_FOLDER_ID" ]; then
  INFRA_FOLDER_ID=$(gcloud resource-manager folders create --display-name="Infrastructure-Admin" --organization="$ORG_ID" --format="value(name)")
fi
echo -e "${GREEN}[OK] Infrastructure Folder: $INFRA_FOLDER_ID${NC}"

WORKLOAD_FOLDER_ID=$(echo "$ALL_FOLDERS" | grep "Workloads" | awk '{print $1}' || true)
if [ -z "$WORKLOAD_FOLDER_ID" ]; then
  WORKLOAD_FOLDER_ID=$(gcloud resource-manager folders create --display-name="Workloads" --organization="$ORG_ID" --format="value(name)")
fi
echo -e "${GREEN}[OK] Workloads Folder: $WORKLOAD_FOLDER_ID${NC}"

SANDBOX_FOLDER_ID=$(echo "$ALL_FOLDERS" | grep "Sandboxes" | awk '{print $1}' || true)
if [ -z "$SANDBOX_FOLDER_ID" ]; then
  SANDBOX_FOLDER_ID=$(gcloud resource-manager folders create --display-name="Sandboxes" --organization="$ORG_ID" --format="value(name)")
fi
echo -e "${GREEN}[OK] Sandboxes Folder: $SANDBOX_FOLDER_ID${NC}"

# --- 2. Admin プロジェクト作成 & フォルダ移動 ---
echo -e "${YELLOW}[2/6] 管理用プロジェクトを準備中...${NC}"
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"
else
  echo -e "${GREEN}[OK] Project $PROJECT_ID は既に存在します${NC}"
fi

gcloud projects move "$PROJECT_ID" --folder="${INFRA_FOLDER_ID#folders/}" --quiet >/dev/null 2>&1 || true

# --- 請求アカウントの紐付け (リトライ付き) ---
echo -e "請求アカウントの紐付けを確認中..."
MAX_RETRIES=5
for i in $(seq 1 $MAX_RETRIES); do
  set +e # エラーでも止まらないようにする
  ERROR_MSG=$(gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID" 2>&1)
  LINK_STATUS=$?
  set -e # 戻す
  
  if [ $LINK_STATUS -eq 0 ]; then
    echo -e "${GREEN}[OK] 請求アカウントの紐付けに成功しました。${NC}"
    break
  fi
  
  if [ $i -eq $MAX_RETRIES ]; then
    echo -e "${RED}[ERROR] 請求アカウントの紐付けに失敗しました。${NC}"
    echo -e "${RED}生のエラー内容: $ERROR_MSG${NC}"
  else
    echo -e "${YELLOW}  - 反映待ち... リトライ中 ($i/$MAX_RETRIES)...${NC}"
    sleep 20
  fi
done

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

echo -e "${YELLOW}[3/6] 管理用APIを有効化中...${NC}"

# A. まず土台となる API を有効化
gcloud services enable \
  serviceusage.googleapis.com \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

# B. Budget API は請求先リンクの反映に非常に敏感なため、個別にリトライと「実動作の確認」を行う
echo -e "${YELLOW}Billing Budget API を有効化 & サービスエージェントを作成中...${NC}"
MAX_API_RETRIES=20
for i in $(seq 1 $MAX_API_RETRIES); do
  # 1. まず有効化コマンドを送る
  gcloud services enable billingbudgets.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1

  # 2. 【最重要】予算管理用のサービスエージェントを明示的に作成
  # これにより、Terraform 実行時に「SA が存在しない」というエラーを物理的に回避します。
  gcloud beta services identity create --service=billingbudgets.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true

  # 3. Runner SA 権限で予算一覧が取得できるかテストする（権限の伝播待ち）
  if gcloud billing budgets list --billing-account="$BILLING_ID" \
     --impersonate-service-account="$RUNNER_SA_EMAIL" --limit=1 >/dev/null 2>&1; then

    echo -e "${GREEN}[OK] Budget API サービスエージェントのアクティベートを確認しました。${NC}"
    BUDGET_API_SUCCESS=true
    break
  fi

  if [ $i -eq $MAX_API_RETRIES ]; then
    echo -e "${RED}[ERROR] Budget API サービスエージェントの準備が整いませんでした。${NC}"
    exit 1
  else
    echo -e "${YELLOW}  - SA 反映待ち... ($i/$MAX_API_RETRIES)${NC}"
    sleep 20
  fi
done

# C. 残りの API を一括有効化
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com \
  sts.googleapis.com logging.googleapis.com orgpolicy.googleapis.com \
  securitycenter.googleapis.com secretmanager.googleapis.com \
  compute.googleapis.com --project="$PROJECT_ID"

# --- 4. Terraform Runner SA の作成 ---
RUNNER_SA_NAME="prd-terraform-runner-sa"
RUNNER_SA_EMAIL="$RUNNER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

if ! gcloud iam service-accounts describe "$RUNNER_SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo -e "${YELLOW}[4/6] Terraform Runner SA を作成中...${NC}"
  gcloud iam service-accounts create "$RUNNER_SA_NAME" --display-name="[Infrastructure] Terraform Runner SA" --project="$PROJECT_ID"
  sleep 10
fi

echo -e "${YELLOW}Runner SA に基本権限を授与中...${NC}"
for ROLE in "roles/editor" "roles/resourcemanager.projectIamAdmin" "roles/iam.serviceAccountAdmin" "roles/iam.workloadIdentityPoolViewer" "roles/serviceusage.serviceUsageConsumer"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="$ROLE" --condition=None >/dev/null
done

# --- 5. WIF & tfstate 作成 ---
POOL_ID="gh-actions-pool"
PROVIDER_ID="gh-provider"

if ! gcloud iam workload-identity-pools describe "$POOL_ID" --location="global" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo -e "${YELLOW}[5/6] WIF Pool を作成中...${NC}"
  gcloud iam workload-identity-pools create "$POOL_ID" --location="global" --display-name="GitHub Actions Pool" --project="$PROJECT_ID"
fi

if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --location="global" --workload-identity-pool="$POOL_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo -e "${YELLOW}WIF Provider を作成中...${NC}"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --location="global" --workload-identity-pool="$POOL_ID" --display-name="GitHub Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.owner=assertion.repository_owner" \
    --attribute-condition="attribute.owner == '$GH_ORG_NAME'" --project="$PROJECT_ID"
fi

BUCKET_NAME="$PROJECT_ID-tfstate"
if ! gcloud storage buckets describe "gs://$BUCKET_NAME" >/dev/null 2>&1; then
  echo -e "${YELLOW}[6/6] tfstate バケットを作成中...${NC}"
  gcloud storage buckets create "gs://$BUCKET_NAME" --location="$REGION" --project="$PROJECT_ID"
  gcloud storage buckets update "gs://$BUCKET_NAME" --versioning
fi
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="roles/storage.admin" --quiet >/dev/null 2>&1

# --- 6. 組織・請求レベルの権限委譲 ---
echo -e "\n${BLUE}組織レベルの権限委譲およびシークレットの初期化を実行します${NC}"

# 必須シークレットの「箱」を事前に用意（中身はダミー）
# これを物理構築(bootstrap)で行うことで、CI/CDの初動での 404 エラーを確実に防ぎます。
# 権限（誰が読めるか）の管理はTerraform 側で一元管理します。
REQUIRED_SECRETS=(
  "infra-gemini-api-key"
  "infra-deploy-slack-webhook"
  "infra-audit-slack-webhook"
  "infra-billing-slack-webhook"
  "infra-sandbox-slack-webhook"
  "infra-ops-slack-webhook"
  "infra-monitoring-slack-token"
)
for SECRET in "${REQUIRED_SECRETS[@]}"; do
  if ! gcloud secrets describe "$SECRET" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "シークレット '$SECRET' を作成中..."
    gcloud secrets create "$SECRET" --replication-policy="automatic" --project="$PROJECT_ID"
    # 初期ダミー値の注入
    echo -n "PLACEHOLDER_DO_NOT_USE" | gcloud secrets versions add "$SECRET" --data-file=- --project="$PROJECT_ID" --quiet
  fi
done

for ROLE in "roles/resourcemanager.projectCreator" "roles/logging.configWriter" "roles/serviceusage.serviceUsageAdmin" "roles/securitycenter.notificationConfigEditor" "roles/iam.securityAdmin"; do
  gcloud organizations add-iam-policy-binding "$ORG_ID" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="$ROLE" --condition=None >/dev/null
done

for FOLDER_ID in "$WORKLOAD_FOLDER_ID" "$SANDBOX_FOLDER_ID"; do
  for ROLE in "roles/resourcemanager.folderAdmin" "roles/resourcemanager.projectCreator" "roles/resourcemanager.projectIamAdmin" "roles/compute.admin" "roles/storage.admin" "roles/pubsub.admin" "roles/cloudfunctions.admin" "roles/cloudscheduler.admin" "roles/serviceusage.serviceUsageAdmin" "roles/iam.serviceAccountUser"; do
    gcloud resource-manager folders add-iam-policy-binding "${FOLDER_ID#folders/}" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="$ROLE" >/dev/null
  done
done

for ROLE in "roles/billing.user" "roles/billing.costsManager"; do
  gcloud billing accounts add-iam-policy-binding "$BILLING_ID" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="$ROLE" >/dev/null
done

# --- 7. 物理ガードレールの設置 (リトライ付き) ---
echo -e "\n${BLUE}物理ガードレールを設置中...${NC}"

for FOLDER_ID in "$WORKLOAD_FOLDER_ID" "$SANDBOX_FOLDER_ID"; do
  RAW_ID="${FOLDER_ID#folders/}"
  echo -e "  - フォルダ $RAW_ID にポリシー適用中..."
  
  # A. デフォルトネットワークの作成を禁止
  cat <<EOF > policy_net.yaml
constraint: constraints/compute.skipDefaultNetworkCreation
booleanPolicy:
  enforced: true
EOF

  # B. 外部IPの付与を禁止 (共通ガードレール)
  cat <<EOF > policy_ip.yaml
constraint: constraints/compute.vmExternalIpAccess
listPolicy:
  allValues: DENY
EOF

  for i in $(seq 1 $MAX_RETRIES); do
    if gcloud resource-manager org-policies set-policy policy_net.yaml --folder="$RAW_ID" --billing-project="$PROJECT_ID" >/dev/null 2>&1 && \
       gcloud resource-manager org-policies set-policy policy_ip.yaml --folder="$RAW_ID" --billing-project="$PROJECT_ID" >/dev/null 2>&1; then
      echo -e "${GREEN}    [OK] フォルダポリシー適用成功${NC}"
      break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
      echo -e "${RED}    [ERROR] ポリシー適用に失敗しました。${NC}"
    else
      echo -e "${YELLOW}    - 反映待ち... リトライ中 ($i/$MAX_RETRIES)...${NC}"
      sleep 15
    fi
  done
  rm -f policy_net.yaml policy_ip.yaml
done

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1


# --- 8. 設定ファイル生成 ---
METADATA_FILE="bootstrap_metadata.json"
cat <<EOF > "$METADATA_FILE"
{
  "infrastructure_folder_id": "folders/${INFRA_FOLDER_ID#folders/}",
  "workloads_folder_id": "folders/${WORKLOAD_FOLDER_ID#folders/}",
  "sandbox_folder_id": "folders/${SANDBOX_FOLDER_ID#folders/}"
}
EOF
gsutil cp "$METADATA_FILE" "gs://$BUCKET_NAME/bootstrap_metadata.json" >/dev/null 2>&1
rm -f "$METADATA_FILE"

# Admin - Foundation レイヤー用
cat <<EOF > "$PROJECT_ROOT/governance/admin/foundation/backend.hcl"
bucket = "$BUCKET_NAME"
prefix = "terraform/admin/foundation/state"
EOF

# Admin - Factory レイヤー用
cat <<EOF > "$PROJECT_ROOT/governance/admin/factory/backend.hcl"
bucket = "$BUCKET_NAME"
prefix = "terraform/admin/factory/state"
EOF

# Governance レイヤー用
cat <<EOF > "$PROJECT_ROOT/governance/org-policies/backend.hcl"
bucket = "$BUCKET_NAME"
prefix = "terraform/org-policies/state"
EOF

echo -e "${GREEN}[OK] backend.hcl ファイルを自動生成しました。${NC}"

# --- 9. GitHub Variableに値を設定 ---
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo -e "\n${YELLOW}[9/9] GitHub Variables/Secrets を同期中...${NC}"
  
  # プロジェクト番号の動的取得 (WIF認証に必須)
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
  
  # 変数 (Variables) の設定
  gh variable set GCP_PROJECT_ID --body "$PROJECT_ID" || true
  gh variable set GCP_PROJECT_NUMBER --body "$PROJECT_NUMBER" || true
  gh variable set GH_ORG_NAME --body "$GH_ORG_NAME" || true
  gh variable set GCP_REGION --body "$REGION" || true
  
  # terraform.tfvars から追加情報を抽出
  APP_BASE_NAME=$(get_var "app_base_name")
  ADMIN_EMAIL=$(get_var "admin_group_email")
  OWNER=$(get_var "project_owner")
  
  gh variable set APP_BASE_NAME --body "$APP_BASE_NAME" || true
  gh variable set ADMIN_GROUP_EMAIL --body "$ADMIN_EMAIL" || true
  gh variable set PROJECT_OWNER --body "$OWNER" || true
  
  # 機密情報 (Secrets) の設定
  gh secret set GCP_BILLING_ACCOUNT_ID --body "$BILLING_ID" || true
  gh secret set GCP_ORG_ID --body "$ORG_ID" || true
  
  echo -e "${GREEN}[OK] GitHub 連携設定が完了しました。${NC}"
fi

# --- 10. 監査用セットアップログの保存 ---
echo -e "\n${YELLOW}[10/10] 監査用セットアップログを保存中...${NC}"
AUDIT_LOG_FILE="bootstrap_audit_log_$(date +%Y%m%d_%H%M%S).json"

cat <<EOF > "$AUDIT_LOG_FILE"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "operator": "$(gcloud config get-value account)",
  "organization_id": "$ORG_ID",
  "billing_account_id": "$BILLING_ID",
  "admin_project_id": "$PROJECT_ID",
  "folders": {
    "admin": "folders/${INFRA_FOLDER_ID#folders/}",
    "workloads": "folders/${WORKLOAD_FOLDER_ID#folders/}",
    "sandboxes": "folders/${SANDBOX_FOLDER_ID#folders/}"
  },
  "wif": {
    "pool": "$POOL_ID",
    "provider": "$PROVIDER_ID"
  }
}
EOF

# バケットはバージョニング有効化済みのため、証跡として安全に保管されます
gsutil cp "$AUDIT_LOG_FILE" "gs://$BUCKET_NAME/audit_logs/$AUDIT_LOG_FILE" >/dev/null 2>&1
rm -f "$AUDIT_LOG_FILE"

echo -e "${GREEN}[OK] 監査ログを gs://$BUCKET_NAME/audit_logs/ に保存しました。${NC}"

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}  セットアップが完了しました${NC}"
echo -e "${GREEN}================================================================${NC}\n"