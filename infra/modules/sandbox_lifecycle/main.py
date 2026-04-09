import os
import json
import base64
import requests
from datetime import datetime, timedelta
from google.cloud import resourcemanager_v3, secretmanager_v1
from googleapiclient import discovery # 【修正】より安定した discovery API を使用

# Force redeploy: 2026-03-28 08:30:00 (JST)
def run_lifecycle_check(event, context):
    """サンドボックスの期限チェックと通知（1時間おきに実行）"""
    project_id = os.environ.get('PROJECT_ID')
    # SECRET_PROJECT_ID が空または未設定の場合のフォールバックを確実に
    admin_pj = os.environ.get('SECRET_PROJECT_ID')
    if not admin_pj:
        admin_pj = project_id
    
    scan_folder = os.environ.get('SCAN_FOLDER_ID')
    slack_secret = os.environ.get('SANDBOX_SLACK_SECRET_NAME', 'infra-sandbox-slack-webhook')
    
    print(f"Lifecycle Check Start. Scan Folder: {scan_folder}")

    try:
        rm_client = resourcemanager_v3.ProjectsClient()
        # Lien 操作用に discovery API のリソースを構築
        rm_service = discovery.build('cloudresourcemanager', 'v3', cache_discovery=False)
        
        if not scan_folder:
            print("Error: SCAN_FOLDER_ID is not set.")
            return

        projects = [p for p in rm_client.list_projects(parent=scan_folder)]
        print(f"Checking {len(projects)} projects...")

        deleted_projects = []
        final_warnings = []
        daily_warnings = []
        
        # 現在時刻（JST換算。UTC+9）
        # Cloud Functions の標準 UTC 運用を考慮し、時間計算を安定させます
        now_jst = datetime.utcnow() + timedelta(hours=9)
        current_hour = now_jst.hour

        for project in projects:
            pj = project.project_id
            labels = getattr(project, 'labels', {})
            
            if labels.get('managed') != 'terraform-sandbox':
                continue

            expiry = labels.get('expiry_date')
            if not expiry:
                continue

            try:
                # 期限日の 00:00:00 (JST) に削除対象とする
                expiry_dt = datetime.strptime(expiry, '%Y-%m-%d')
                owner = labels.get('owner', '不明')
                
                # 期限日（当日）の判定
                if now_jst.date() >= expiry_dt.date():
                    try:
                        # 【修正】直接削除ではなく、GitHub Actions をトリガーして台帳(inventory.json)から消す
                        print(f"Triggering cleanup for expired sandbox: {pj}")
                        
                        # inventory.json のキーを取得 (ラベル app_base を最優先で使用)
                        sandbox_key = labels.get('app_base')
                        
                        # もしラベルがなければプロジェクトIDからフォールバック（念のため）
                        if not sandbox_key:
                            parts = pj.split('-')
                            sandbox_key = f"{parts[2]}-{parts[3]}" if len(parts) >= 4 else pj.replace('dev-sandbox-', '')
                        
                        # GitHub トークンを取得 (専用シークレット infra-github-token を優先)
                        gh_token = get_secret(admin_pj, os.environ.get('GH_TOKEN_SECRET_NAME', 'infra-github-token'))
                        gh_org = os.environ.get('GH_ORG_NAME')
                        gh_repo = os.environ.get('GH_REPO_NAME')
                        
                        if gh_token and gh_org and gh_repo:
                            # 既存の webhook URL からトークンを抽出、またはシークレットを直接使用
                            # ここではワークフローの起動 (workflow_dispatch) を実行
                            url = f"https://api.github.com/repos/{gh_org}/{gh_repo}/actions/workflows/platform-delete-sandbox.yml/dispatches"
                            headers = {
                                "Authorization": f"Bearer {gh_token}",
                                "Accept": "application/vnd.github+json",
                                "X-GitHub-Api-Version": "2022-11-28"
                            }
                            data = {"ref": "main", "inputs": {"sandbox_id": sandbox_key}}
                            
                            res = requests.post(url, json=data, headers=headers, timeout=30)
                            if res.status_code == 204:
                                print(f"Successfully triggered deletion workflow for {sandbox_key}")
                                # 詳細な通知情報をリストに追加
                                deleted_projects.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry})")
                            else:
                                print(f"Failed to trigger GitHub Actions: {res.status_code} {res.text}")
                        else:
                            print(f"ERROR: GitHub config missing. gh_org={gh_org}, gh_repo={gh_repo}")

                    except Exception as e:
                        print(f"ERROR: Failed to process cleanup for project {pj}: {e}")
                
                # 始業前（朝7時台）のカウントダウン通知
                elif current_hour == 7:
                    diff_days = (expiry_dt.date() - now_jst.date()).days
                    if diff_days <= 3:
                        status = "🚨 *【最終警告】本日中に削除されます*" if diff_days == 0 else f"⚠️ *あと {diff_days} 日で削除されます*"
                        daily_warnings.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry}) - {status}")
            
            except Exception as e:
                print(f"Date parse error in {pj}: {e}")

        # Slack 通知
        if deleted_projects or final_warnings or daily_warnings:
            slack_url = get_secret(admin_pj, slack_secret)
            if not slack_url: return

            blocks = [{"type": "header", "text": {"type": "plain_text", "text": "📦 サンドボックス・ライフサイクル管理"}}]

            if deleted_projects:
                blocks.append({
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": "🗑️ *期限切れのため自動クリーンアップを開始したサンドボックス*\n" + "\n".join(deleted_projects) + "\n\n> ※ 台帳（`inventory.json`）から削除されました。この後 Terraform によりリソースが物理的に消去されます。"}
                })
            if final_warnings:
                blocks.append({
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": "🚨 *【最終警告】本日のうちに削除が開始されます！*\n" + "\n".join(final_warnings)}
                })
            if daily_warnings:
                blocks.append({
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": "⚠️ *削除期限が近づいています (3日以内)*\n" + "\n".join(daily_warnings)}
                })

            requests.post(slack_url, json={"blocks": blocks}, timeout=30)
            print("Notification sent.")
        else:
            print("No action needed.")

    except Exception as e:
        print(f"Fatal error: {e}")

def get_secret(pj, name):
    client = secretmanager_v1.SecretManagerServiceClient()
    try:
        path = f"projects/{pj}/secrets/{name}/versions/latest"
        res = client.access_secret_version(request={"name": path})
        return res.payload.data.decode("UTF-8").strip()
    except:
        return None
