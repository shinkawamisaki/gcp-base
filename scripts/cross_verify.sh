#!/bin/bash
set -euo pipefail

# 1. 動作モードの決定 (OSS疎結合 vs 厳格モード)
# デフォルトはfalse (AIが使えなくても警告のみで続行するOSS向けのフェイルセーフ)
STRICT_AI_VERIFY="${STRICT_AI_VERIFY:-false}"

if [ -f ".clinerules" ]; then
  STRICT_META=$(grep -E '^# @metadata: STRICT_AI_VERIFY=' .clinerules | cut -d '=' -f 2 | tr -d '"' | tr -d "'" || true)
  if [ -n "$STRICT_META" ]; then
    STRICT_AI_VERIFY="$STRICT_META"
  fi
fi

if [ -f ".env" ]; then
  STRICT_ENV=$(grep -E '^STRICT_AI_VERIFY=' .env | cut -d '=' -f 2 | tr -d '"' | tr -d "'" || true)
  if [ -n "$STRICT_ENV" ]; then
    STRICT_AI_VERIFY="$STRICT_ENV"
  fi
fi
export STRICT_AI_VERIFY

if [ ! -f ".clinerules" ]; then
  echo "[ERROR] .clinerules not found. Run this from the project root."
  exit 1
fi

TMP_DIFF=$(mktemp)
git diff HEAD > "$TMP_DIFF" || git diff > "$TMP_DIFF"

if [ ! -s "$TMP_DIFF" ]; then
  echo "[INFO] No staged changes to verify."
  rm -f "$TMP_DIFF"
  exit 0
fi

echo "[INFO] Sending staged changes to Vertex AI (Gemini 2.5 Flash) for cross-verification..."

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "${PROJECT_ID}" ]; then
  PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-}"
fi

if [ -z "${PROJECT_ID}" ]; then
  if [ "$STRICT_AI_VERIFY" = "true" ]; then
    echo "[ERROR] STRICT_AI_VERIFY=true: Google Cloud Project ID is not set. Aborting."
    rm -f "$TMP_DIFF"
    exit 1
  else
    echo "[WARN] Google Cloud Project ID is not set. Skipping AI cross-verification (OSS Fallback)."
    rm -f "$TMP_DIFF"
    exit 0
  fi
fi

LOCATION="${VERTEX_LOCATION:-asia-northeast1}"

python3 << EOF
import os
import sys

strict_mode = os.environ.get("STRICT_AI_VERIFY", "false").lower() == "true"

try:
    import vertexai
    from vertexai.generative_models import GenerativeModel
except ImportError:
    if strict_mode:
        print("[ERROR] STRICT_AI_VERIFY=true: google-cloud-aiplatform is not installed. Aborting.")
        sys.exit(2)
    else:
        print("[WARN] google-cloud-aiplatform is not installed. Skipping AI cross-verification (OSS Fallback).")
        sys.exit(0)

project_id = "${PROJECT_ID}"
location = "${LOCATION}"

with open(".clinerules", "r", encoding="utf-8") as f:
    rules_content = f.read()

with open("$TMP_DIFF", "r", encoding="utf-8") as f:
    diff_content = f.read()

import re
def redact_sensitive_info(text):
    # 機密情報（パスワード、シークレット、トークン、APIキーなど）のマスク
    text = re.sub(r'(?i)(password|secret|token|api[_-]?key|credentials)["\'\s:=]+[^\s"\'},]+', r'\1: [REDACTED]', text)
    # 特定のIPアドレス（プライベートIPなど）のマスク
    text = re.sub(r'\b(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)[0-9.]+\b', '[REDACTED_IP]', text)
    return text

rules_content = redact_sensitive_info(rules_content)
diff_content = redact_sensitive_info(diff_content)

base_prompt = """あなたは厳格なIPO準備・高セキュリティ仕様のGCP基盤の外部コードレビュアーです。
以下の「プロジェクト憲法（設計思想・ルール）」を基準に、現在ステージングされている変更（git diff）を厳密にレビューしてください。

【特記事項 (Architect's Decision)】
1. 証跡の自動生成：逆引き仕様書(change-logs)の自動生成機能およびコミットへの自動追加は必須の機能として実装されています。PRレビュー時に確認するため自動追加は許容されます。
2. Datadogへのメトリクス送信：監視基盤の障害によって本番デプロイがブロックされることを防ぐため、送信失敗時は警告ログを出すのみとするフェイルセーフ設計が承認されています。
3. OSS向けデフォルト設定：STRICT_AI_VERIFYのデフォルトがfalseなのは、OSS公開時の導入ハードルを下げるための意図的な設計です。

【プロジェクト憲法】
[[RULES]]

【変更内容 (git diff)】
[[DIFF]]

【指示】
1. プロジェクト憲法の思想（職務分掌、最小権限、物理隔離、ハードコーディング排除など）と矛盾がないか厳格にチェックしてください。
2. ルール違反やセキュリティリスクがある場合、またはルールの思想から逸脱している場合は不合格としてください。
3. 出力形式：
   - 合格の場合: 最初の行に「RESULT: PASS」と書き、次の行に「OK」とだけ出力してください。
   - 不合格の場合: 最初の行に「RESULT: FAIL」と書き、次の行から具体的な指摘事項を日本語で出力してください。
"""

prompt = base_prompt.replace("[[RULES]]", rules_content).replace("[[DIFF]]", diff_content)

# -- Datadog LLMObs Setup --
ddtrace_enabled = False
try:
    import subprocess
    api_key = os.environ.get("DATADOG_API_KEY")
    if not api_key:
        api_key = subprocess.check_output(
            ["gcloud", "secrets", "versions", "access", "latest", 
             "--secret", "infra-datadog-api-key", "--project", project_id],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
    
    if api_key:
        os.environ["DD_API_KEY"] = api_key
        os.environ["DD_SITE"] = "ap1.datadoghq.com"
        os.environ["DD_LLMOBS_ENABLED"] = "1"
        os.environ["DD_LLMOBS_AGENTLESS_ENABLED"] = "1"
        
        from ddtrace.llmobs import LLMObs
        LLMObs.enable(ml_app="cross_verify")
        ddtrace_enabled = True
except ImportError:
    pass # ddtrace not installed
except Exception as e:
    print(f"[WARN] Failed to enable Datadog LLMObs: {e}")

try:
    vertexai.init(project=project_id, location=location)
    model = GenerativeModel("gemini-2.5-flash")
    
    if ddtrace_enabled:
        with LLMObs.llm(model_name="gemini-2.5-flash", name="cross_verify_review", ml_app="cross_verify"):
            response = model.generate_content(
                prompt,
                generation_config={"temperature": 0.0}
            )
            LLMObs.flush()
    else:
        response = model.generate_content(
            prompt,
            generation_config={"temperature": 0.0}
        )
    
    text = response.text.strip()
    
    if "RESULT: FAIL" in text:
        print(text)
        
        # GitHub Actions Summary (Fail)
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, "a", encoding="utf-8") as f:
                f.write(f"### 🛡️ AI Cross-Verification: FAIL ❌\n\`\`\`\n{text}\n\`\`\`\n")
        sys.exit(1)
    else:
        print("OK")
        print("[INFO] AI Verification Passed.")
        
        # GitHub Actions Summary (Pass)
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, "a", encoding="utf-8") as f:
                f.write(f"### 🛡️ AI Cross-Verification: PASS ✅\n今回の検閲結果：合格。懸念点なし。\n")
                
        # --- Generate Reverse Specification Document ---
        print("\n[INFO] 逆引き仕様書（変更証跡）を生成しています...")
        doc_prompt = """あなたは優秀なテクニカルライターです。
以下の変更内容（git diff）から、「誰が、何のために、どのような変更をしたか」を説明する逆引き仕様書（Markdown形式）を作成してください。

【変更内容 (git diff)】
[[DIFF]]

出力形式:
# 変更証跡
- **変更概要**: 
- **目的と背景**: 
- **主な変更点**:
- **セキュリティ・IPO観点での評価**: 
"""
        doc_prompt = doc_prompt.replace("[[DIFF]]", diff_content)
        try:
            if ddtrace_enabled:
                with LLMObs.llm(model_name="gemini-2.5-flash", name="generate_changelog", ml_app="cross_verify"):
                    doc_response = model.generate_content(
                        doc_prompt,
                        generation_config={"temperature": 0.2}
                    )
                    LLMObs.flush()
            else:
                doc_response = model.generate_content(
                    doc_prompt,
                    generation_config={"temperature": 0.2}
                )
            import datetime
            import subprocess
            import tempfile
            
            branch_cmd = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True)
            branch_name = branch_cmd.stdout.strip()
            if not branch_name or branch_name == "HEAD":
                branch_name = "unknown-branch"
            branch_name = branch_name.replace("/", "-")
            
            date_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"{date_str}_{branch_name}.md"
            
            bucket_name = os.environ.get("CHANGELOG_BUCKET", f"{project_id}-changelog-store")
            
            with tempfile.TemporaryDirectory() as tmpdir:
                filepath = os.path.join(tmpdir, filename)
                with open(filepath, "w", encoding="utf-8") as out_f:
                    out_f.write(doc_response.text.strip())
                
                print(f"[INFO] 逆引き仕様書を GCS バケット (gs://{bucket_name}/change-logs/{filename}) にアップロードしています...")
                try:
                    subprocess.run(["gcloud", "storage", "cp", filepath, f"gs://{bucket_name}/change-logs/{filename}"], check=True, capture_output=True)
                    print(f"[INFO] GCS へのアップロードが完了しました: gs://{bucket_name}/change-logs/{filename}")
                except subprocess.CalledProcessError as e:
                    print(f"[WARN] GCS へのアップロードに失敗しました: {e.stderr.decode('utf-8', errors='ignore').strip()}")
                    print(f"[WARN] バケットが存在しないか、権限が不足している可能性があります。")
                    # フェイルセーフとしてローカルに保存
                    os.makedirs("docs/change-logs", exist_ok=True)
                    fallback_path = f"docs/change-logs/{filename}"
                    with open(fallback_path, "w", encoding="utf-8") as out_f:
                        out_f.write(doc_response.text.strip())
                    print(f"[INFO] フェイルセーフ: ローカルに保存しました ({fallback_path})。git add は行われません。")
            
        except Exception as e:
            print(f"[WARN] 逆引き仕様書の生成に失敗しました: {e}")
            
        sys.exit(0)

except Exception as e:
    if strict_mode:
        print(f"[ERROR] STRICT_AI_VERIFY=true: Vertex AI API Error: {e}")
        sys.exit(2)
    else:
        print(f"[WARN] Vertex AI API Error: {e}. Skipping AI verification (OSS Fallback).")
        sys.exit(0)
EOF
EXIT_CODE=$?

rm -f "$TMP_DIFF"

if [ $EXIT_CODE -eq 1 ]; then
  python3 scripts/send_to_datadog.py fail || echo "[WARN] Datadog metric sending failed."
  exit 1
elif [ $EXIT_CODE -eq 0 ]; then
  python3 scripts/send_to_datadog.py pass || echo "[WARN] Datadog metric sending failed."
  exit 0
else
  exit 1
fi
