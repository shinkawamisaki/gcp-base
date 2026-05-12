#!/usr/bin/env python3
"""
AI検閲官 (Cloud Build版)
ローカルの pre-commit に依存せず、クラウド(CI)環境で自律的に動作するAIレビュアー。
職務分掌と最小権限の原則に基づき、開発者の権限外で厳格にコードを検閲し、
不適切なIAM付与やシークレットのハードコーディングを防止します。
"""

import os
import sys
import re
import json
import datetime
import tempfile
import requests
from google.cloud import storage

# ==============================================================================
# 環境変数の取得
# ==============================================================================
PROJECT_ID = os.environ.get("PROJECT_ID")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
REPO_FULL_NAME = os.environ.get("REPO_FULL_NAME")
PR_NUMBER = os.environ.get("PR_NUMBER")
COMMIT_SHA = os.environ.get("COMMIT_SHA")
STRICT_AI_VERIFY = os.environ.get("STRICT_AI_VERIFY", "false").lower() == "true"
LOCATION = os.environ.get("VERTEX_LOCATION", "asia-northeast1")
DATADOG_ENABLED = os.environ.get("DATADOG_ENABLED", "false").lower() == "true"

if not all([PROJECT_ID, GITHUB_TOKEN, REPO_FULL_NAME, PR_NUMBER, COMMIT_SHA]):
    print("[ERROR] 必要な環境変数が設定されていません。")
    sys.exit(1)

# ==============================================================================
# GitHub API ヘルパー
# ==============================================================================
GH_HEADERS_JSON = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
}

GH_HEADERS_DIFF = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github.v3.diff",
    "X-GitHub-Api-Version": "2022-11-28"
}

def get_pr_info():
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/pulls/{PR_NUMBER}"
    resp = requests.get(url, headers=GH_HEADERS_JSON)
    resp.raise_for_status()
    return resp.json()

def get_pr_diff():
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/pulls/{PR_NUMBER}"
    resp = requests.get(url, headers=GH_HEADERS_DIFF)
    resp.raise_for_status()
    return resp.text

def set_commit_status(state, description):
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/statuses/{COMMIT_SHA}"
    data = {
        "state": state,
        "description": description[:140],
        "context": "AI-Verifier"
    }
    requests.post(url, headers=GH_HEADERS_JSON, json=data)

def post_or_update_comment(body_text):
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/issues/{PR_NUMBER}/comments"
    resp = requests.get(url, headers=GH_HEADERS_JSON)
    resp.raise_for_status()
    comments = resp.json()
    
    bot_comment_id = None
    for c in comments:
        if "🤖 AI検閲官" in c.get("body", ""):
            bot_comment_id = c["id"]
            break
            
    if bot_comment_id:
        update_url = f"https://api.github.com/repos/{REPO_FULL_NAME}/issues/comments/{bot_comment_id}"
        requests.patch(update_url, headers=GH_HEADERS_JSON, json={"body": body_text})
    else:
        requests.post(url, headers=GH_HEADERS_JSON, json={"body": body_text})

# ==============================================================================
# Datadog メトリクス送信
# DATADOG_ENABLED=false の場合は何もしない（切り替えはこの環境変数だけ）
# ==============================================================================
def send_datadog_metrics(result, is_draft, pr_author, category=None):
    if not DATADOG_ENABLED:
        return
    dd_api_key = os.environ.get("DATADOG_API_KEY", "").strip()
    if not dd_api_key:
        print("[WARN] DATADOG_ENABLED=true だが DATADOG_API_KEY が未設定です。")
        return

    import urllib.request
    import time

    tags = [
        f"result:{result}",
        f"repo:{REPO_FULL_NAME}",
        f"pr_number:{PR_NUMBER}",
        f"is_draft:{str(is_draft).lower()}",
        f"author:{pr_author}",
    ]
    if category:
        tags.append(f"category:{category}")

    payload = {
        "series": [{
            "metric": "gcp.ai_verifier.review",
            "type": 1,  # count
            "points": [{"timestamp": int(time.time()), "value": 1}],
            "tags": tags,
        }]
    }
    url = os.environ.get("DATADOG_API_URL", "https://api.datadoghq.com/api/v2/series")
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"DD-API-KEY": dd_api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"[INFO] Datadog 送信完了 (status={resp.status}, tags={tags})")
    except Exception:
        print("[WARN] Datadog への送信に失敗しました。(詳細は非表示)")

# ==============================================================================
# セキュリティ・マスク処理
# ==============================================================================
def redact_sensitive_info(text):
    # 情報漏洩の防止と静的解析(SAST)対応のため、AIに送る前にマスク
    text = re.sub(r'(?i)(password|secret|token|api[_-]?key|credentials)["\'\s:=]+[^\s"\'},]+', r'\1: [REDACTED]', text)
    text = re.sub(r'\b(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)[0-9.]+\b', '[REDACTED_IP]', text)
    return text

# ==============================================================================
# メインロジック
# ==============================================================================
def main():
    print("[INFO] AI検閲官 (Cloud Build版) を開始します。")
    
    # Vertex AI インポート（エラーハンドリング）
    try:
        import vertexai
        from vertexai.generative_models import GenerativeModel
    except ImportError:
        print("[ERROR] google-cloud-aiplatform がインストールされていません。")
        set_commit_status("error", "AI Platform setup failed")
        sys.exit(2 if STRICT_AI_VERIFY else 0)

    # PR情報と差分の取得
    pr_info = get_pr_info()
    is_draft = pr_info.get("draft", False)
    diff_content = get_pr_diff()
    
    if not diff_content.strip():
        print("[INFO] 差分がありません。")
        set_commit_status("success", "No diff to verify")
        sys.exit(0)
        
    # ルールファイルの読み込み
    rules_path = ".clinerules"
    rules_content = ""
    if os.path.exists(rules_path):
        with open(rules_path, "r", encoding="utf-8") as f:
            rules_content = f.read()
    else:
        print("[WARN] .clinerules が見つかりません。")

    # 判例集の読み込み（重複なし・最新判断のみ。証跡は judgments.md を参照）
    active_rules_path = "logs/active_rules.md"
    active_rules_content = ""
    if os.path.exists(active_rules_path):
        with open(active_rules_path, "r", encoding="utf-8") as f:
            active_rules_content = f.read()
        print("[INFO] 判例集 (active_rules.md) を読み込みました。")
    else:
        print("[WARN] logs/active_rules.md が見つかりません。判例なしで審査します。")

    # マスク処理
    rules_content_masked = redact_sensitive_info(rules_content)
    active_rules_masked = redact_sensitive_info(active_rules_content)
    diff_content_masked = redact_sensitive_info(diff_content)

    # プロンプトの構築
    base_prompt = """あなたは厳格なIPO準備・高セキュリティ仕様のGCP基盤の外部コードレビュアーです。
以下の「プロジェクト憲法（設計思想・ルール）」と「判例集（過去の人間判断）」を基準に、現在ステージングされている変更（git diff）を厳密にレビューしてください。

【プロジェクト憲法】
{rules}

【判例集（過去に人間が下した判断 - 憲法より優先して適用せよ）】
{active_rules}

【変更内容 (git diff)】
{diff}

【指示】
1. 判例集に該当するケースがあれば、憲法より判例を優先して判断せよ。
2. プロジェクト憲法の思想（職務分掌、最小権限、物理隔離、ハードコーディング排除など）と矛盾がないか厳格にチェックしてください。
3. ルール違反やセキュリティリスクがある場合、またはルールの思想から逸脱している場合は不合格としてください。
4. コードの修正が必要な場合は、開発者がすぐに取り込めるようにGitHubのSuggested Changes形式（```suggestion ... ```）を用いて具体的な修正コードを提案してください。
5. 回答およびコメントの文章は【必ずすべて日本語】で記述してください（コードスニペットを除く）。
6. 出力形式：
   - 合格の場合: 最初の行に「RESULT: PASS」と書き、次の行に「OK」とだけ出力してください。
   - 不合格の場合: 最初の行に「RESULT: FAIL」、2行目に「CATEGORY: <カテゴリ>」と書き、3行目から具体的な指摘理由と修正案を日本語で出力してください。
     カテゴリは以下から最も近いものを1つ選んでください: IAM / SECRET / NETWORK / HARDCODING / POLICY / OTHER
"""
    prompt = base_prompt.format(
        rules=rules_content_masked,
        active_rules=active_rules_masked or "（判例なし）",
        diff=diff_content_masked,
    )

    # Gemini APIの呼び出し
    vertexai.init(project=PROJECT_ID, location=LOCATION)
    model = GenerativeModel("gemini-2.5-flash")
    
    print("[INFO] Gemini 2.5 Flash に検閲をリクエストしています...")
    try:
        response = model.generate_content(prompt, generation_config={"temperature": 0.0})
        result_text = response.text.strip()
    except Exception as e:
        print(f"[ERROR] Vertex AI 呼び出しエラー: {e}")
        set_commit_status("error", "AI verification failed")
        sys.exit(2 if STRICT_AI_VERIFY else 0)

    # 結果の判定とフィードバック
    pr_author = pr_info.get("user", {}).get("login", "unknown")

    if "RESULT: FAIL" in result_text:
        print("[INFO] 検閲結果: 違反を検知しました。")

        # CATEGORY 行をパース（Datadog タグ用）
        category_match = re.search(r"CATEGORY:\s*(\w+)", result_text)
        violation_category = category_match.group(1).lower() if category_match else "other"

        clean_body = re.sub(r"RESULT:\s*FAIL\n?", "", result_text)
        clean_body = re.sub(r"CATEGORY:\s*\w+\n?", "", clean_body).strip()
        comment_body = f"### 🤖 AI検閲官からのアドバイス\n\n🚨 **プロジェクト憲法への違反またはリスクを検知しました。**\n\n{clean_body}"
        post_or_update_comment(comment_body)
        send_datadog_metrics("fail", is_draft, pr_author, category=violation_category)

        # Draft PRの聖域化
        if is_draft:
            print("[INFO] Draft PRのため、Status Check は Success で通過させます。")
            set_commit_status("success", "Failed but Draft PR (Warning only)")
            sys.exit(0)
        else:
            set_commit_status("failure", "AI verification failed. Check PR comments.")
            sys.exit(1)
    else:
        print("[INFO] 検閲結果: 合格しました。")
        comment_body = "### 🤖 AI検閲官\n\n✅ **AI検閲を通過しました。** 憲法に準拠した素晴らしいコードです！"
        post_or_update_comment(comment_body)
        set_commit_status("success", "AI verification passed")
        send_datadog_metrics("pass", is_draft, pr_author)

        # 逆引き仕様書生成
        generate_changelog(model, diff_content_masked)
        sys.exit(0)

def generate_changelog(model, diff_content):
    print("\n[INFO] 逆引き仕様書（変更証跡）を生成しています...")
    doc_prompt = """あなたは優秀なテクニカルライターです。
以下の変更内容（git diff）から、「誰が、何のために、どのような変更をしたか」を説明する逆引き仕様書（Markdown形式）を作成してください。
なお、出力される文章は【必ずすべて日本語】で記述してください。

【変更内容 (git diff)】
{diff}

出力形式:
# 変更証跡
- **変更概要**: 
- **目的と背景**: 
- **主な変更点**:
- **セキュリティ・IPO観点での評価**: 
"""
    prompt = doc_prompt.format(diff=diff_content)
    try:
        doc_response = model.generate_content(prompt, generation_config={"temperature": 0.2})
        doc_text = doc_response.text.strip()
        
        date_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{date_str}_pr_{PR_NUMBER}.md"
        bucket_name = os.environ.get("CHANGELOG_BUCKET", f"{PROJECT_ID}-changelog-store")
        
        storage_client = storage.Client(project=PROJECT_ID)
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(f"change-logs/{filename}")
        blob.upload_from_string(doc_text, content_type="text/markdown")
        
        print(f"[INFO] 逆引き仕様書を GCS にアップロードしました: gs://{bucket_name}/change-logs/{filename}")
                
    except Exception as e:
        print(f"[WARN] 逆引き仕様書の生成またはアップロードに失敗しました: {e}")

if __name__ == "__main__":
    main()
