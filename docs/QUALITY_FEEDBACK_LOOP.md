# 品質管理とフィードバックループ

コーディングからデプロイまでの品質がどう保証され、どう改善されていくかを整理したドキュメント。

---

## 全体構造

```mermaid
flowchart TD
    L0["**Layer 0**\nコーディング\nCline + .clinerules"]
    L1["**Layer 1**\npre-commit\n※クラウドに委譲済み・実質素通り"]
    L2["**Layer 2**\nPR時の自動検査（並列）\nA: gitleaks　B: Checkov　C: terraform plan\nD: Gemini AI　E: CodeQL"]
    L3["**Layer 3**\nデプロイ\nterraform apply\nprd-org-policy-sa"]

    L0 -->|git commit| L1
    L1 -->|git push → PR作成| L2
    L2 -->|全チェックPASS → mainマージ| L3
```

---

## Layer 2 の詳細：何を根拠に判定しているか

A〜Dは外部標準に乗り、Dはプロジェクト固有の判断をする。この役割分担が設計の核心。

```mermaid
flowchart LR
    CR[".clinerules\n役割分担を明記"]

    CR -->|客観的・静的\n外部標準に委譲| EXT
    CR -->|設計思想が要るもの\nAIに残す| AI

    subgraph EXT["外部標準"]
        A["**A: gitleaks**\n公式デフォルトルールセット\nシークレット検知"]
        B["**B: Checkov**\nCIS GCP Benchmark\nIAM・削除保護・VPC Flow Logs"]
        C["**C: terraform plan**\nHashiCorpエンジン\n差分の事実を表示"]
        E["**E: CodeQL**\nGitHub公式\nPythonコードの脆弱性"]
    end

    subgraph AI["プロジェクト固有"]
        D["**D: Gemini**\n.clinerules（憲法）\n+ active_rules.md（判例）\nprd-プレフィックス・Shared VPC・SA境界"]
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

### Layer 0（Cline）

Clineはセッションをまたいで記憶を持たないため、ファイルが記憶の代わりになる。

```mermaid
flowchart TD
    CODE["Clineがコードを書く\n.clinerules を読む"]
    EVENT["設計変更・差し戻し・背景の共有"]
    NOTES[".claude/cline-notes.md\nに申し送りを追記"]
    NEXT["次のセッション開始時に\nAIが読み込む"]
    RESULT["同じ失敗・同じ質問を繰り返さない"]

    CODE --> EVENT --> NOTES --> NEXT --> RESULT
```

> **特性：** 人間が `cline-notes.md` を書かないとループが回らない。人手依存。

---

### Layer 2 D（Gemini）

PRのたびに自動でファイルを読むため、ファイルを更新するだけでループが回る。

```mermaid
flowchart TD
    FAIL["GeminiがFAILを出す\nor\n人間が判定ミスに気づく"]
    HUMAN["人間が判断\n（エスカレーション）"]
    J["logs/judgments.md に追記\nappend-only・削除禁止\nIPO監査用の全履歴"]
    AR["logs/active_rules.md を更新\nupsert・最新判断のみ\n同トピックは上書き"]
    PR["次のPR時に\npr_reviewer.py が自動で読み込む"]
    UP["Geminiの判定精度が上がる"]

    FAIL --> HUMAN --> J
    HUMAN --> AR
    J -->|同時に更新| AR
    AR --> PR --> UP
```

> **特性：** 判例が積み重なるほど精度が上がる。人間の介入は「判断を書く」だけでよい。

---

### フィードバックの方向性の非対称性

```mermaid
flowchart LR
    subgraph LOOSE["緩める方向にしか動かない"]
        A2["A: gitleaks\nallowlistに追記"]
        B2["B: Checkov\nskip-checkに追記\n※judgments.md参照必須"]
        C2["C: terraform plan\nフィードバックループなし\n（事実の表示のみ）"]
    end

    subgraph TIGHT["精度を上げる方向に動く"]
        D2["D: Gemini\njudgments.md + active_rules.md\nの二層構造"]
        E2["E: CodeQL\nGitHub Code Scanningに蓄積\n→ active_rules.mdに判例追加"]
    end
```

> **リスク：** A・Bはskip/allowlistが積み重なるほど「意図的な例外か穴か」の管理コストが増える。Bはコメントと `judgments.md` 参照を義務付けることでこれを抑制している。

---

## 証跡の全体像

```mermaid
flowchart TD
    J2["logs/judgments.md\nappend-only・削除禁止\n人間が下した判決の全履歴\nIPO監査用"]
    AR2["logs/active_rules.md\nupsert・最新のみ\nAIが参照する現在有効な判例"]
    PR2["GitHub PRコメント\nGeminiの判定結果\nPASS / FAIL + 理由"]
    CS["GitHub Commit Status\nマージブロックの根拠"]
    GCS["GCS change-logs/\n自動生成・PASS時のみ\n逆引き仕様書\n誰が何のために何を変えたか"]
    DD["Datadog\ngcp.ai_verifier.review\nresult / author / category タグ\nFAIL傾向の可視化"]
    CSCAN["GitHub Code Scanning\nCodeQL + Checkov SARIF\nセキュリティアラートの集約"]

    J2 -->|同時に更新| AR2
    AR2 -->|pr_reviewer.py が毎PR読み込む| PR2
    PR2 --> CS
    PR2 --> GCS
    PR2 --> DD
    CSCAN -->|アラート発生時\nactive_rules.mdへ判例追加| AR2
```

---

## Draft PRの扱い（判例 DX-001）

```mermaid
flowchart TD
    NEW["PR作成"]
    DRAFT{"Draft PR?"}
    REVIEW_W["AIレビューする\nFAILでもブロックしない\nCommit Status: success（警告のみ）"]
    REVIEW_S["FAILで厳格にブロック\nCommit Status: failure"]
    REASON["理由: mainへのマージが物理的に不可能\n本番隔離が担保されている"]

    NEW --> DRAFT
    DRAFT -->|Yes| REVIEW_W
    DRAFT -->|No（Ready for Review）| REVIEW_S
    REVIEW_W --- REASON
```

> `[skip ai]` のようなバイパスを作らない理由：IPO監査で「誰がどの権限でバイパスしたか」を証明できなくなるため、職務分掌・証跡確保の原則に反する。

---

## バグが出たときの切り分け

```mermaid
flowchart TD
    BUG["バグ発生"]
    Q{"バグの性質は？"}

    BUG --> Q

    Q -->|シークレット・トークンが混入| A3
    Q -->|roles/owner・IAMワイルドカード\n削除保護なし| B3
    Q -->|Terraform構文エラー\n意図しないリソース差分| C3
    Q -->|Pythonコードの脆弱性\n平文ロギング等| E3
    Q -->|設計思想違反\nprd-プレフィックスなし\nShared VPC・SA境界混在| D3

    A3["**A（gitleaks）の取りこぼし**\n原因: allowlistが広すぎる\n対処: .gitleaks.tomlを見直す"]
    B3["**B（Checkov）の取りこぼし**\n原因: skip-checkが広すぎた\n対処: .checkov.yamlを見直す\n+ judgments.mdに記録"]
    C3["**C（terraform plan）の取りこぼし**\n原因: planを人間が見ていなかった\n対処: レビュープロセスを見直す"]
    E3["**E（CodeQL）の取りこぼし**\n原因: クエリがカバーしていない\n対処: active_rules.mdに判例追加"]
    D3["**D（Gemini）の取りこぼし**\n原因: active_rules.mdに判例がなかった\n対処: judgments.md追記\n→ active_rules.md更新\n→ 次PRから自動反映"]
```

---

## 今後の課題：バグ切り分けの自動化

CodeQL アラートをフィードバックループに自動で取り込む構想。

```mermaid
flowchart TD
    ALERT["GitHub Code Scanning\nアラート発生"]
    WF["code_scanning_alert\nワークフローが起動"]
    PARSE["rule.id で自動分類\nCKV_GCP_* → B\ngitleaks-* → A\nその他 → D"]
    SEV{"重大度"}
    ISSUE["GitHub Issueを自動起票\n+ judgments.md追記を促す"]
    ISSUE2["Issue起票のみ\n（追記は任意）"]
    TRIAGE["pr_reviewer.py を\ntriage modeで実行\n「どのルールで防げたか」を\nGeminiに問う"]
    UPDATE["judgments.md → active_rules.md 更新\n次PRから自動反映"]

    ALERT --> WF --> PARSE --> SEV
    SEV -->|CRITICAL / HIGH| ISSUE
    SEV -->|MEDIUM以下| ISSUE2
    ISSUE --> TRIAGE --> UPDATE
```

> `pr_reviewer.py` はすでに diff取得・Gemini呼び出し・GitHubコメント投稿の実装を持っているため、プロンプトを差し替えるだけで triage mode として転用できる。
