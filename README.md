# GCP-base: Google Cloud 基盤構築キット

「ベンチャーの基盤」を前提に設計したGCPの基盤構築キットです。ベンチャーだから「開発スピードは落としたくない」としながらも「いつかのIPO」や「お客さんの個人情報を扱う」ためのセキュリティとガバナンスを担保しています。

## 主な機能 (Core Features)

1.  **GitOps によるProject Factory**
    - `inventory.json` を更新することで、プロジェクト作成から WIF・予算設定まで自動実行します。
2.  **台帳同期型サンドボックス**
    - 期限が来ると「台帳（Git）」と「実体（GCP）」を自動でクリーンアップして、ゾンビ化を物理的に防止します。
3.  **職務分掌による安全なデプロイ**
    - 本番の書き換えを中央の Runner に集約しました。最小権限（Viewer）での安全なアプリ運用を強制します。
4.  **AI による週次セキュリティ監査**
    - Gemini 2.5-flash が「今すぐ対応すべき Top 5」を抽出してSlack 通知でおしらせします。
5.  **開発者向け自動セットアップ**
    - プロジェクト完成時、開発者はサンプルキットをDLするだけでWIFによるapply/deployが可能に。
6.  **AI 駆動型クロス検証 (Cloud Build CI)**
    - Gemini 2.5-flash が Pull Request 作成時に設計思想 (`.clinerules`) および過去の人間判断 (`logs/active_rules.md`) との整合性を自動レビュー。承認された変更の逆引き仕様書（変更証跡）を自動生成してGCSバケットに直送・保存し、検証結果を GitHub PR コメントとしてフィードバック（Suggested Changes 含む）します。
7.  **CIS GCP ベースライン Checkov (governance / modules)**
    - Google Cloud CIS Benchmark に基づく Checkov が `governance/` と `modules/` を対象に MEDIUM 以上の脆弱性をハードフェイルでブロック。客観的なIAM・ネットワーク・削除保護チェックはツールに委譲し、AIは設計判断に集中します。
8.  **Datadog メトリクス監視（ON/OFF 切り替え可）**
    - AI検閲の結果（pass/fail）を `result` / `category` / `author` 等のリッチなタグ付きで Datadog へ送信。`DATADOG_ENABLED=false` 1行で無効化可能。


## 前提条件 (Prerequisites)

本プロジェクトのデプロイと運用には以下の環境が必要です。

- **Terraform:** `>= 1.5.0` (推奨: 最新の 1.x 系)
- **Google Cloud SDK (gcloud):** 最新版を推奨
- **Python:** `3.11` (通知用 Cloud Functions のランタイム)
- **GCP 権限:** 組織管理者 (Organization Administrator) またはそれに準ずる権限

## ディレクトリ構成 (Directory Structure)

```text
gcp-base/
├── .clinerules             # AIへのプロジェクト憲法（設計原則・禁止事項）
├── .checkov.yaml           # Checkov CIS GCP 設定（意図的除外の管理）
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
├── logs/
│   ├── judgments.md        # 人間による判断の監査証跡（append-only）
│   └── active_rules.md     # AIが読む判例集（upsert運用・行数一定）
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
4. **Git フックの有効化（任意）**: ローカルでのフォーマットチェック等を有効にするため、以下のコマンドを実行します。
   ```bash
   git config core.hooksPath .githooks
   ```
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

#### 📝 inventory.json の設定サンプル
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

- **IPO対応のガバナンス**: `owner` や `editor` などの強い基本ロールを排除し、原則としてIAM条件(Conditions)を用いた時間的・スコープ的に限定された権限のみを使用。
- **自律的レビュー**: コード変更はマージ前に `.clinerules` に基づいて AI (Gemini) が自律的にレビューし、違反があればブロック（Fail-Closed）。
- **WIF の厳格化**: 各リポジトリのブランチに対して最小権限の Service Account を紐づけ、ワイルドカード（*）による認証を禁止。

## AIとのフィードバックループ（判例集の二重運用）

AIによる自動検閲が厳しすぎる場合や、プロジェクト特有の例外を許可する場合、AI同士で勝手に妥協せず人間に判断を仰ぎます。その際の「人間が下した判断」は、**監査証跡とAIコンテキスト供給の要件の違いを分離**するため、以下の2つのファイルで運用されます。

1. **`logs/judgments.md`（IPO監査用の証跡）**
   - いつ誰がなぜ例外を許可したかという証跡を **Append-only** で全て残します。AIはこのファイルは読みません（コンテキストウィンドウの枯渇を防ぐため）。
2. **`logs/active_rules.md`（AIに読ませる判例集）**
   - トピック（例: Draft PRの例外処理など）ごとに最新の判断のみを **Upsert（上書き）** して書き込みます。行数が無限に増えないため、AIへのコンテキスト供給を軽量かつコンパクトに保ちながら、過去の「判例」を憲法より優先して適用させることができます。

## 初期セットアップのヒント (Tips)

- **GitHub App (推奨):** サンドボックスの自動削除機能（Git台帳更新）および GitHub Variables の自動同期に使用します。ガバナンスの観点から、特定のリポジトリにのみ権限を絞った GitHub App の利用を強く推奨します。

    - **必要な 3 要素**:
        - `App ID`: App の基本情報ページに記載されている数字。
        - `Private Key`: 生成・ダウンロードした `.pem` ファイルの中身（全文）。
        - `Installation ID`: App を Organization/Repository にインストールした際の URL 末尾にある数字。
    - **推奨される権限 (Repository permissions)**:
        - `Contents`: **Read & write** (台帳 `inventory.json` の自動更新用)
        - `Actions`: **Read & write** (削除ワークフローのトリガー用)
        - `Variables`: **Read & write** (プロジェクト作成時の変数自動同期用)
    - **設定方法**: `scripts/setup_secrets.sh` を実行し、上記 3 つの値を入力してください。

- **GitHub Fine-grained PAT (非推奨):** 以前のバージョンとの互換性のために残されていますが、近日中に廃止予定です。新規構築時は上記 GitHub App を使用してください。

### 💡 組織ポリシー設定で 409 エラー (Already Exists) が出た場合
既に Google Cloud 組織レベルで何らかのポリシーが設定されている場合、`governance/org-policies` の実行時に「リソースが既に存在する」というエラーが発生することがあります。その場合は、以下のコマンドで既存の設定を Terraform の管理下にインポートしてください。

```bash
# 例: ドメイン制限ポリシーのインポート
terraform import google_org_policy_policy.legacy_allowed_domains organizations/YOUR_ORG_ID/policies/iam.allowedPolicyMemberDomains
```
## Changelog
 [1.5.0] - 2026-05-12
- [Feature] CIS Google Cloud Platform Foundation Benchmark に基づく Checkov を `governance/` と `modules/` に追加。`.checkov.yaml` で除外設定を一元管理。
- [Refactor] `.clinerules` の3・4章から Checkov が機械的に検知できる項目（最小権限・ワイルドカード禁止・削除ロック等）を削除し、AIは設計判断に集中させる構造に整理。
- [Feature] `logs/active_rules.md` を新設。AIが読む判例集として upsert 運用（行数が増えない）。`judgments.md`（監査証跡）と役割を分離。
- [Feature] `pr_reviewer.py` が `logs/active_rules.md` を読み込み、過去の人間判断を憲法より優先して適用するように変更。
- [Feature] Datadog メトリクスを `DATADOG_ENABLED` 環境変数で ON/OFF 切り替え可能に。送信タグを `result` / `category` / `author` / `is_draft` 等のリッチな構成に刷新。AIの FAIL 判定時に違反カテゴリ（IAM / SECRET / NETWORK 等）を Datadog タグとして送信。

 [1.4.2] - 2026-05-10
- [Feature] AI検閲官（Cloud Build版）の実行結果（PASS数など）をDatadogカスタムメトリクスとして送信する機能を追加統合。

 [1.4.1] - 2026-05-10
- [BugFix] AI検閲官のフィードバックコメントが英語で出力される問題を修正し、完全な日本語出力を強制。
- [BugFix] Cloud BuildでのCI実行時に発生するGitHub APIの認証エラー（403 Forbidden）および環境変数の参照エラーを修正。

 [1.4.0] - 2026-05-10
- [Feature] AI検閲官の実行環境をローカルの pre-commit から Cloud Build (CI) へ移行し、Pull Request に対する自動レビュー機能へ進化（DX最適化）。
- [Feature] GitHubの Suggested Changes を用いた修正案の自動提案機能を実装。

 [1.3.1] - 2026-05-06
- [BugFix] Datadog送信スクリプトにてCodeQL（SAST）警告となるシークレット名の平文ログ出力を修正。
- [Update] プロジェクト憲法（`.clinerules`）に静的解析(SAST)対応および機密情報の平文ログ出力禁止ルールを追記。

 [1.3.0] - 2026-05-04
- [Feature] コミット前にGeminiによるAIクロス検証(Pre-commit Hook)を追加し、承認された変更の逆引き仕様書をGCSへ自動保存・Datadogへメトリクス送信するよう実装。
- [Feature] アプリ・サンドボックス環境向けに、Checkovによるセキュリティガードレールを導入（脆弱性を含むコードをCIでブロック）。

 [1.2.1] - 2026-04-26
- [BugFix] 実行ログにおける機密情報およびメタデータの露出を修正。
- 各種ボット（ライフサイクル、監査）の実行ログに含まれていたプロジェクトIDを末尾4桁に匿名化。
- アクセス失敗時の例外内容およびシークレット名をログから排除（抽象的なセキュリティ通知へ変更）  。

 [1.2.0] - 2026-04-25
[Feature]認証をGithub PATからGithub APPに変更
- サンドボックスの自動削除・開発者がプロジェクトでデプロイを行う際の認証をGithub PATからGithub APPに変更。
- [BugFix]Boostrap　2回目以降実行時、バケットに条件付きポリシーが存在する場合、add-iam-policy-binding は非対話モードで  --condition=None（または明示的な条件）を要求するため処理が止まるエラーを修正。

 [1.1.1] - 2026-04-12
- [BugFix]サンドボックス削除処理改修（削除対象がない時エラーで止まる不具合）

- [Update]プロジェクト払い出し時のslack内容・通知先の修正

 [1.1.0] - 2026-04-11
[Feature]APPデプロイ・パイプラインの刷新
- 自動連鎖デプロイ：これまでは push するとstg環境だけにデプロイされていましたが、今回の修正で 「まずdev環境 へ。成功したら自動でstg環境へ」 と、1 回のプッシュで複数の環境を順番に更新できるようになりました。
- 設定ガイド連動型の自動スキップ ：dev環境を持っていないプロジェクトでも同じワークフローが使えるよう、ID_DEV が空欄なら Actionsが自分で判断してdevデプロイをスキップしstgから開始する仕組みを導入しました。
- テンプレート化による共通化 :複雑なデプロイ命令を _deploy_template.yml に1箇所にまとめたことで、インデントミスや設定漏れが起きにくい、メンテしやすい構造に刷新しました。

 [1.0.2] - 2026-04-10
- [BugFix]サンドボックス削除通知・削除処理バグ改修（削除期限の値の受け渡し漏れ、削除期限判定の誤り）
- PROJECT_GUIDE.md:ドキュメント内のymlの名称修正
- ARCHITECTURE.md:依存関係（depends on）、ログ、通知について記載

 [1.0.1] - 2026-04-09
- [BugFix]Uploadし忘れていたフォルダ（module）追加
- [BugFix]サンドボックス削除権限が不足していたため追加
- [BugFix]サンドボックス作成時既存データについてもslack通知するバグ改修

 [1.0.0] - 2026-04-09
- 初回リリース

## 作者 (Author)

**shinkawa.misaki**

- **GitHub**: [shinkawamisaki](https://github.com/shinkawamisaki)
- **YOUTRUST**: [shinkawa](https://youtrust.jp/users/shinkawa)
- **Email**: [shinkawa.misaki@gmail.com](mailto:shinkawa.misaki@gmail.com)

## ライセンス
Apache License 2.0
 
