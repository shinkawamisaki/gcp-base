#!/usr/bin/env bash
# =============================================================================
# AI検閲官の回帰テスト実行ラッパー
# =============================================================================
# 環境変数を覚えなくても `./evals/run.sh` 一発で回せるようにする。
# - VERTEX_PROJECT_ID はハードコードせず（.clinerules §3）、未指定なら
#   gcloud の既定プロジェクトから導出する
# - 認証は ADC（pr_reviewer.py と同一のキーレス方式・新規資格情報なし）
# - 追加引数はそのまま promptfoo に渡す（例: ./run.sh --no-cache）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export VERTEX_PROJECT_ID="${VERTEX_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
export VERTEX_REGION="${VERTEX_REGION:-asia-northeast1}"
export PROMPTFOO_DISABLE_TELEMETRY="${PROMPTFOO_DISABLE_TELEMETRY:-1}"

if [ -z "${VERTEX_PROJECT_ID}" ]; then
  # §5: 内部情報は出さず、復旧手順だけを示す
  echo "[ERROR] VERTEX_PROJECT_ID が未設定で、gcloud の既定プロジェクトも取得できませんでした。" >&2
  echo "        'gcloud config set project <PROJECT_ID>' を実行するか、環境変数で指定してください。" >&2
  exit 1
fi

echo "[INFO] promptfoo eval を実行します (project=${VERTEX_PROJECT_ID}, region=${VERTEX_REGION})"
npx -y promptfoo@latest eval "$@"
