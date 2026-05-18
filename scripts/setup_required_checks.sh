#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_INVENTORY="$PROJECT_ROOT/governance/admin/factory/inventory.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/setup_required_checks.sh [options]

Options:
  --repo <owner/repo>           Target a single repository (can be repeated)
  --inventory <path>            Read repositories from inventory.json apps[].github_repo
  --branch <name>               Protect this branch (default: repo default branch)
  --with-sandbox-critical       Also require "Checkov Sandbox Critical Guardrail" (sandbox用, prd env設定をスキップ)
  --prd-reviewer-team <slug>    prd Environmentの承認者チームスラッグ (例: platform-admins)
  --no-prd-env                  prd GitHub Environment保護設定をスキップ
  --dry-run                     Print targets and payload, do not apply
  -h, --help                    Show this help

Examples:
  # 1) Current repository (auto-detect from git remote)
  ./scripts/setup_required_checks.sh

  # 2) Explicit repository
  ./scripts/setup_required_checks.sh --repo your-org/your-app-repo

  # 3) Bulk apply to all apps in inventory.json
  ./scripts/setup_required_checks.sh --inventory governance/admin/factory/inventory.json
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: $1"
    exit 1
  fi
}

normalize_repo() {
  local v="$1"
  v="${v#https://github.com/}"
  v="${v#git@github.com:}"
  v="${v%.git}"
  echo "$v"
}

detect_current_repo() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [ -z "$remote" ]; then
    return 1
  fi
  normalize_repo "$remote"
}

read_repos_from_inventory() {
  local path="$1"
  jq -r '
    (.apps // {})
    | to_entries[]
    | .value.github_repo // empty
    | select(. != "")
    | select(test("^your-org/") | not)
  ' "$path"
}

generate_github_app_token() {
  python3 <<'PY'
import os
import time
import jwt
import requests

app_id = os.environ.get("GITHUB_APP_ID", "")
private_key = os.environ.get("GITHUB_APP_PRIVATE_KEY", "")
installation_id = os.environ.get("GITHUB_APP_INSTALLATION_ID", "")

if not app_id or not private_key or not installation_id:
    raise SystemExit("missing GitHub App credentials")

now = int(time.time())
payload = {
    "iat": now - 60,
    "exp": now + (10 * 60),
    "iss": app_id
}
encoded_jwt = jwt.encode(payload, private_key, algorithm="RS256")

url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
headers = {
    "Authorization": f"Bearer {encoded_jwt}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
}
res = requests.post(url, headers=headers, timeout=30)
res.raise_for_status()
print(res.json()["token"])
PY
}
build_payload() {
  local checks_json="$1"
  local current="${2:-}"

  if [ -n "$current" ]; then
    jq -n \
      --argjson checks "$checks_json" \
      --argjson current "$current" '
      {
        required_status_checks: {
          strict: true,
          contexts: $checks
        },
        enforce_admins: ($current.enforce_admins.enabled // false),
        required_pull_request_reviews: ($current.required_pull_request_reviews // null),
        restrictions: ($current.restrictions // null),
        required_linear_history: ($current.required_linear_history.enabled // false),
        allow_force_pushes: ($current.allow_force_pushes.enabled // false),
        allow_deletions: ($current.allow_deletions.enabled // false),
        block_creations: ($current.block_creations.enabled // false),
        required_conversation_resolution: ($current.required_conversation_resolution.enabled // true),
        lock_branch: ($current.lock_branch.enabled // false),
        allow_fork_syncing: ($current.allow_fork_syncing.enabled // false)
      }'
  else
    jq -n \
      --argjson checks "$checks_json" '
      {
        required_status_checks: {
          strict: true,
          contexts: $checks
        },
        enforce_admins: false,
        required_pull_request_reviews: null,
        restrictions: null,
        required_linear_history: false,
        allow_force_pushes: false,
        allow_deletions: false,
        block_creations: false,
        required_conversation_resolution: true,
        lock_branch: false,
        allow_fork_syncing: false
      }'
  fi
}

# PRD GitHub Environment に保護設定を適用する
# - protected_branches: true  → mainブランチからのみデプロイ可
# - prevent_self_review: true → 自己承認禁止
# - reviewers (team): --prd-reviewer-team で指定したチームを承認者に追加
apply_environment_protection() {
  local repo="$1"
  local env_name="$2"
  local reviewer_team_slug="${3:-}"
  local dry_run="$4"

  local reviewers_json="[]"
  if [ -n "$reviewer_team_slug" ]; then
    local org
    org="$(echo "$repo" | cut -d'/' -f1)"
    local team_id
    team_id="$(gh api "/orgs/$org/teams/$reviewer_team_slug" --jq '.id' 2>/dev/null || true)"
    if [ -n "$team_id" ]; then
      reviewers_json="[{\"type\":\"Team\",\"id\":$team_id}]"
    else
      echo "[WARN] Team '$reviewer_team_slug' not found in org '$org'. Skipping reviewer."
    fi
  fi

  local payload
  payload="$(jq -n \
    --argjson reviewers "$reviewers_json" \
    '{
      wait_timer: 0,
      prevent_self_review: true,
      reviewers: $reviewers,
      deployment_branch_policy: {
        protected_branches: true,
        custom_branch_policies: false
      }
    }')"

  echo "[INFO] Applying prd environment protection: $repo (env: $env_name)"

  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] Environment payload:"
    echo "$payload" | jq .
    return 0
  fi

  if gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/$repo/environments/$env_name" \
    --input - <<<"$payload" >/dev/null; then
    echo "[OK] prd environment protection set for $repo"
  else
    echo "[WARN] Failed to set prd environment protection for $repo"
    return 1
  fi
}

apply_branch_protection() {
  local repo="$1"
  local branch="$2"
  local payload="$3"
  local dry_run="$4"

  echo "[INFO] Target: $repo (branch: $branch)"

  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] Payload:"
    echo "$payload" | jq .
    return 0
  fi
  if gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/$repo/branches/$branch/protection" \
    --input - <<<"$payload" >/dev/null; then
    echo "[OK] Updated required checks for $repo:$branch"
    return 0
  fi

  echo "[WARN] Failed to update required checks for $repo:$branch"
  return 1
}

main() {
  require_cmd gh
  require_cmd jq
  local prefer_app_token="${USE_GITHUB_APP_TOKEN:-false}"

  if [ "$prefer_app_token" = "true" ]; then
    if [ -z "${GITHUB_APP_ID:-}" ] || [ -z "${GITHUB_APP_PRIVATE_KEY:-}" ] || [ -z "${GITHUB_APP_INSTALLATION_ID:-}" ] || [[ "${GITHUB_APP_ID:-}" == *"PLACEHOLDER"* ]]; then
      echo "[ERROR] USE_GITHUB_APP_TOKEN=true but GitHub App credentials are missing."
      exit 1
    fi
    app_token="$(generate_github_app_token)"
    export GH_TOKEN="$app_token"
    export GITHUB_TOKEN="$app_token"
  elif [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    :
  elif [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [[ "${GITHUB_APP_ID:-}" != *"PLACEHOLDER"* ]]; then
    app_token="$(generate_github_app_token)"
    export GH_TOKEN="$app_token"
    export GITHUB_TOKEN="$app_token"
  elif ! gh auth status >/dev/null 2>&1; then
    echo "[ERROR] gh is not authenticated. Run: gh auth login, or provide GitHub App credentials."
    exit 1
  fi

  local inventory=""
  local forced_branch=""
  local dry_run="false"
  local with_sandbox_critical="false"
  local setup_prd_env="true"          # サンドボックス以外はデフォルトで prd env 保護を設定
  local prd_reviewer_team=""
  local strict_sync="${STRICT_REQUIRED_CHECKS_SYNC:-false}"
  local failed_count=0
  local -a repos=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        repos+=("$(normalize_repo "$2")")
        shift 2
        ;;
      --inventory)
        inventory="$2"
        shift 2
        ;;
      --branch)
        forced_branch="$2"
        shift 2
        ;;
      --with-sandbox-critical)
        with_sandbox_critical="true"
        setup_prd_env="false"         # サンドボックスに prd env 保護は不要
        shift
        ;;
      --no-prd-env)
        setup_prd_env="false"
        shift
        ;;
      --prd-reviewer-team)
        prd_reviewer_team="$2"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "[ERROR] Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [ -n "$inventory" ]; then
    if [ ! -f "$inventory" ]; then
      echo "[ERROR] Inventory file not found: $inventory"
      exit 1
    fi
    while IFS= read -r r; do
      [ -n "$r" ] && repos+=("$(normalize_repo "$r")")
    done < <(read_repos_from_inventory "$inventory")
  fi

  if [ "${#repos[@]}" -eq 0 ] && [ -f "$DEFAULT_INVENTORY" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] && repos+=("$(normalize_repo "$r")")
    done < <(read_repos_from_inventory "$DEFAULT_INVENTORY")
  fi

  if [ "${#repos[@]}" -eq 0 ]; then
    if detected="$(detect_current_repo)"; then
      repos+=("$detected")
    fi
  fi

  if [ "${#repos[@]}" -eq 0 ]; then
    echo "[ERROR] No target repositories found. Use --repo or --inventory."
    exit 1
  fi

  # mapfile は bash 4+ のみ対応のため、macOS (bash 3.2) 互換の書き方に変更
  local -a _deduped=()
  while IFS= read -r _r; do
    _deduped+=("$_r")
  done < <(printf '%s\n' "${repos[@]}" | awk '!seen[$0]++')
  repos=("${_deduped[@]}")

  # ※ プライベートリポジトリへのブランチ保護設定は GitHub Pro 以上が必要です。
  #    パブリックリポジトリ（gcp-base 等）では無償で利用可能です。
  local checks='["Checkov Project Strict","AI-Verifier"]'
  if [ "$with_sandbox_critical" = "true" ]; then
    checks='["Checkov Project Strict","Checkov Sandbox Critical Guardrail","AI-Verifier"]'
  fi

  for repo in "${repos[@]}"; do
    if [[ ! "$repo" =~ ^[^/]+/[^/]+$ ]]; then
      echo "[WARN] Skip invalid repo format: $repo"
      continue
    fi

    local branch
    if [ -n "$forced_branch" ]; then
      branch="$forced_branch"
    else
      branch="$(gh api "/repos/$repo" --jq '.default_branch')"
    fi

    local current_protection=""
    if current_protection="$(gh api "/repos/$repo/branches/$branch/protection" 2>/dev/null)"; then
      :
    else
      current_protection=""
    fi

    payload="$(build_payload "$checks" "$current_protection")"
    if ! apply_branch_protection "$repo" "$branch" "$payload" "$dry_run"; then
      failed_count=$((failed_count + 1))
    fi

    # prd GitHub Environment の保護設定（サンドボックスは除外）
    if [ "$setup_prd_env" = "true" ]; then
      if ! apply_environment_protection "$repo" "prd" "$prd_reviewer_team" "$dry_run"; then
        failed_count=$((failed_count + 1))
      fi
    fi
  done
  if [ "$failed_count" -gt 0 ]; then
    echo "[WARN] Required checks sync had $failed_count failure(s)."
    if [ "$strict_sync" = "true" ]; then
      echo "[ERROR] STRICT_REQUIRED_CHECKS_SYNC=true, exiting with failure."
      exit 1
    fi
  fi

  echo "[DONE] Required checks setup complete."
}

main "$@"
