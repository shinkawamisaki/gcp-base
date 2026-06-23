#!/bin/bash
set -e

# 異常系の確実なクリーンアップ: set -e による早期 exit でも、ローカルに残った
# 一時ファイル（org-policy 定義・GCS へ退避するメタデータ/監査ログ。内部情報を含み得る）を
# 必ず削除する。成功パスの明示 rm と二重になるが rm -f は冪等で無害。
# trap 自体が失敗して本処理の終了コードを汚さないよう 2>/dev/null || true で保護。
trap 'rm -f policy_net.yaml policy_ip.yaml bootstrap_metadata.json bootstrap_audit_log_*.json 2>/dev/null || true' EXIT

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

# Runner SA の定義 (2回目実行時でもチェック等で正しく参照できるよう、冒頭で定義)
RUNNER_SA_NAME="prd-terraform-runner-sa"
RUNNER_SA_EMAIL="$RUNNER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# fail-loud: リトライ尽きた失敗を握り潰さず集約し、最後に非0で終了する。
# ガードレール（org-policy）未適用や監査証跡の保存失敗が「完了しました」で
# 緑に見えると、欠落に誰も気付けない（偽りの安心が最も危険）。
FAILED_STEPS=()

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
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID" >/dev/null 2>&1
  # 終了コードではなく「実際に請求が有効か」で判定する。
  # 既にリンク済みの再実行では link コマンドが非0を返すことがあり、状態は正常なのに
  # 「失敗」と誤表示されて紛らわしいため、真の状態（billingEnabled）を成功条件にする。
  BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)
  set -e # 戻す

  if [ "$BILLING_ENABLED" = "True" ]; then
    echo -e "${GREEN}[OK] 請求アカウントの紐付けを確認しました。${NC}"
    break
  fi

  if [ $i -eq $MAX_RETRIES ]; then
    echo -e "${RED}[ERROR] 請求アカウントの紐付けに失敗しました。${NC}"
    # §5: 生のエラー出力（請求アカウントID等の内部情報を含み得る）はログに出さず抽象化する。
    # 詳細は実行端末の権限で `gcloud billing projects link` を手動実行して確認する運用とする。
    echo -e "${RED}  権限・請求アカウントID・対象APIの有効化状態を確認してください（詳細はマスク）。${NC}"
    FAILED_STEPS+=("billing-link")
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

  # 3. Budget API（billingbudgets）が実際に応答するかを確認する（サービスエージェント有効化の伝播待ち）。
  #    呼び出し元（bootstrap 実行者）の権限で確認する。Runner SA はこの時点では未作成（167行）で、
  #    請求権限の付与も後段（242行）のため、SA を impersonate すると初回フル実行では原理的に通らない。
  if gcloud billing budgets list --billing-account="$BILLING_ID" --limit=1 >/dev/null 2>&1; then

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
# aiplatform: AI検閲官(scripts/pr_reviewer.py)と監査ボット(weekly_check)が Vertex AI(Gemini)を
#   ADC で呼び出すために必須。未有効だと全 Vertex 呼び出しが失敗し、fail-open 構成
#   (STRICT_AI_VERIFY=false)では検閲ゲートが素通り(no-op)で緑になってしまう。明示有効化する。
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com \
  sts.googleapis.com logging.googleapis.com orgpolicy.googleapis.com \
  securitycenter.googleapis.com secretmanager.googleapis.com \
  compute.googleapis.com aiplatform.googleapis.com --project="$PROJECT_ID"

# --- 4. Terraform Runner SA の作成 ---
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

# 【修正】--condition=None を追加し、非対話モードでのエラーを回避
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" --member="serviceAccount:$RUNNER_SA_EMAIL" --role="roles/storage.admin" --condition=None --quiet >/dev/null 2>&1

# --- 6. 組織・請求レベルの権限委譲 ---
echo -e "\n${BLUE}組織レベルの権限委譲およびシークレットの初期化を実行します${NC}"

# 必須シークレットの「箱」を事前に用意（中身はダミー）
# これを物理構築(bootstrap)で行うことで、CI/CDの初動での 404 エラーを確実に防ぎます。
# 権限（誰が読めるか）の管理はTerraform 側で一元管理します。
REQUIRED_SECRETS=(
  "infra-deploy-slack-webhook"
  "infra-audit-slack-webhook"
  "infra-billing-slack-webhook"
  "infra-sandbox-slack-webhook"
  "infra-ops-slack-webhook"
  "infra-monitoring-slack-token"
  "infra-github-token"
  "infra-github-app-id"
  "infra-github-app-private-key"
  "infra-github-app-installation-id"
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
      FAILED_STEPS+=("org-policy-folder:${RAW_ID}")
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
if ! gsutil cp "$METADATA_FILE" "gs://$BUCKET_NAME/bootstrap_metadata.json" >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] bootstrap_metadata.json の GCS 保存に失敗しました（後続の参照が壊れます）。${NC}"
  FAILED_STEPS+=("metadata-upload")
fi
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

# --- 10. ローカル開発環境のセットアップ (pre-commit) ---
echo -e "\n${YELLOW}[10/11] ローカル開発環境のセットアップ (pre-commit) を実行中...${NC}"
if command -v pre-commit >/dev/null 2>&1; then
  echo -e "pre-commit がインストールされています。フックを設定します。"
  pre-commit install
else
  echo -e "${YELLOW}pre-commit が見つかりません。pip3 を使ってインストールを試みます...${NC}"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install pre-commit
    pre-commit install
    echo -e "${GREEN}[OK] pre-commit をインストールし、フックを設定しました。${NC}"
  else
    echo -e "${RED}[WARN] pip3 が見つかりません。手動で pre-commit をインストールし、'pre-commit install' を実行してください。${NC}"
  fi
fi

# --- 11. 監査用セットアップログの保存 ---
echo -e "\n${YELLOW}[11/11] 監査用セットアップログを保存中...${NC}"
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
# 監査証跡（IPO 用）の保存は成功確認が必須。失敗を握り潰して
# 「保存しました」と表示するのは虚偽の証跡報告になる。
if gsutil cp "$AUDIT_LOG_FILE" "gs://$BUCKET_NAME/audit_logs/$AUDIT_LOG_FILE" >/dev/null 2>&1; then
  rm -f "$AUDIT_LOG_FILE"
  echo -e "${GREEN}[OK] 監査ログを gs://$BUCKET_NAME/audit_logs/ に保存しました。${NC}"
else
  # trap が bootstrap_audit_log_*.json を削除するため、.unsent に退避して保全する
  mv "$AUDIT_LOG_FILE" "${AUDIT_LOG_FILE}.unsent"
  echo -e "${RED}[ERROR] 監査ログの GCS 保存に失敗しました。ローカルに ${AUDIT_LOG_FILE}.unsent として退避しました。${NC}"
  echo -e "${RED}  手動でアップロードしてください: gsutil cp ${AUDIT_LOG_FILE}.unsent gs://$BUCKET_NAME/audit_logs/$AUDIT_LOG_FILE${NC}"
  FAILED_STEPS+=("audit-log-upload")
fi

if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
  echo -e "\n${RED}================================================================${NC}"
  echo -e "${RED}  セットアップは完了していません（失敗したステップがあります）${NC}"
  for step in "${FAILED_STEPS[@]}"; do
    echo -e "${RED}    - $step${NC}"
  done
  echo -e "${RED}  上記を解消してから本スクリプトを再実行してください（再実行は冪等です）。${NC}"
  echo -e "${RED}================================================================${NC}\n"
  exit 1
fi

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}  セットアップが完了しました${NC}"
echo -e "${GREEN}================================================================${NC}\n"