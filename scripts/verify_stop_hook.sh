#!/usr/bin/env bash
# Stop hook: .clinerules 第6章「自律検証フロー」の terraform validate を機械的に強制する。
# .tf に変更があったターンだけ、変更を含む init 済みディレクトリを検証する。
# 会話のみのターン・未 init ディレクトリ・terraform 未インストール時は何もしない
# （誤ブロックによる開発体験の毀損を防ぐため）。
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

changed_tf=$(
  { git diff --name-only HEAD -- '*.tf' 2>/dev/null
    git ls-files --others --exclude-standard -- '*.tf' 2>/dev/null
  } | sort -u
)
[ -z "$changed_tf" ] && exit 0
command -v terraform >/dev/null 2>&1 || exit 0

dirs=$(printf '%s\n' "$changed_tf" | xargs -n1 dirname | sort -u)
failed=0
report=""
while IFS= read -r d; do
  [ -z "$d" ] && continue
  [ -d "$d/.terraform" ] || continue          # 未 init はスキップ
  if ! out=$(terraform -chdir="$d" validate -no-color 2>&1); then
    failed=1
    report+="── ${d}"$'\n'"${out}"$'\n'
  fi
done <<< "$dirs"

if [ "$failed" -eq 1 ]; then
  {
    echo "❌ terraform validate 失敗（.clinerules 第6章）。修正してから完了すること:"
    echo "$report"
  } >&2
  exit 2
fi
exit 0
