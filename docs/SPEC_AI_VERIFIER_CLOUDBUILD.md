# AI検閲官 (Cloud Build版) 実装仕様書

本ドキュメントは、ローカルの `pre-commit` フックで動作していたAIコードレビューを、Cloud Buildベースの非同期PRフィードバックループへ移行するための**実装・コーディング用仕様書**です。AIエージェント（Cline等）がこのドキュメントを読み、迷いなくコードを生成・修正できるレベルの具体性を持ちます。

## 1. 移行のスコープと目標

*   **対象**: `scripts/cross_verify.sh` および関連する検証ロジック。
*   **移行先**: Dockerコンテナ化され、Cloud Build上で動作するPythonアプリケーション。
*   **トリガー**: GitHubのPull Request作成・更新時。
*   **主要な変更点**:
    *   ローカルでの `git diff` から、GitHub PRの差分取得へ変更。
    *   ターミナルへの出力から、GitHub PRへの自動コメント（Suggestion含む）へ変更。
    *   Bashスクリプトから、保守性の高いPythonスクリプトへの完全移行。

### 1.1 アーキテクチャ進化の背景と理由

本仕様は、初期構想から実践的な運用を見据えて以下の3点で設計がシフトしています。

1. **実行環境の「クラウド化・標準化」**
   * **最初**: 開発者のローカルPCで動く `pre-commit`（スクリプト）想定。
   * **最終**: Cloud Build + Docker によるCI/CD統合。
   * **理由**: 自律型AIは、自分のローカル環境でスクリプトを回避したり書き換えたりするリスクがあります。クラウド側（CI）でコンテナを動かして検閲することで、AIが回避不能な物理的なガードレールにしました。
2. **監視の目的が「AI警察（ガードレール）」にシフト**
   * **最初**: 人間のエンジニアの「うっかりミス」を防ぐサポーター。
   * **最終**: AIエージェントが勝手に権限を広げないか監視する「検閲官」。
   * **理由**: 精鋭エンジニアが不在（副業）の間に、AIエージェントが「動かすこと」を優先してIAM権限をガバガバにするのを防ぐため、より「セキュリティ・統制」に特化した役割に変更しました。
3. **「証跡の保存先」の現実化（コストと実用性）**
   * **最初**: ログや逆引き仕様書を Datadog に保存（案）。
   * **最終**: PRへの自動コメント ＋ GCS（Google Cloud Storage）への保存。（※Datadogへの保存もオプションとして選択可能）
   * **理由**: プレシリーズAでDatadogに長文ドキュメントを貯めるとコストが重すぎるため、開発者がすぐ見れる「PRコメント」と、監査法人が後で確認できる「GCS」に分けることで、現実的かつ安価な構成にしました。Datadogを使う実装部分もオプションとして残しており、将来的な要件に応じて選べるようにしています。

## 2. 変更・新規作成が必要なファイル一覧

| ファイルパス | アクション | 概要 |
| :--- | :--- | :--- |
| `docker/ai-verifier/Dockerfile` | 新規作成 | AI検閲官の実行環境（Python 3.11ベース） |
| `docker/ai-verifier/requirements.txt` | 新規作成 | 依存ライブラリ（`google-generativeai`, `requests`, `datadog` 等） |
| `scripts/pr_reviewer.py` | 新規作成 | AI検閲のメインロジック（`cross_verify.sh` のPython移植版） |
| `cloudbuild-pr.yaml` | 新規作成 | PR時に発火するCloud Buildのパイプライン定義 |
| `governance/admin/foundation/build.tf` | 修正/追記 | Artifact Registry, Cloud Build Trigger, IAM権限の定義 |
| `governance/admin/foundation/secrets.tf` | 修正/追記 | GitHub Token等のシークレット定義 |
| `.githooks/pre-commit` | 修正 | `cross_verify.sh` の呼び出しを削除（フォーマッタ等は残す） |

## 3. 各コンポーネントの実装詳細

### 3.1 Docker環境 (`docker/ai-verifier/`)

*   **ベースイメージ**: `python:3.11-slim`
*   **インストールパッケージ**: `git`, `jq` (OSパッケージ)
*   **Pythonパッケージ**:
    *   `google-generativeai` (Gemini API呼び出し)
    *   `requests` (GitHub API呼び出し用)
    *   `datadog` / `ddtrace` (メトリクス送信・オブザーバビリティ)

### 3.2 メインロジック (`scripts/pr_reviewer.py`)

現在の `cross_verify.sh` の後継となるPythonスクリプトです。Cloud Build環境で実行されます。

**環境変数**:
*   `PROJECT_ID`: GCPプロジェクトID
*   `GITHUB_TOKEN`: GitHub API操作用トークン
*   `REPO_FULL_NAME`: リポジトリ名（例: `shinkawamisaki/project-23378`）
*   `PR_NUMBER`: プルリクエスト番号
*   `COMMIT_SHA`: 対象コミットハッシュ

**処理フロー**:
1.  **差分取得**: GitHub API (`/repos/{owner}/{repo}/pulls/{pull_number}/files` または `git diff`) を使用してPRの差分を取得。
2.  **機密情報のマスク**: 正規表現によるパスワード・IPのマスク（既存ロジック踏襲）。
3.  **AIプロンプト構築**: **PRブランチ上の最新の `.clinerules`** と差分を結合。これにより、憲法自体のアップデート時も新しいルールで検閲が可能になります。また、開発者がワンクリックで修正を取り込めるよう、**GitHubの Suggested Changes 形式（` ```suggestion `）**で具体的な修正コードを出力するようにプロンプトで指示を追加します。
4.  **Gemini API呼び出し**: `gemini-1.5-flash` を使用。Context Cachingの利用を検討（`.clinerules` が巨大な場合）。
5.  **結果解析とGitHubフィードバック**:
    *   **ノイズ管理（重要）**: 毎回新規コメントを投稿してタイムラインを埋め尽くさないよう、**既存のボットのコメントが存在する場合はそれを Update する**ロジックを実装します。
    *   **Draft PRの聖域化（DX向上）**: 対象のPRが「Draft」状態である場合、AIは検証とコメント（Suggestion含む）までは行いますが、たとえFAIL判定であってもStatus Checkは必ず「Success（またはNeutral）」として通過させます。これにより、開発中の「とりあえず動かして試したい」というスピード重視の作業を阻害せず、かつガバナンスも犠牲にしない開発体験を提供します。
    *   **PASSの場合**: PRの既存コメントを「✅ AI検閲を通過しました」に更新し、Status CheckをSuccessに。
    *   **FAILの場合（Ready for Review時）**: GitHub APIを用いて、AIの指摘事項と修正案（Suggestion）をPRコメントとして更新/投稿。Status CheckをFailureにし、マージを物理的にブロックします。
6.  **逆引き仕様書生成**: PASSした場合、Geminiにドキュメントを生成させ、GCS (`gs://[PROJECT_ID]-changelog-store/`) へアップロード。（※設定により、Datadogへのドキュメント送信も選択可能）
7.  **Datadogメトリクス送信（オプション）**: 検証結果、トークン使用量、実行時間を送信。さらに分析の質を上げるため、LLMObsのタグに **`result:pass` や `result:fail` などのカスタムタグ**を明示的に付与し、不合格の傾向（特定のファイルや時間帯）を分析可能にするオプションを残しています。

### 3.3 Cloud Build パイプライン (`cloudbuild-pr.yaml`)

PRトリガーで実行される定義ファイルです。

```yaml
steps:
  - name: 'us-central1-docker.pkg.dev/$PROJECT_ID/infra-tools/ai-verifier:latest'
    entrypoint: 'python'
    args: ['/app/scripts/pr_reviewer.py']
    secretEnv: ['GITHUB_TOKEN', 'DATADOG_API_KEY']
    env:
      - 'PR_NUMBER=$_PR_NUMBER'
      - 'REPO_FULL_NAME=$REPO_NAME'
      - 'COMMIT_SHA=$COMMIT_SHA'

availableSecrets:
  secretManager:
    - versionName: projects/$PROJECT_ID/secrets/github-token-pr-reviewer/versions/latest
      env: 'GITHUB_TOKEN'
    - versionName: projects/$PROJECT_ID/secrets/infra-datadog-api-key/versions/latest
      env: 'DATADOG_API_KEY'
```

### 3.4 インフラリソース定義 (`governance/admin/foundation/`)

Terraformで以下のリソースを構築（または追記）します。

1.  **Artifact Registry**: `ai-verifier` コンテナイメージの保存先 (`infra-tools` リポジトリ等)。
2.  **Secret Manager**:
    *   `github-token-pr-reviewer`: GitHub PRにコメントを書き込むための権限（`repo`）を持ったPAT（Personal Access Token）。
3.  **Cloud Build Trigger**:
    *   対象リポジトリのPRイベント（作成・更新）で発火。
    *   代入変数（Substitutions）として `_PR_NUMBER` 等を渡す設定。
    *   （※GitHub App連携が前提）
4.  **IAM権限 (Cloud Build Service Account)**:
    Cloud BuildのデフォルトSA（またはカスタムSA）に対して以下を付与。
    *   `roles/secretmanager.secretAccessor` (特定のシークレットのみ)
    *   `roles/storage.objectAdmin` (Changelogバケットへの書き込み用)
    *   `roles/aiplatform.user` (Vertex AI / Gemini 呼び出し用)

## 4. AI (Cline) への実装指示

この設計書に基づき、以下のステップで実装を進めてください。

*   **Step 1**: `docker/ai-verifier/Dockerfile` と `requirements.txt` を作成する。
*   **Step 2**: `scripts/cross_verify.sh` のロジックを読み解き、GitHub APIと連携する `scripts/pr_reviewer.py` を実装する。
*   **Step 3**: `cloudbuild-pr.yaml` をプロジェクトルートに作成する。
*   **Step 4**: `governance/admin/foundation/` 配下のTerraformコードを修正し、Cloud Buildトリガー、Artifact Registry、IAM権限、Secret Manager定義を追加する。
*   **Step 5**: ローカルの `.githooks/pre-commit` から `cross_verify.sh` の呼び出しを削除し、ローカル検証からクラウド検証への切り替えを完了させる。
