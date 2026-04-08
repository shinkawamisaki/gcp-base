# GCP-base: Google Cloud 基盤構築キット

「ベンチャーの基盤」を前提に設計したGCPの基盤構築キットです。ベンチャーだから「開発スピードは落としたくない」としながらも「いつかのIPO」や「お客さんの個人情報を扱う」ためのセキュリティとガバナンスを担保しています。

## 主な機能 (Core Features)

1.  **GitOps によるProject Factory**
    - `inventory.json` を更新することで、プロジェクト作成から WIF・予算設定まで自動実行します。
2.  **台帳同期型サンドボックス **
    - 期限が来ると「台帳（Git）」と「実体（GCP）」を自動でクリーンアップして、ゾンビ化を物理的に防止します。
3.  **職務分掌による安全なデプロイ**
    - 本番の書き換えを中央の Runner に集約しました。最小権限（Viewer）での安全なアプリ運用を強制します。
4.  **AI による週次セキュリティ監査**
    - Gemini 2.5-flash が「今すぐ対応すべき Top 5」を抽出してSlack 通知でおしらせします。
5.  **開発者向け自動セットアップガイド**
    - プロジェクト完成時、Slack にそのままコピペして使える YAML 設定を自動配信します。


## 前提条件 (Prerequisites)

本プロジェクトのデプロイと運用には以下の環境が必要です。

- **Terraform:** `>= 1.5.0` (推奨: 最新の 1.x 系)
- **Google Cloud SDK (gcloud):** 最新版を推奨
- **Python:** `3.11` (通知用 Cloud Functions のランタイム)
- **GCP 権限:** 組織管理者 (Organization Administrator) またはそれに準ずる権限

## ディレクトリ構成 (Directory Structure)

```text
gcp-base/
├── .github/                # GitHub Actions ワークフロー定義
├── apps/                   # 各アプリ用スターターキット（テンプレート）
├── docs/                   # 思想、技術仕様、運用ガイド
│   ├── ARCHITECTURE.md     # 思想・権限設計・ネットワーク
│   ├── SPECIFICATION.md    # 【詳細】各機能の技術仕様
│   └── PROJECT_GUIDE.md    # 開発者向け利用ガイド
├── governance/             # ガバナンス・基盤構築レイヤー
│   ├── org-policies/       # 【組織】組織ポリシー（ガードレール）
│   └── admin/              # 【基盤】管理用リソース
│       ├── foundation/     # 基盤共通（WIF, 予算通知, 監視, セキュリティ）
│       └── factory/        # プロジェクト工場（各アプリ環境の払い出し）
├── infra/                  # 基盤オートメーション機能
│   └── modules/            # 監査ボット, ライフサイクル管理
├── modules/                # 再利用可能な Terraform モジュール群
│   ├── project_factory/    # プロジェクト払い出しエンジン
│   ├── billing_base/       # 予算アラート通知
│   └── vpc_base/           # 疎結合な VPC 構築
├── scripts/                # bootstrap.sh 等の自動化スクリプト
└── README.md               # 本ファイル
```

## 構築手順 (初回セットアップ)

### Step 1: 物理土台の作成 (Bootstrap)
ルートディレクトリで初期スクリプトを実行してGCPプロジェクトと権限の土台を作ります。

1. `governance/admin/terraform.tfvars` を作成。
2. `governance/org-policies/terraform.tfvars` を作成。
3. ターミナル（ルートディレクトリ）で以下を実行:
   ```bash
   chmod +x scripts/*.sh
   ./scripts/bootstrap.sh
   ./scripts/setup_secrets.sh
   ```
   ※ `setup_secrets.sh` を実行すると、Slack Webhook URL や Gemini API キーの入力を求められます。
### Step 2: ガードレールの展開 (Governance)
組織全体のルール（ドメイン制限の緩和等）を適用します。

1. **ディレクトリ移動**: `cd governance/org-policies/`
2. **初期化と適用**:
   ```bash
   terraform init -backend-config=backend.hcl
   terraform apply -var-file=terraform.tfvars
   ```

### Step 3: 基盤共通リソースの展開 (Foundation)
WIF（GitHub連携）、予算通知、監視ボットなどを構築します。

1. **ディレクトリ移動**: `cd governance/admin/foundation/`
2. **初期化と適用**:
   ```bash
   terraform init -backend-config=backend.hcl
   terraform apply -var-file=../terraform.tfvars
   ```

### Step 4: プロジェクト工場の展開 (Factory)
各アプリケーション環境やサンドボックスを自動払い出しします。

1.  **台帳の編集**: `governance/admin/factory/inventory.json` を開き、作成したいアプリ名や GitHub リポジトリ名を設定します。
    *   💡 **重要**: `is_audit_host: true` は組織内で **必ず 1つのプロジェクトのみ** に設定してください。

#### 📝 inventory.json のまともな設定サンプル
```json
{
  "apps": {
    "infra-audit": {
      "is_audit_host": true,      // 👈 組織に1つだけ。管理チームが運用
      "environments": ["audit"],
      "github_repo": "your-org/infra-repo"
    },
    "my-app": {
      "is_audit_host": false,     // 👈 通常のアプリは常に false
      "environments": ["stg", "prd"], // 👈 必要な環境だけ指定
      "budget_amount": 50000,
      "github_repo": "your-org/my-app-repo"
    }
  },
  "sandboxes": {}
}
```
2.  **ディレクトリ移動**: `cd governance/admin/factory/`
3.  **初期化と適用**:
    ```bash
    terraform init -backend-config=backend.hcl
    terraform apply -var-file=../terraform.tfvars
    ```



## 運用フェーズの手順

運用に入った後は変更したい箇所のファイルを Push するだけで自動デプロイされます。

- **プロジェクトを追加したい**: `governance/admin/factory/inventory.json` を更新して Push。
- **インフラ構成を変えたい**: `modules/` や `infra/` のコードを修正して Push。

### ⚠️ プロジェクトを削除・変更したい場合
誤削除防止のため、通常のアプリプロジェクトには削除保護 (`PREVENT`) がデフォルトでかかっています。削除を完遂（またはアプリ名の変更）するには、以下の **2ステップ** が必要です。

1.  **保護の解除 (Unlock)**:
    `inventory.json` は **変更せず**、以下のコマンドを実行して全プロジェクトの保護状態を `DELETE` に更新します。
    ```bash
    terraform apply -var-file=../terraform.tfvars -var="deletion_policy=DELETE"
    ```
2.  **削除の実行 (Destroy)**:
    `inventory.json` から対象プロジェクトを削除し、再度コマンドを実行します。
    ```bash
    terraform apply -var-file=../terraform.tfvars -var="deletion_policy=DELETE"
    ```
    ※ ステップ1を飛ばして JSON から削除すると、Terraform の仕様により保護が優先され、エラーとなります。

## セキュリティ設計 (Security by Design)

- **State の完全分離**: 組織ポリシー、基盤インフラ、プロジェクト工場それぞれの台帳を分離し、被害半径を最小化。
- **2系統のSA運用**: 組織権限を持つ特権 SA と、プロジェクト権限のみの通常 SA を使い分け。
- **承認プロセスの強制**: GitHub Environments を活用し、組織ポリシーの変更には管理者の承認を必須とする運用を推奨。

## 初期セットアップのヒント (Tips)

- **GitHub Fine-grained PAT:** サンドボックスの自動削除機能を使用する場合、`Contents: Write` および `Actions: Write` 権限を持つ細粒度トークンが必要です。

### 💡 組織ポリシー設定で 409 エラー (Already Exists) が出た場合
既に Google Cloud 組織レベルで何らかのポリシーが設定されている場合、`governance/org-policies` の実行時に「リソースが既に存在する」というエラーが発生することがあります。その場合は、以下のコマンドで既存の設定を Terraform の管理下にインポートしてください。

```bash
# 例: ドメイン制限ポリシーのインポート
terraform import google_org_policy_policy.legacy_allowed_domains organizations/YOUR_ORG_ID/policies/iam.allowedPolicyMemberDomains
```

## 作者 (Author)

**shinkawa.misaki**

- **GitHub**: [shinkawamisaki](https://github.com/shinkawamisaki)
- **YOUTRUST**: [shinkawa](https://youtrust.jp/users/shinkawa)
- **Email**: [shinkawa.misaki@gmail.com](mailto:shinkawa.misaki@gmail.com)

## ライセンス
Apache License 2.0
