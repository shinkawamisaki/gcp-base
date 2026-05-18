# 品質管理とフィードバックループ (Quality Assurance & Feedback Loop)

本ドキュメントは、本GCP基盤におけるAI生成コードの品質管理アーキテクチャ、および継続的な品質改善のためのフィードバックループについて定義する。

---

## 1. 全体構造
本プロジェクトでは、コードの自動生成から本番デプロイに至るプロセスを複数のレイヤーに分割し、段階的に品質を保証する。AIによる主観的検証と、ツールによる客観的検証を適材適所で組み合わせることで、検証コスト（時間・金銭）の最適化を図っている。

```mermaid
flowchart TD
    L0["**Layer 0**<br>コーディング<br>Cline + .clinerules"]
    L1["**Layer 1**<br>pre-commit<br>gitleaks + Checkov<br>ローカルで即時フィードバック<br>（スキップ可）"]
    L2["**Layer 2**<br>PR時の自動検査（並列）<br>強制ゲート（スキップ不可）<br>A: gitleaks　B: Checkov　C: terraform plan<br>D: Gemini AI　E: CodeQL"]
    L3["**Layer 3**<br>デプロイ<br>terraform apply<br>prd-org-policy-sa"]

    L0 -->|git commit| L1
    L1 -->|git push → PR作成| L2
    L2 -->|全チェックPASS → mainマージ| L3
```

---

## 2. Layer 2 の詳細：判定基準と責任分界点

Layer 2における各検証プロセスは、その判定基準となる「根拠」によって明確に役割が分担されている。外部標準に基づく客観的なチェックと、プロジェクト固有の設計思想に基づくAI検証を分離することが本設計の核心である。

```mermaid
flowchart LR
    CR[".clinerules<br>役割分担を明記"]

    CR -->|客観的・静的<br>外部標準に委譲| EXT
    CR -->|設計思想が要るもの<br>AIに残す| AI

    subgraph EXT["外部標準"]
        A["**A: gitleaks**<br>公式デフォルトルールセット<br>シークレット検知"]
        B["**B: Checkov**<br>CIS GCP Benchmark<br>IAM・削除保護・VPC Flow Logs"]
        C["**C: terraform plan**<br>HashiCorpエンジン<br>差分の事実を表示"]
        E["**E: CodeQL**<br>GitHub公式<br>Pythonコードの脆弱性"]
    end

    subgraph AI["プロジェクト固有"]
        D["**D: Gemini**<br>.clinerules（憲法）<br>+ active_rules.md（判例）<br>prd-プレフィックス・Shared VPC・SA境界"]
    end
```

| レイヤー | 根拠 | 判定主体 |
|---|---|---|
| A（gitleaks） | gitleaks公式デフォルトルールセット | OSSコミュニティ |
| B（Checkov） | CIS Google Cloud Platform Foundation Benchmark | CIS（国際標準団体） |
| C（terraform plan） | Terraform エンジンの差分計算 | HashiCorp |
| D（Gemini） | `.clinerules`（憲法）+ `logs/active_rules.md`（判例） | プロジェクト設計 |
| E（CodeQL） | GitHub公式セキュリティクエリ | GitHub Security Lab |

---

## フィードバックループ

### Layer 0（開発 AI エージェント）

開発を担当するAIエージェント（Cline）はセッション間でコンテキストを保持しないため、ルールやプロジェクト固有の微調整をファイルシステム上に記憶として永続化する。

```mermaid
flowchart TD
    CODE["clinerules を読んでClineがコードを書く"]
    EVENT["設計変更・差し戻し・背景の共有"]
    NOTES["log/ai-notes.md<br>に申し送りを追記"]
    NEXT["次のセッション開始時に<br>AIが読み込む"]
    RESULT["同じ失敗・同じ質問を繰り返さない"]

    CODE --> EVENT --> NOTES --> NEXT --> RESULT
```

> **特性:** 本レイヤーのフィードバックループは、人間による明示的な記録（`log/ai-notes.md`の更新）に依存する。

---

### Layer 2 D（検証 AI エージェント）

Pull Request作成時に自動実行されるAIレビューのフィードバックループ。継続的な運用に耐えうるよう、人間向けとAI向けの記録ファイルを分離している。
- `logs/judgments.md`: 人間が下した判断の全履歴（Append-only）。IPO監査や経緯確認用。
- `logs/active_rules.md`: AIが参照する現在有効なルールのスナップショット。同トピックは上書きされ、コンテキスト長を節約する。

```mermaid
flowchart TD
    FAIL["GeminiがFAILを出す<br>or<br>人間が判定ミスに気づく"]
    HUMAN["人間が判断<br>（エスカレーション）"]
    J["logs/judgments.md に追記<br>append-only・削除禁止"]
    AR["logs/active_rules.md を更新<br>upsert・最新判断のみ<br>同トピックは上書き"]
    PR["次のPR時に<br>pr_reviewer.py が自動で読み込む"]
    UP["Geminiの判定精度が上がる"]

    FAIL --> HUMAN --> J
    HUMAN --> AR
    J -->|同時に更新| AR
    AR --> PR --> UP
```

> **特性:** 判例が蓄積されるほど自律的に検証精度が向上する。人間の介入は「最終判断の明文化」のみで完結する。

---

### 検証ツールの性質とフィードバック方向の非対称性
外部標準に依存するツール（A, B, C, E）の検知漏れはツールのカバレッジ限界に起因するが、プロジェクト固有のAI検証（D）の検知漏れは「判例の不足」または「プロンプトの曖昧さ」に起因する。
さらに、フィードバックループが精度に与える「作用の方向性」もツールによって異なる。

```text
A の取りこぼし → .gitleaks.toml の見直し（allowlistの縮小）
B の取りこぼし → .checkov.yaml の見直し（skip-checkの削減）+ judgments.md への記録
C の取りこぼし → terraform plan の人間によるレビュープロセス改善
D の取りこぼし → judgments.md へ判例追加 → active_rules.md 更新 → 次回PRから自動適用
E の取りこぼし → CodeQL設定見直し ＋ 脆弱性パターンを active_rules.md に移植し D(AI) を強化
```

```mermaid
flowchart LR
    subgraph LOOSE["緩める方向にしか動かない"]
        A2["A: gitleaks<br>allowlistに追記"]
        B2["B: Checkov<br>skip-checkに追記<br>※judgments.md参照必須"]
        C2["C: terraform plan<br>フィードバックループなし<br>（事実の表示のみ）"]
    end

    subgraph TIGHT["精度を上げる方向に動く"]
        D2["D: Gemini<br>judgments.md + active_rules.md<br>の二層構造"]
        E2["E: CodeQL<br>GitHub Code Scanningに蓄積<br>→ active_rules.mdに判例追加"]
    end
```

外部標準のツールは例外処理を追加する（制約を緩める）方向のフィードバックが主となるが、AIやCodeQLは新しい検知ルールを学習・追加する（精度を上げる）方向のフィードバックが機能する。

```mermaid
flowchart TD
    J2["logs/judgments.md<br>append-only・削除禁止<br>人間が下した判決の全履歴"]
    AR2["logs/active_rules.md<br>upsert・最新のみ<br>AIが参照する現在有効な判例"]
    PR2["GitHub PRコメント<br>Geminiの判定結果<br>PASS / FAIL + 理由"]
    CS["GitHub Commit Status<br>マージブロックの根拠"]
    GCS["GCS change-logs/<br>自動生成・PASS時のみ<br>逆引き仕様書<br>誰が何のために何を変えたか"]
    DD["Datadog<br>gcp.ai_verifier.review<br>result / author / category タグ<br>FAIL傾向の可視化"]
    CSCAN["GitHub Code Scanning<br>CodeQL + Checkov SARIF<br>セキュリティアラートの集約"]

    J2 -->|同時に更新| AR2
    AR2 -->|pr_reviewer.py が毎PR読み込む| PR2
    PR2 --> CS
    PR2 --> GCS
    PR2 --> DD
    CSCAN -->|アラート発生時<br>active_rules.mdへ判例追加| AR2
```

## 3. バグ発生時のトラブルシューティングと切り分け

本番環境または結合テストで問題が発覚した場合、以下のフローに従って原因となった検証レイヤーを特定し、フィードバックループを回す。

```mermaid
flowchart TD
    BUG["バグ発生"]
    Q{"バグの性質は？"}

    BUG --> Q

    Q -->|シークレット・トークンが混入| A3
    Q -->|roles/owner・IAMワイルドカード<br>削除保護なし| B3
    Q -->|Terraform構文エラー<br>意図しないリソース差分| C3
    Q -->|Pythonコードの脆弱性<br>平文ロギング等| E3
    Q -->|設計思想違反<br>prd-プレフィックスなし<br>Shared VPC・SA境界混在| D3

    A3["**A（gitleaks）の取りこぼし**<br>原因: allowlistが広すぎる<br>対処: .gitleaks.tomlを見直す"]
    B3["**B（Checkov）の取りこぼし**<br>原因: skip-checkが広すぎた<br>対処: .checkov.yamlを見直す<br>+ judgments.mdに記録"]
    C3["**C（terraform plan）の取りこぼし**<br>原因: planを人間が見ていなかった<br>対処: レビュープロセスを見直す"]
    E3["**E（CodeQL）の取りこぼし**<br>原因: クエリがカバーしていない<br>対処: active_rules.mdに判例追加"]
    D3["**D（Gemini）の取りこぼし**<br>原因: active_rules.mdに判例がなかった<br>対処: judgments.md追記<br>→ active_rules.md更新<br>→ 次PRから自動反映"]
```

---

## 4. 運用上の課題と今後の展望

### 4.1 フィードバックループの人手依存
現状、各種ログファイル（`judgments.md`, `active_rules.md`, `ai-notes.md`）の更新は人間の介入を前提としている。今後はIssueやPRの議論からAIが自動で判例ドラフトを作成する仕組みが望まれる。

### 4.2 terraform plan の自動ゲート化
現在 `terraform plan` の結果はPRにコメントされるのみであり、破壊的変更を機械的にブロックする仕組みが存在しない。OPA（Open Policy Agent）や Sentinel の導入によるポリシーのコード化（Policy as Code）が今後の課題である。

### 4.3 Datadog アラートの欠如
AI検証の合否メトリクスはDatadogに送信されているものの、連続FAIL等の異常検知アラートが設定されていない。監視基盤の拡充が必要である。

### 4.4 バグ切り分けの自動化（構想）
CodeQLやCheckovのアラートを自動で分類し、Issue起票からAI検証ルールの更新までを一気通貫で行うシステムの構築を構想している。

```mermaid
flowchart TD
    ALERT["GitHub Code Scanning<br>アラート発生"]
    WF["code_scanning_alert<br>ワークフローが起動"]
    PARSE["rule.id で自動分類<br>CKV_GCP_* → B<br>gitleaks-* → A<br>その他 → D"]
    SEV{"重大度"}
    ISSUE["GitHub Issueを自動起票<br>+ judgments.md追記を促す"]
    ISSUE2["Issue起票のみ<br>（追記は任意）"]
    TRIAGE["pr_reviewer.py を<br>triage modeで実行<br>「どのルールで防げたか」を<br>Geminiに問う"]
    UPDATE["judgments.md → active_rules.md 更新<br>次PRから自動反映"]

    ALERT --> WF --> PARSE --> SEV
    SEV -->|CRITICAL / HIGH| ISSUE
    SEV -->|MEDIUM以下| ISSUE2
    ISSUE --> TRIAGE --> UPDATE
```

既存の `pr_reviewer.py` をTriage Modeとして転用することで、この自動分類機能は実装可能である。

### 4.5 自動化の境界と人間の役割（設計哲学）
障害の根本原因や「例外か違反か」の判断は、プロジェクトの設計思想に深く依存するためAIによる完全自動化は困難である。したがって、本システムの自動化のゴールは**「人間の判断を要求するところまで情報を整理して運ぶこと」**に設定している。
ウォーターフォール開発における「バグの流出フェーズ分析」と同様に、AI駆動開発においても「どのツール/プロンプトがそのバグを検出すべきだったか」を特定し、適切なレイヤーの仕組みを改善することが、長期的な品質安定化の鍵となる。

---

## 5. レイヤーごとの責務と仕組みの強制

開発体験とセキュリティ・ガバナンス要件を両立するため、以下の役割分担を定義する。

* **Layer 1（pre-commit）:** gitleaks + Checkov 
  * **目的:** 開発者への即時フィードバック
  * **制約:** スキップ可（ローカルの柔軟性確保）
* **Layer 2（PR）:** gitleaks + Checkov + AI Review 
  * **目的:** 本番環境への危険なコードの混入防止
  * **制約:** 強制ゲート（GitHub Actions Required Status Checksによるスキップ不可）

### Layer 1 の確実な運用（仕組み化）
Layer 1 は開発者のローカル環境に依存するため、「インストール忘れ」によるすり抜けリスクが存在する。これを防ぐため、本プロジェクトでは**初期セットアップスクリプト（`scripts/bootstrap.sh`等）に `pre-commit` のインストールを組み込み、開発参加時に自動的かつ強制的に仕組みが適用される**アーキテクチャを採用している。
