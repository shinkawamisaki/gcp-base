# AI検閲官の回帰テスト (promptfoo evals)

AIレビュアー（`scripts/pr_reviewer.py` / Layer 2 D）の判定精度を、ゴールデンセット
（合格すべき diff / 不合格にすべき diff）に対する回帰テストで機械検証する。

「AIにレビューさせているが、そのAI自身の精度は誰が保証するのか？」への答えであり、
プロンプト・憲法・判例の変更やモデル更新によるデグレをマージ前に検知する。

## 設計原則

- **本番と同一のプロンプトをテストする**: `prompts/reviewer_prompt.txt` を
  `pr_reviewer.py` と本設定の両方が参照する。eval と本番のプロンプト乖離を構造的に防ぐ。
- **判定は決定的文字列マッチのみ**: `RESULT: PASS` / `RESULT: FAIL` の一致判定。
  LLM-as-a-judge は使わず、eval のコストはテスト対象の Gemini 呼び出し分のみ。
- **temperature 0**: 本番（`pr_reviewer.py`）と同一設定で再現性を確保する。
- **promptfoo は OSS（MIT）**: サインアップ・API キー・課金契約は不要。
  認証は gcloud の ADC（本番検閲官と同じキーレス方式）で、コストは Vertex AI の
  従量課金のみ（1回の実行 = ケース数 × Gemini Flash 呼び出し1回・十数ケースで数円規模）。

## 実行方法

```bash
# 認証: gcloud の ADC（pr_reviewer.py と同じくキーレス。新規資格情報は作らない）
gcloud auth application-default login   # 未設定の場合のみ

./evals/run.sh                          # これだけで実行できる
npx promptfoo@latest view               # 結果をブラウザで確認（任意）
```

`run.sh` は `VERTEX_PROJECT_ID` 未指定時に gcloud の既定プロジェクトを使い、
リージョンは `asia-northeast1`（本番既定と同一）、テレメトリ無効で実行する。
追加引数はそのまま promptfoo へ渡る（例: `./evals/run.sh --no-cache`）。

## いつ回るか（検証ループ）

**CI が自動で強制する**: 検閲基準（`.clinerules` / `prompts/` / `evals/` /
`logs/active_rules.md`）を変更する PR では、Cloud Build（`scripts/run_evals_ci.sh`）が
eval を自動実行し、**全ケース合格しないとマージできない**。手動実行を忘れても
検証が抜けることはない（AI検閲官の Cloud Build トリガーを配線済みであることが前提）。

ローカルの `./evals/run.sh` は「PR を出す前の事前確認」用として併存する:

| タイミング | 目的 |
|---|---|
| 検閲基準を変更する PR の前（任意・CI で必ず再検証される） | 手元での素早いデグレ確認 |
| `GEMINI_MODEL`（モデル更新）の前後 | モデルドリフト・乗り換え検証 |
| 新しい判例が追加されたとき | 判例に対応するケースを `cases/` に追加して固定化 |

> **CI 側の設計**: 全 PR での常時実行はしない（モデル側の一時障害が無関係な PR まで
> ブロックする半径拡大を避ける）。変更ファイル一覧の取得に失敗した場合は「実行する」
> 側に倒す（スキップ側に倒すとエラー誘発がバイパス手段になるため）。eval 失敗時は
> キャッシュ無効で1回リトライし、モデルの一時的な空応答・揺らぎを吸収する（2回連続
> fail は本物の回帰）。CI の promptfoo はバージョン固定で、更新は意図的な PR で行う
> （`scripts/run_evals_ci.sh` 冒頭）。

## 判例集（active_rules）との連動

既定では `fixtures/active_rules.sample.md`（サンプル判例集）を読む。本テンプレートは
内部判例を同梱しないためである。**自リポジトリで判例運用を始めたら**:

1. `logs/active_rules.md` を VCS 追跡する（PRIVATE リポジトリ推奨。PUBLIC で内部判例を
   公開しないこと）
2. `promptfooconfig.yaml` の `active_rules` を `file://../logs/active_rules.md` に差し替える
3. 人間判断（判例）が出るたびに、対応するケースの diff を `cases/pass|fail/` に追加する

判例がそのまま「正解データ」になり、同じ判定ミスの再発を機械的に検知できる。

## なぜ攻撃パターンを平文で同梱するのか

`cases/fail/` にはプロンプトインジェクション文や憲法違反コードが**テストデータとして
平文で**含まれる。これは検閲官のインジェクション耐性・違反検知力を回帰テストするために
必要であり、エンコード・難読化での収載は「レビュアーを欺く」構図になるため行わない。

このため、**フィクスチャを追加・変更する PR は AI検閲官に（正しい動作として）FAIL され
得る**。その場合はサンプル判例 `[SEC-001]`（`fixtures/active_rules.sample.md` 参照）と
同趣旨の判例を自リポジトリの `logs/active_rules.md` に追加してから、フィクスチャ PR を
出すこと（検閲基準は base コミットから読まれるため、判例の先行マージが必要）。

判例には「diff ヘッダのパスが `evals/cases/` 配下のときだけ適用する」という**機械的な
判定手順**を必ず含めること。適用境界が曖昧だと、検閲モデルが「テストデータか実攻撃か」を
延々と熟考して判定不能（空応答）に陥ることが実際に確認されている。

### フィクスチャ作成時の注意

- **実シークレットに似せない**: 偽の Webhook URL・API キー等は gitleaks（Layer 1/2）が
  実シークレットと誤検知して PR をブロックする。秘匿情報のハードコード違反をテストしたい
  場合は、スキャナの正規表現に掛からない形（org_id 直書き等）で表現する。

## ケースの追加方法

1. `cases/pass/` または `cases/fail/` に git diff 形式のファイルを置く
2. `promptfooconfig.yaml` の `tests:` にエントリを追加する
   - 合格ケース: `regex: "^RESULT: PASS"`
   - 不合格ケース: `contains: "RESULT: FAIL"`
