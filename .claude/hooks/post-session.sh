#!/bin/bash
# Stop hook: コミット済みで未プッシュ/未PR の場合に Draft PR 作成 + Mac 通知

set -euo pipefail

BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] && exit 0

AHEAD=$(git rev-list --count "origin/main..${BRANCH}" 2>/dev/null || echo "0")
[ "$AHEAD" -eq 0 ] && exit 0

# すでに PR があるか確認
PR_URL=$(gh pr view --json url --jq '.url' 2>/dev/null || echo "")

if [ -z "$PR_URL" ]; then
  TITLE=$(git log -1 --pretty=%s)
  PR_URL=$(gh pr create \
    --draft \
    --title "$TITLE" \
    --body "$(cat <<'EOF'
Claude Code による自動 Draft PR。

## 変更概要
<!-- Cline レビュー前に記載してください -->

## チェックリスト
- [ ] Cline (Gemini Pro) レビュー完了
- [ ] AI 検閲 (Gemini Flash) 通過
EOF
)" 2>/dev/null || echo "")
fi

if [ -n "$PR_URL" ]; then
  osascript -e "display notification \"Draft PR 作成済: $PR_URL\" with title \"Claude Code → Cline\" subtitle \"VS Code でレビューしてください\" sound name \"Glass\"" 2>/dev/null || true
fi
