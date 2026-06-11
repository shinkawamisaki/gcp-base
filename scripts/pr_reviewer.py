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
import time
import datetime
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
# モデルIDはハードコードせず変数化する（weekly_check と統一）。
MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
# 可用性フォールバック（判例 OPS-008）: fail-closed ゲートは Vertex 障害時に
# マージを止めるため、同一 ADC の範囲内でリージョン・モデルを切り替えて
# 可用性を補完する。別ベンダーは使わない（writer=Claude / reviewer=Gemini の
# 独立性を維持し、新しい資格情報を増やさないため）。
FALLBACK_LOCATION = os.environ.get("VERTEX_FALLBACK_LOCATION", "global")
FALLBACK_MODEL = os.environ.get("GEMINI_FALLBACK_MODEL", "gemini-2.5-pro")
# 同一構成での試行回数と待機秒（一時的な 429/503 を吸収する）
RETRIES_PER_CONFIG = 2
RETRY_BACKOFF_SECONDS = (5, 15)
DATADOG_ENABLED = os.environ.get("DATADOG_ENABLED", "false").lower() == "true"
# 検閲プロンプトの外部ファイル化: promptfoo による回帰テスト（evals/）と本番が
# 同一のプロンプトを読むことで、「eval が通っても本番と違うプロンプトをテスト
# していた」という形骸化を構造的に防ぐ。プレースホルダは promptfoo (nunjucks) が
# 直接解釈できる {{rules}} / {{active_rules}} / {{diff}} 形式とし、本番側は
# 単純な文字列置換で埋める（.format() は将来プロンプトに {} が入ると壊れるため不使用）。
PROMPT_TEMPLATE_PATH = "prompts/reviewer_prompt.txt"

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

# GitHub API 呼び出しの timeout（秒）。タイムアウト未指定だと応答遅延時に
# Cloud Build ジョブが無限ハングし、CI 枠とコストを浪費する（bandit B113 / CWE-400）。
# notify_inventory_changes.py の既存値(30s)と統一する。
GH_HTTP_TIMEOUT = 30

def get_base_file_content(path, base_sha, local_path=None):
    """審査基準ファイル（憲法・判例）を PR の base コミットから取得する。

    【なぜ base から読むか（自己参照の遮断）】
    検閲基準（.clinerules / active_rules.md）を PR 適用後（checkout 後）の
    内容で読むと、「ルールを骨抜きにする PR」を“骨抜き後のルール”で審査する
    ことになり、ルール削除を同じ diff で検知できなくなる（自己参照の穴）。
    base コミットから読めば「この変更を、変更前のルールで判定」が成立する。
    diff そのものは従来どおり PR から取得するため、変更内容は審査される。

    取得は GitHub Contents API（base_sha 固定・固定パス）で行う。この取得の
    成否は PR の内容に左右されない（攻撃者が失敗を誘発できない）ため、一時的な
    API エラー時はローカル（PR head）版へ警告付きでフォールバックして可用性を
    保つ。base に存在しない（404）= 新規追加ファイルは「緩める対象の旧ルールが
    無い」ため head 版で問題ない。
    戻り値: (内容, ソース種別 'base'|'local'|'empty')
    """
    headers = {
        "Authorization": f"token {GITHUB_TOKEN}",
        "Accept": "application/vnd.github.raw",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/contents/{path}?ref={base_sha}"
    try:
        resp = requests.get(url, headers=headers, timeout=GH_HTTP_TIMEOUT)
        if resp.status_code == 200:
            return resp.text, "base"
        if resp.status_code == 404:
            # base に存在しない＝この PR で新規追加。旧ルールが無いので head 可
            print(f"[INFO] {path} は base に存在しません（新規追加）。head 版を使用します。")
        else:
            # 一時的な API エラー等。head へフォールバック（§5: 詳細は出さない）
            print(f"[WARN] {path} の base 版取得に失敗（status={resp.status_code}）。head 版へフォールバックします。")
    except Exception:
        print(f"[WARN] {path} の base 版取得で例外。head 版へフォールバックします。(詳細は非表示)")

    # フォールバック: ローカル（PR head）版
    lp = local_path or path
    if os.path.exists(lp):
        with open(lp, "r", encoding="utf-8") as f:
            return f.read(), "local"
    return "", "empty"

def get_pr_info():
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/pulls/{PR_NUMBER}"
    resp = requests.get(url, headers=GH_HEADERS_JSON, timeout=GH_HTTP_TIMEOUT)
    resp.raise_for_status()
    return resp.json()

def get_pr_diff():
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/pulls/{PR_NUMBER}"
    resp = requests.get(url, headers=GH_HEADERS_DIFF, timeout=GH_HTTP_TIMEOUT)
    resp.raise_for_status()
    return resp.text

def set_commit_status(state, description):
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/statuses/{COMMIT_SHA}"
    data = {
        "state": state,
        "description": description[:140],
        "context": "AI-Verifier"
    }
    requests.post(url, headers=GH_HEADERS_JSON, json=data, timeout=GH_HTTP_TIMEOUT)

def post_or_update_comment(body_text):
    url = f"https://api.github.com/repos/{REPO_FULL_NAME}/issues/{PR_NUMBER}/comments"
    resp = requests.get(url, headers=GH_HEADERS_JSON, timeout=GH_HTTP_TIMEOUT)
    resp.raise_for_status()
    comments = resp.json()

    bot_comment_id = None
    for c in comments:
        if "🤖 AI検閲官" in c.get("body", ""):
            bot_comment_id = c["id"]
            break

    if bot_comment_id:
        update_url = f"https://api.github.com/repos/{REPO_FULL_NAME}/issues/comments/{bot_comment_id}"
        requests.patch(update_url, headers=GH_HEADERS_JSON, json={"body": body_text}, timeout=GH_HTTP_TIMEOUT)
    else:
        requests.post(url, headers=GH_HEADERS_JSON, json={"body": body_text}, timeout=GH_HTTP_TIMEOUT)

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
    import urllib.parse
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
    # 根本対策: urlopen に file:// 等の想定外スキームを渡させない（bandit B310 / CWE-22）。
    # DATADOG_API_URL は外部入力（環境変数）であり、https 以外は弾く。
    if urllib.parse.urlparse(url).scheme != "https":
        print("[WARN] DATADOG_API_URL が https ではないため送信をスキップします。")
        return
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"DD-API-KEY": dd_api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        # B310 抑止の根拠: 直前で scheme を https に限定済みのため、
        # file:// や独自スキームの読み込みは到達不能（実害なし）。
        with urllib.request.urlopen(req) as resp:  # nosec B310
            print(f"[INFO] Datadog 送信完了 (status={resp.status}, tags={tags})")
    except Exception:
        print("[WARN] Datadog への送信に失敗しました。(詳細は非表示)")

# ==============================================================================
# セキュリティ・マスク処理
# ==============================================================================
def redact_sensitive_info(text):
    # 情報漏洩の防止と静的解析(SAST)対応のため、AIに送る前にマスク
    # 変数参照（${VAR} / $VAR / {var} / process.env.X / os.environ[...]）は秘密の
    # 「実値」ではないためマスク対象から除外する（negative lookahead）。
    # 参照までマスクすると diff 自体が改変され、検閲官が「壊れた・不正なコード」と
    # 誤認する false positive を生む（実例: `token ${GITHUB_TOKEN}` という正当な
    # 環境変数参照が `token: [REDACTED]}` に化け、FAIL 判定された）。
    # 実値（英数字の生トークン等）は $ や { で始まらないため、保護範囲は後退しない。
    text = re.sub(r'(?i)(password|secret|token|api[_-]?key|credentials)["\'\s:=]+(?!\$|\{|process\.env|os\.environ)[^\s"\'},]+', r'\1: [REDACTED]', text)
    text = re.sub(r'\b(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)[0-9.]+\b', '[REDACTED_IP]', text)
    return text

# ==============================================================================
# Vertex AI 呼び出し（リトライ＋フォールバック）
# ==============================================================================
def call_gemini_with_failover(genai, prompt):
    """検閲リクエストをリトライ＋構成フォールバック付きで実行する。

    fail-closed ゲート（STRICT_AI_VERIFY=true）は検閲不能時にマージを止めるため、
    可用性はこの呼び出し層で多層化する（判例 OPS-008）:
      1. 同一構成でリトライ（一時的な 429/503 を吸収）
      2. 別モデル → 別リージョンへ順にフォールバック（モデル/リージョン単位の障害を回避）
    すべて Vertex AI + ADC の範囲内で、新しい資格情報・ベンダーは増やさない。
    全構成が失敗した場合のみ例外を送出し、呼び出し元の STRICT 契約に委ねる
    （フォールバック追加で従来より悪くなる経路は存在しない）。
    戻り値: (検閲結果テキスト, 成功した client, 成功したモデルID)
    """
    attempts = []
    for location in (LOCATION, FALLBACK_LOCATION):
        for model in (MODEL, FALLBACK_MODEL):
            if (location, model) not in attempts:
                attempts.append((location, model))

    for idx, (location, model) in enumerate(attempts):
        for attempt in range(RETRIES_PER_CONFIG):
            try:
                client = genai.Client(vertexai=True, project=PROJECT_ID, location=location)
                response = client.models.generate_content(
                    model=model,
                    contents=prompt,
                    config={"temperature": 0.0},
                )
                text = (response.text or "").strip()
                if not text:
                    # 空応答は判定不能。リトライ/フォールバック対象として扱う
                    raise ValueError("empty response")
                if idx > 0 or attempt > 0:
                    print(f"[INFO] フォールバック後に成功しました (location={location}, model={model})")
                return text, client, model
            except Exception:
                # §5: 例外詳細は出力せず、どの構成が失敗したかだけを記録する
                print(f"[WARN] Vertex 呼び出し失敗 (location={location}, model={model}, "
                      f"try {attempt + 1}/{RETRIES_PER_CONFIG})。詳細は非表示。")
                if attempt < RETRIES_PER_CONFIG - 1:
                    time.sleep(RETRY_BACKOFF_SECONDS[min(attempt, len(RETRY_BACKOFF_SECONDS) - 1)])

    raise RuntimeError("all Vertex AI attempts failed")

# ==============================================================================
# メインロジック
# ==============================================================================
def main():
    print("[INFO] AI検閲官 (Cloud Build版) を開始します。")
    
    # Vertex AI (google-genai) インポート（エラーハンドリング）
    # NOTE: weekly_check は top-level import だが、ここでは import を main 内の
    #       try/except に置く。これは STRICT_AI_VERIFY による fail-open ガードの
    #       一部。検閲不能（SDK欠落 / Vertexエラー）時は §5 に従いスタックトレースを
    #       出さず抽象化し、STRICT=true なら error+exit(2) でブロック、STRICT=false
    #       なら success(skipped)+exit(0) で「真の fail-open」とする。pr_reviewer 固有の差分。
    try:
        from google import genai
    except ImportError:
        print("[ERROR] google-genai がインストールされていません。")
        if STRICT_AI_VERIFY:
            set_commit_status("error", "AI Platform setup failed")
            sys.exit(2)
        # fail-open: 検閲不能でもマージをブロックしない。status を error にすると
        # 必須チェック設定で実質ブロックになり fail-open 契約に反するため success とする。
        set_commit_status("success", "AI verification skipped (SDK missing)")
        sys.exit(0)

    # PR情報と差分の取得
    pr_info = get_pr_info()
    is_draft = pr_info.get("draft", False)
    diff_content = get_pr_diff()
    
    if not diff_content.strip():
        print("[INFO] 差分がありません。")
        set_commit_status("success", "No diff to verify")
        sys.exit(0)
        
    # 審査基準（憲法・判例）は PR の base コミットから読む（自己参照の遮断）。
    # これにより「ルールを骨抜きにする PR」を“骨抜き前のルール”で審査できる。
    # 判例集の更新 PR（例: 新トピック追加）も、その未承認の判例を自らの
    # 正当化根拠に使えなくなる（承認は judgments.md＝人間が行う）。
    base_sha = pr_info.get("base", {}).get("sha")
    if not base_sha:
        # base SHA 不明時は安全側に倒し、検閲不能として STRICT 契約に委ねる
        print("[ERROR] PR の base コミットを特定できません。審査基準を確定できないため検閲を中止します。")
        if STRICT_AI_VERIFY:
            set_commit_status("error", "Cannot determine base commit for rules")
            sys.exit(2)
        set_commit_status("success", "AI verification skipped (no base ref)")
        sys.exit(0)

    rules_content, rules_src = get_base_file_content(".clinerules", base_sha)
    if rules_src == "empty":
        print("[WARN] .clinerules が取得できません。")
    else:
        print(f"[INFO] .clinerules を読み込みました（source={rules_src}）。")

    # 判例集（重複なし・最新判断のみ。証跡は judgments.md を参照）
    active_rules_content, ar_src = get_base_file_content("logs/active_rules.md", base_sha)
    if ar_src == "empty":
        print("[WARN] logs/active_rules.md が取得できません。判例なしで審査します。")
    else:
        print(f"[INFO] 判例集 (active_rules.md) を読み込みました（source={ar_src}）。")

    # 検閲プロンプト本体も審査基準の一部であるため、.clinerules と同様に
    # base コミットから読む（自己参照の遮断）。「プロンプトを骨抜きにする PR」を
    # 骨抜き前のプロンプトで検閲する。プロンプト無しでは検閲が成立しないため、
    # 取得不能時は SDK 欠落・Vertex 障害と同じ STRICT_AI_VERIFY 契約に従う。
    prompt_template, tpl_src = get_base_file_content(PROMPT_TEMPLATE_PATH, base_sha)
    if tpl_src == "empty":
        print("[ERROR] 検閲プロンプト (prompts/reviewer_prompt.txt) が取得できません。")
        if STRICT_AI_VERIFY:
            set_commit_status("error", "AI verification prompt missing")
            sys.exit(2)
        set_commit_status("success", "AI verification skipped (prompt missing)")
        sys.exit(0)
    print(f"[INFO] 検閲プロンプトを読み込みました（source={tpl_src}）。")

    # マスク処理
    rules_content_masked = redact_sensitive_info(rules_content)
    active_rules_masked = redact_sensitive_info(active_rules_content)
    diff_content_masked = redact_sensitive_info(diff_content)

    # プロンプトの構築（テンプレートは base コミットから取得済み）。
    # 単一パス置換: 連鎖 .replace() だと、先に埋めた値（憲法・判例）の中に後続の
    # プレースホルダ文字列（例: {{diff}}）が含まれていた場合、その位置へ攻撃者制御の
    # diff を <diff> デリミタ外に再注入し得る。count=1 でも「値の中のトークンが先に
    # マッチして本物のプレースホルダが残る」逆の失敗が起きる。re.sub の単一パスなら
    # 置換対象はテンプレート由来のプレースホルダのみで、埋めた値は再走査されない。
    placeholder_values = {
        "rules": rules_content_masked,
        "active_rules": active_rules_masked or "（判例なし）",
        "diff": diff_content_masked,
    }
    prompt = re.sub(
        r"\{\{(rules|active_rules|diff)\}\}",
        lambda m: placeholder_values[m.group(1)],
        prompt_template,
    )

    # Gemini APIの呼び出し（Vertex AI バックエンド / ADC 認証）
    print(f"[INFO] {MODEL} に検閲をリクエストしています...")
    try:
        result_text, client, used_model = call_gemini_with_failover(genai, prompt)
    except Exception:
        # リトライ・フォールバックをすべて尽くした場合のみここに到達する。
        # §5: 例外詳細にはエンドポイントやリクエスト断片が含まれ得るため抽象化する
        print("[ERROR] Vertex AI 呼び出しに失敗しました（全リトライ・フォールバック試行後）。(詳細は非表示)")
        if STRICT_AI_VERIFY:
            set_commit_status("error", "AI verification failed")
            sys.exit(2)
        # fail-open: 同上。検閲不能を success(skipped) として通し、マージをブロックしない。
        set_commit_status("success", "AI verification skipped (Vertex error)")
        sys.exit(0)

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

        # Draft PRの聖域化（判例 DX-001: レビューはするがブロックしない）
        # NOTE: ここを success にすると、draft→ready 転換では再検閲が走らない
        # （GitHub は ready_for_review で synchronize を発火しない）ため、
        # FAIL コードがそのまま必須チェックを通過できてしまう。pending なら
        # Draft 中は何もブロックせず（Draft はそもそもマージ不可）、ready 後は
        # 再実行で success になるまでマージ不可となり、判例の意図
        # 「Ready for Review 時点から厳格にブロック」が技術的に強制される。
        if is_draft:
            print("[INFO] Draft PRのため、Status Check は Pending（警告のみ・非ブロック）とします。")
            set_commit_status("pending", "FAIL (Draft - warning only. Re-run needed when ready)")
            sys.exit(0)
        else:
            set_commit_status("failure", "AI verification failed. Check PR comments.")
            sys.exit(1)
    elif re.search(r"^RESULT:\s*PASS\b", result_text, re.MULTILINE):
        print("[INFO] 検閲結果: 合格しました。")
        comment_body = "### 🤖 AI検閲官\n\n✅ **AI検閲を通過しました。** 憲法に準拠した素晴らしいコードです！"
        post_or_update_comment(comment_body)
        set_commit_status("success", "AI verification passed")
        send_datadog_metrics("pass", is_draft, pr_author)

        # 逆引き仕様書生成（検閲に成功した client / モデルを再利用する）
        generate_changelog(client, diff_content_masked, used_model)
        sys.exit(0)
    else:
        # 想定外の出力形式。従来は「FAIL を含まない＝合格」という否定形判定で、
        # プロンプトインジェクション成功時やモデルの形式逸脱時に合格側へ倒れていた。
        # 検閲不能（判定が得られない）として SDK 欠落・Vertex 障害と同じ
        # STRICT_AI_VERIFY 契約に従う（true なら fail-closed）。
        print("[ERROR] AI応答が想定形式 (RESULT: PASS / RESULT: FAIL) ではありません。")
        if STRICT_AI_VERIFY:
            set_commit_status("error", "AI verification returned unexpected output")
            sys.exit(2)
        set_commit_status("success", "AI verification skipped (unexpected output)")
        sys.exit(0)

def generate_changelog(client, diff_content, model=None):
    print("\n[INFO] 逆引き仕様書（変更証跡）を生成しています...")
    model = model or MODEL
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
        doc_response = client.models.generate_content(
            model=model,
            contents=prompt,
            config={"temperature": 0.2},
        )
        doc_text = doc_response.text.strip()
        
        date_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{date_str}_pr_{PR_NUMBER}.md"
        bucket_name = os.environ.get("CHANGELOG_BUCKET", f"{PROJECT_ID}-changelog-store")
        
        storage_client = storage.Client(project=PROJECT_ID)
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(f"change-logs/{filename}")
        blob.upload_from_string(doc_text, content_type="text/markdown")
        
        print(f"[INFO] 逆引き仕様書を GCS にアップロードしました: gs://{bucket_name}/change-logs/{filename}")
                
    except Exception:
        # §5: 例外詳細は出力しない（バケット名・エンドポイント等が含まれ得る）
        print("[WARN] 逆引き仕様書の生成またはアップロードに失敗しました。(詳細は非表示)")

if __name__ == "__main__":
    main()
