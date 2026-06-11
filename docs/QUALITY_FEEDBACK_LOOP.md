# 品質管理とフィードバックループ (Quality Assurance & Feedback Loop)

本ドキュメントは、本GCP基盤におけるAI生成コードの品質管理アーキテクチャ、および継続的な品質改善のためのフィードバックループについて定義する。

---

## 1. 全体構造
本プロジェクトでは、コードの自動生成から本番デプロイに至るプロセスを複数のレイヤーに分割し、段階的に品質を保証する。AIによる主観的検証と、ツールによる客観的検証を適材適所で組み合わせることで、検証コスト（時間・金銭）の最適化を図っている。

```mermaid
flowchart TD
    L0["**Layer 0**<br>コーディング<br>Claude Code + CLAUDE.md<br>Stop hook で terraform validate"]
    L1["**Layer 1**<br>pre-commit<br>gitleaks + Checkov<br>ローカルで即時フィードバック<br>（スキップ可）"]
    L2["**Layer 2**<br>PR時の自動検査（並列）<br>強制ゲート（スキップ不可）<br>A: gitleaks　B: Checkov　C: terraform plan<br>D: Gemini AI　E: CodeQL<br>＋ D の回帰テスト（eval・検閲基準を変える PR のみ）"]
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

開発を担当するAIエージェント（Claude Code）はセッション間でコンテキストを保持しないため、必要な記憶を用途別に永続化先を分けてファイルシステム／個人メモリに残す。

> **writer と reviewer の関係:** 設計思想の正典は `.clinerules`（全モデル共通の憲法）で、writer・reviewer の双方がこれに従う。writer（Claude Code）は CLAUDE.md 経由で `.clinerules` を取り込み「正しいコードを書くため」に参照する。reviewer（Layer 2 D / Gemini）は同じ憲法で独立に照合する強制ゲート。二段レビューの価値は writer の無知ではなく「別モデル・独立したゲート」にあり、writer が「レビュー通過」を目的化しないことが要点（Goodhart の罠の回避）。

記憶の永続化先は次の3経路に分業する（Cline 時代の単一ノート `logs/ai-notes.md` は廃止）：

| 種別 | 永続化先 | 読む主体 |
|---|---|---|
| 設計思想・ルールの更新 | `CLAUDE.md` / `.clinerules` | writer（次回セッション） |
| 人間判断の判例 | `logs/judgments.md` → `logs/active_rules.md`（Layer 2 D に合流）＋ 対応ケースを `evals/cases/` に追加（回帰テストに固定化） | reviewer（Gemini）／ eval |
| 個人の作業習慣 | auto-memory（Claude Code 個人メモリ） | writer（自動） |

```mermaid
flowchart TD
    EVENT["設計変更・差し戻し・背景の共有"]
    R{種別で振り分け}
    RULE["CLAUDE.md / .clinerules<br>（設計・ルール）"]
    JUDGE["logs/judgments.md<br>（人間判断 → Layer 2 D へ合流）"]
    MEM["auto-memory<br>（個人の作業習慣）"]
    NEXT["次のセッションで<br>該当経路から読み込む"]

    EVENT --> R
    R --> RULE
    R --> JUDGE
    R --> MEM
    RULE --> NEXT
    MEM --> NEXT
```

> **特性:** かつては単一の `logs/ai-notes.md` に人間が申し送りを書いていたが、用途が上記3経路へ明確化されたため廃止した（固有だった判例は `logs/judgments.md` に移設・保全済み）。

---

### Layer 2 D（検証 AI エージェント）

Pull Request作成時に自動実行されるAIレビューのフィードバックループ。継続的な運用に耐えうるよう、人間向けとAI向けの記録ファイルを分離している。
- `logs/judgments.md`: 人間が下した判断の全履歴（Append-only）。IPO監査や経緯確認用。
- `logs/active_rules.md`: AIが参照する現在有効なルールのスナップショット。同トピックは上書きされ、コンテキスト長を節約する。

**ゲートの堅牢性（強制ゲートとして成立させるための設計）:**
- **Fail-Closed 判定**: 合格は `RESULT: PASS` の**明示一致**のみ。PASS/FAIL いずれにも一致しない出力（プロンプトインジェクション成功・形式逸脱）は「検閲不能」として扱う。従来の「FAIL を含まなければ合格」という否定形判定は合格側に倒れるため廃止。PR の diff は `<diff>` デリミタで囲み、diff 内の指示を実行しないようプロンプトで明示する。検閲不能をブロックにするかは `STRICT_AI_VERIFY`（本番運用では `true` 推奨）で制御する。
- **審査基準は base コミットから読む（自己参照の遮断）**: `.clinerules` / `active_rules.md` を PR 適用後ではなく **PR の base** から読む。これにより「ルール自体を骨抜きにする PR」を骨抜き前のルールで審査でき、判例の改変も削除前の基準で検閲される（diff は PR から取得するので変更内容は審査される）。判例の更新 PR が、その未承認の判例を自らの正当化に使うこともできない。
- **Draft PR の扱い**: Draft は FAIL でも非ブロックだが Status Check は Success ではなく **Pending**。Success にすると draft→ready 転換で再検閲が走らず FAIL のまま通過できるため、Pending で「Ready 時点から厳格にブロック」を技術的に強制する。
- **可用性の多層化**: Vertex 障害時は ①リトライ → ②フォールバックモデル（`gemini-2.5-pro`）→ ③フォールバックリージョン（`global`）の順に同一 ADC で自動切替。**別ベンダーの AI は使わない**（writer / reviewer の独立性維持・新規資格情報を増やさない）。

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
              ＋ evals/cases/ にケース追加 → 同じ判定ミスの再発を回帰テストで機械検知
E の取りこぼし → CodeQL設定見直し（クエリやdismissの調整のみ）
```

```mermaid
flowchart LR
    subgraph LOOSE["緩める方向にしか動かない"]
        A2["A: gitleaks<br>allowlistに追記"]
        B2["B: Checkov<br>skip-checkに追記<br>※judgments.md参照必須"]
        C2["C: terraform plan<br>フィードバックループなし<br>（事実の表示のみ）"]
        E2["E: CodeQL<br>dismissで無視<br>クエリ設定で除外<br>ルールはGitHub固定"]
    end

    subgraph TIGHT["精度を上げる方向に動く"]
        D2["D: Gemini<br>judgments.md + active_rules.md<br>の二層構造<br>＋ evals/cases（判例の回帰テスト固定化）"]
    end
```

フィードバックループで「判断ルール」に反映できるかどうかが、作用方向の分かれ目。CodeQLのルールはGitHub Security Lab固定であり、プロジェクト側でできるのはalert dismissやクエリ除外（制約を緩める方向）のみ。Geminiだけが判例の蓄積によって精度を上げる方向に動く。

```mermaid
flowchart TD
    J2["logs/judgments.md<br>append-only・削除禁止<br>人間が下した判決の全履歴"]
    AR2["logs/active_rules.md<br>upsert・最新のみ<br>AIが参照する現在有効な判例"]
    PR2["GitHub PRコメント<br>Geminiの判定結果<br>PASS / FAIL + 理由"]
    CS["GitHub Commit Status<br>マージブロックの根拠"]
    GCS["GCS change-logs/<br>自動生成・PASS時のみ<br>逆引き仕様書<br>誰が何のために何を変えたか"]
    DD["Datadog<br>gcp.ai_verifier.review<br>result / author / category タグ<br>FAIL傾向の可視化"]
    J2 -->|同時に更新| AR2
    AR2 -->|pr_reviewer.py が毎PR読み込む| PR2
    PR2 --> CS
    PR2 --> GCS
    PR2 --> DD
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
    E3["**E（CodeQL）の取りこぼし**<br>原因: クエリがカバーしていない<br>対処: CodeQL設定見直し（クエリ追加・dismiss調整）<br>※ active_rules.mdには連携しない"]
    D3["**D（Gemini）の取りこぼし**<br>原因: active_rules.mdに判例がなかった<br>対処: judgments.md追記<br>→ active_rules.md更新<br>→ evals/cases/ にケース追加<br>→ 次PRから自動反映・再発は機械検知"]
```

---

## 4. 運用上の課題と今後の展望

### 4.1 フィードバックループの人手依存
現状、各種ログファイル（`judgments.md`, `active_rules.md`）の更新は人間の介入を前提としている。今後はIssueやPRの議論からAIが自動で判例ドラフトを作成する仕組みが望まれる。

### 4.2 terraform plan の自動ゲート化
現在 `terraform plan` の結果はPRにコメントされるのみであり、破壊的変更を機械的にブロックする仕組みが存在しない。OPA（Open Policy Agent）や Sentinel の導入によるポリシーのコード化（Policy as Code）が今後の課題である。

### 4.3 AIレビュアー精度の機械検証（promptfoo evals）と Datadog の位置づけ
AIレビュアー（D）の判定精度は、ゴールデンセット（合格/不合格にすべき diff）への回帰テスト（`evals/` / promptfoo）でマージ前に機械検証する。

- 本番（`pr_reviewer.py`）と同一の `prompts/reviewer_prompt.txt` をテストするため、eval と本番のプロンプト乖離は構造的に発生しない
- 検閲基準（`.clinerules` / 判例集 / プロンプト / `evals/`）を変更する PR では、Cloud Build（`scripts/run_evals_ci.sh`）が eval を自動実行し、全ケース合格しないとマージできない（手動実行の「打ち忘れ」は構造的に発生しない）。無関係な PR では実行しない（障害半径の限定）
- 新しい判例の追加時に対応ケースを `evals/cases/` へ追加し、同じ判定ミスの再発を機械検知する（運用詳細は `evals/README.md`）

Datadog 送信（オプション機能）は実行結果の事後可視化であり、精度担保の主手段は上記の事前回帰テストに置く。Datadog 利用時は連続FAIL等の異常検知アラートが未設定という課題が残る。

### 4.4 GitHub Code Scanning との関係（設計上の決定）

GitHub Code Scanning（CodeQL + Checkov SARIF）はセキュリティアラートの履歴を蓄積するが、**`active_rules.md` への自動連携は行わない**という設計判断を下している。

理由は、CodeQLやCheckovが検出するのは「コードの客観的パターン」（未使用import、平文ロギング、IAMワイルドカード等）であり、これらはすでに静的解析ツールがカバーしている。「プロジェクトの設計思想を知らないと判定できない」という性質を持たないため、Gemini（D）に判例として学習させる必要がない。

```text
GitHub Code Scanning
  └─ CodeQL / Checkov SARIF アラート蓄積
       └─ alert dismiss / クエリ除外 でのみ対応（緩める方向）
            ※ active_rules.md には連携しない
```

> **判断基準:** `active_rules.md` に追加すべきなのは「同じ状況でGeminiが同じ判定ミスを繰り返す」ケースのみ。CodeQL findings はGitHub Code Scanningで管理し、ツールの設定（クエリ・dismiss）で対応する。

### 4.5 自動化の境界と人間の役割（設計哲学）
障害の根本原因や「例外か違反か」の判断は、プロジェクトの設計思想に深く依存するためAIによる完全自動化は困難である。したがって、本システムの自動化のゴールは**「人間の判断を要求するところまで情報を整理して運ぶこと」**に設定している。
ウォーターフォール開発における「バグの流出フェーズ分析」と同様に、AI駆動開発においても「どのツール/プロンプトがそのバグを検出すべきだったか」を特定し、適切なレイヤーの仕組みを改善することが、長期的な品質安定化の鍵となる。

---

## 5. レイヤーごとの責務と仕組みの強制

開発体験とセキュリティ・ガバナンス要件を両立するため、以下の役割分担を定義する。

* **Layer 0（コーディング）:** Claude Code の Stop hook（`terraform validate`）
  * **目的:** AI が `.tf` を変更したターンで自己検証し、構文エラーを次レイヤーへ送らない
  * **制約:** Claude Code 限定（Cline・手書きには非適用。ツール非依存の検証は Layer 1 / 2 が担う）
* **Layer 1（pre-commit）:** gitleaks + Checkov 
  * **目的:** 開発者への即時フィードバック
  * **制約:** スキップ可（ローカルの柔軟性確保）
* **Layer 2（PR）:** gitleaks + Checkov + AI Review + eval（D の回帰テスト）
  * **目的:** 本番環境への危険なコードの混入防止
  * **制約:** 強制ゲート（GitHub Actions Required Status Checksによるスキップ不可）
  * **eval（条件付き強制ゲート）:** 検閲基準（`.clinerules` / `logs/active_rules.md` / `prompts/` / `evals/`）を変更する PR でのみ、D と同一ビルド内（`scripts/run_evals_ci.sh`）でゴールデンセット回帰テストを実行し、全ケース合格しないとマージ不可。無関係な PR では実行しない（§4.3 参照）

### Layer 1 の確実な運用（仕組み化）
Layer 1 は開発者のローカル環境に依存するため、「インストール忘れ」によるすり抜けリスクが存在する。これを防ぐため、本プロジェクトでは**初期セットアップスクリプト（`scripts/bootstrap.sh`等）に `pre-commit` のインストールを組み込み、開発参加時に自動的かつ強制的に仕組みが適用される**アーキテクチャを採用している。
