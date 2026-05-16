#!/bin/bash
# UserPromptSubmit hook: セッション開始時に PR の状態を確認し、問題があれば Claude に注入する
# 検知対象:
#   1. AI 検閲 (Gemini Flash) の FAIL コメント
#   2. PR レビューの CHANGES_REQUESTED
#   3. CI チェック失敗
#   4. 自分以外 (Cline 等) による追加コミット

set -euo pipefail

BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] && exit 0

PR_JSON=$(gh pr view --json number,reviewDecision,statusCheckRollup,state,headRefName \
  2>/dev/null || echo "")
[ -z "$PR_JSON" ] && exit 0

PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
PR_STATE=$(echo "$PR_JSON"  | jq -r '.state')

# マージ済み・クローズ済みは何もしない
[ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ] && exit 0

CONTEXT_PARTS=()

# ------------------------------------------------------------------
# 1. AI 検閲 FAIL コメント
# ------------------------------------------------------------------
FAIL_COMMENT=$(gh api \
  "/repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" \
  --jq '[.[] | select(.body | contains("FAIL")) | select(.user.login | test("bot|github-actions|cloudbuild"; "i")) | .body] | last' \
  2>/dev/null || echo "")

if [ -n "$FAIL_COMMENT" ] && [ "$FAIL_COMMENT" != "null" ]; then
  CONTEXT_PARTS+=("【AI 検閲 FAIL (PR #${PR_NUMBER})】\n${FAIL_COMMENT}")
fi

# ------------------------------------------------------------------
# 2. PR レビュー却下 (CHANGES_REQUESTED)
# ------------------------------------------------------------------
REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // empty')

if [ "$REVIEW_DECISION" = "CHANGES_REQUESTED" ]; then
  LATEST_REVIEW=$(gh api \
    "/repos/{owner}/{repo}/pulls/${PR_NUMBER}/reviews" \
    --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | last | "レビュアー: \(.user.login)\n\(.body)"' \
    2>/dev/null || echo "詳細不明")
  CONTEXT_PARTS+=("【レビュー差し戻し (CHANGES_REQUESTED)】\n${LATEST_REVIEW}")
fi

# ------------------------------------------------------------------
# 3. CI チェック失敗
# ------------------------------------------------------------------
FAILED_CHECKS=$(echo "$PR_JSON" | jq -r '
  .statusCheckRollup // []
  | [.[] | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")
       | "  - \(.name): \(.detailsUrl // "URL なし")"]
  | join("\n")' 2>/dev/null || echo "")

if [ -n "$FAILED_CHECKS" ]; then
  CONTEXT_PARTS+=("【CI チェック失敗】\n${FAILED_CHECKS}")
fi

# ------------------------------------------------------------------
# 4. 自分以外 (Cline 等) のコミット
# ------------------------------------------------------------------
MY_EMAIL=$(git config user.email 2>/dev/null || echo "")
OTHERS_COMMITS=$(git log "origin/main..${BRANCH}" \
  --format="%ae|%s" 2>/dev/null \
  | grep -v "^${MY_EMAIL}|" \
  | awk -F'|' '{print "  - ["$1"] "$2}' || echo "")

if [ -n "$OTHERS_COMMITS" ]; then
  CONTEXT_PARTS+=("【Cline / 他者によるコミット検出】\n${OTHERS_COMMITS}\n設計・仕様変更が含まれている可能性があります。作業前に内容を確認してください。")
fi

# ------------------------------------------------------------------
# 5. Cline 申し送りノート (.claude/cline-notes.md)
# ------------------------------------------------------------------
NOTES_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/cline-notes.md"
if [ -f "$NOTES_FILE" ]; then
  # [DONE] 未マークのエントリだけ抽出
  PENDING_NOTES=$(awk '
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ { entry=$0; next }
    /^---$/ {
      if (entry != "" && entry !~ /\[DONE\]/) print entry"\n---"
      entry=""
      next
    }
    entry != "" { entry=entry"\n"$0 }
  ' "$NOTES_FILE" | sed '/^$/d')

  if [ -n "$PENDING_NOTES" ]; then
    CONTEXT_PARTS+=("【Cline 申し送りノート】\n対応後は該当エントリの先頭に [DONE] を付けてください。\n\n${PENDING_NOTES}")
  fi
fi

# ------------------------------------------------------------------
# 何もなければ終了
# ------------------------------------------------------------------
[ "${#CONTEXT_PARTS[@]}" -eq 0 ] && exit 0

# ------------------------------------------------------------------
# まとめて Claude に注入
# ------------------------------------------------------------------
SEPARATOR="\n\n----------------------------------------\n"
FULL_MSG="PR #${PR_NUMBER} に以下の未対応事項があります:\n\n"
for i in "${!CONTEXT_PARTS[@]}"; do
  [ "$i" -gt 0 ] && FULL_MSG+="$SEPARATOR"
  FULL_MSG+="${CONTEXT_PARTS[$i]}"
done

jq -n --arg msg "$FULL_MSG" \
  '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $msg}}'
