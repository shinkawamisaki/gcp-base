#!/usr/bin/env bash
# =============================================================================
# AI検閲官の回帰テスト（promptfoo eval）— Cloud Build 用の条件付き実行
# =============================================================================
# 検閲基準（憲法・判例・プロンプト・ゴールデンセット）を変更する PR でのみ
# eval を実行し、全ケース合格しないとビルドを fail させてマージをブロックする。
# 「ルール変更前に手で eval を打つ」運用の打ち忘れを構造的に排除する。
#
# 設計上の判断:
# - 全 PR で常時実行しない: モデル側の一時障害・ドリフトが無関係な PR まで
#   ブロックする半径拡大を避ける。
# - 変更ファイルの取得に失敗した場合は「実行する」側に倒す（保守的 fail-closed。
#   スキップ側に倒すと API エラーの誘発がバイパスになる）。
# - promptfoo はバージョン固定（再現性）。更新は意図的な PR で行うこと。
# - 認証は Cloud Build SA のメタデータ ADC（検閲官と同一・新規資格情報なし）。
# =============================================================================
set -euo pipefail

PROMPTFOO_VERSION="0.121.15"
# 検閲基準に関わるパス（ここを変える PR だけが eval の対象）。
# logs/active_rules.md は判例運用（VCS 追跡）を始めたリポジトリ向けの将来枠。
CRITERIA_PATTERN='^(prompts/|evals/|\.clinerules$|logs/active_rules\.md$)'

: "${GITHUB_TOKEN:?}" "${REPO_FULL_NAME:?}" "${PR_NUMBER:?}" "${PROJECT_ID:?}"

# --- PR の変更ファイル一覧を取得（最大300件。超過・失敗時は保守側＝実行に倒す） ---
# §5: GITHUB_TOKEN はシェル引数・一時ファイルに一切出さず、node プロセス内で
# 環境変数から直接読んで fetch する（argv 経由だとプロセスリストに平文で載る。
# 本番 pr_reviewer.py がヘッダをプロセス内メモリで扱うのと同じ方式に揃える）。
# エラー時も応答本文・ヘッダは出力しない（exit code のみで通知）。
need_eval=0
files=$(node --input-type=module -e '
const { GITHUB_TOKEN, REPO_FULL_NAME, PR_NUMBER } = process.env;
const out = [];
for (let page = 1; page <= 3; page++) {
  const res = await fetch(
    `https://api.github.com/repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}`,
    {
      headers: {
        "Authorization": `token ${GITHUB_TOKEN}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    },
  ).catch(() => null);
  if (!res || !res.ok) process.exit(2);          // API エラー（詳細は出さない）
  const j = await res.json();
  out.push(...j.map((f) => f.filename));
  if (j.length < 100) break;
  if (page === 3) process.exit(3);               // 300件超
}
console.log(out.join("\n"));
') || {
  echo "[WARN] 変更ファイル一覧を確定できませんでした（APIエラーまたは300件超）。保守側に倒し eval を実行します。"
  need_eval=1
}

if [ "${need_eval}" -eq 0 ] && grep -qE "${CRITERIA_PATTERN}" <<<"${files}"; then
  need_eval=1
fi

if [ "${need_eval}" -eq 0 ]; then
  echo "[INFO] 検閲基準（prompts/ evals/ .clinerules active_rules.md）への変更はありません。eval をスキップします。"
  exit 0
fi

echo "[INFO] 検閲基準に関わる変更を検知しました。回帰テストを実行します（promptfoo v${PROMPTFOO_VERSION}）。"
export VERTEX_PROJECT_ID="${VERTEX_PROJECT_ID:-${PROJECT_ID}}"
export VERTEX_REGION="${VERTEX_REGION:-asia-northeast1}"
export PROMPTFOO_DISABLE_TELEMETRY=1

cd "$(dirname "$0")/../evals"
# モデルの一時的な空応答・揺らぎ・レートリミットを吸収するため1回リトライする
# （検閲官本体のリトライ＋フォールバックと同じ思想）。
# - 並列数を 2 に制限: 既定(4)だと検閲官本体の呼び出しと合わせて Vertex の
#   分間クォータを食い潰し、429（RateLimitExhaustedError）で全滅し得る
#   （実検証リポジトリで実際に発生）。
# - リトライ前に 60 秒待つ: 429 は分間クォータのため、即時リトライは枯渇した
#   窓にそのまま突っ込んで全滅する。
# - リトライ時はキャッシュを無効化し、失敗応答の再利用を防ぐ。
# 2回連続で失敗した場合は本物の回帰としてビルドを fail させる。
if npx -y "promptfoo@${PROMPTFOO_VERSION}" eval --no-progress-bar --max-concurrency 2; then
  echo "[INFO] 回帰テスト: 全ケース合格しました。"
else
  echo "[WARN] 回帰テストに失敗しました。一時的なモデル揺らぎ・レートリミットの可能性があるため、60秒待ってからキャッシュ無効で1回だけリトライします。"
  sleep 60
  if npx -y "promptfoo@${PROMPTFOO_VERSION}" eval --no-progress-bar --no-cache --max-concurrency 2; then
    echo "[INFO] 回帰テスト: リトライで全ケース合格しました。"
  else
    echo "[ERROR] 回帰テスト: リトライも失敗しました。本物の回帰としてビルドを fail させます。"
    exit 1
  fi
fi
