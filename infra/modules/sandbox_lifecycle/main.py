import os
import json
import base64
import requests
import time
import jwt
from datetime import datetime, timedelta
from google.cloud import resourcemanager_v3, secretmanager_v1
from googleapiclient import discovery

class GitHubAppAuth:
    """GitHub App 認証用のトークンを取得するクラス"""
    def __init__(self, app_id, private_key, installation_id):
        self.app_id = app_id
        self.private_key = private_key
        self.installation_id = installation_id

    def get_installation_access_token(self):
        # 1. JWT を生成 (GitHub App として認証)
        now = int(time.time())
        payload = {
            "iat": now - 60,
            "exp": now + (10 * 60),
            "iss": self.app_id
        }
        try:
            encoded_jwt = jwt.encode(payload, self.private_key, algorithm="RS256")
        except Exception as e:
            print(f"JWT encoding error: {e}")
            raise

        # 2. Installation Access Token (IAT) を取得
        url = f"https://api.github.com/app/installations/{self.installation_id}/access_tokens"
        headers = {
            "Authorization": f"Bearer {encoded_jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        }
        res = requests.post(url, headers=headers, timeout=30)
        res.raise_for_status()
        return res.json()["token"]

def run_lifecycle_check(event, context):
    """サンドボックスの期限チェックと通知（1時間おきに実行）"""
    project_id = os.environ.get('PROJECT_ID')
    admin_pj = os.environ.get('SECRET_PROJECT_ID', project_id)
    scan_folder = os.environ.get('SCAN_FOLDER_ID')
    slack_secret = os.environ.get('SANDBOX_SLACK_SECRET_NAME', 'infra-sandbox-slack-webhook')
    
    print(f"Lifecycle Check Start. Scan Folder: {scan_folder}")

    try:
        rm_client = resourcemanager_v3.ProjectsClient()
        if not scan_folder:
            print("Error: SCAN_FOLDER_ID is not set.")
            return

        projects = [p for p in rm_client.list_projects(parent=scan_folder)]
        print(f"Checking {len(projects)} projects...")

        deleted_projects = []
        final_warnings = []
        daily_warnings = []
        
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
                expiry_dt = datetime.strptime(expiry, '%Y-%m-%d')
                owner = labels.get('owner', '不明')
                diff_days = (expiry_dt.date() - now_jst.date()).days
                
                # 始業前（朝7時台）のカウントダウン通知
                if current_hour == 7:
                    if diff_days == 0:
                        final_warnings.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry})")
                    elif 0 < diff_days <= 3:
                        daily_warnings.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry}) - ⚠️ あと {diff_days} 日")

                # 期限切れの物理削除トリガー
                if diff_days <= 0:
                    try:
                        print(f"Triggering cleanup for expired sandbox: {pj}")
                        sandbox_key = labels.get('app_base')
                        if not sandbox_key:
                            parts = pj.split('-')
                            sandbox_key = f"{parts[2]}-{parts[3]}" if len(parts) >= 4 else pj.replace('dev-sandbox-', '')
                        
                        # 1. まず既存の PAT を試行
                        gh_token = get_secret(admin_pj, os.environ.get('GH_TOKEN_SECRET_NAME', 'infra-github-token'))
                        
                        # 2. PAT がない、またはプレースホルダーの場合は GitHub App 認証を試行
                        if not gh_token or "PLACEHOLDER" in gh_token:
                            app_id = get_secret(admin_pj, "infra-github-app-id")
                            private_key = get_secret(admin_pj, "infra-github-app-private-key")
                            inst_id = get_secret(admin_pj, "infra-github-app-installation-id")
                            
                            if app_id and private_key and inst_id and "PLACEHOLDER" not in app_id:
                                print("Using GitHub App authentication...")
                                auth = GitHubAppAuth(app_id, private_key, inst_id)
                                gh_token = auth.get_installation_access_token()
                        
                        gh_org = os.environ.get('GH_ORG_NAME')
                        gh_repo = os.environ.get('GH_REPO_NAME')
                        
                        if gh_token and gh_org and gh_repo:
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
                                deleted_projects.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry})")
                            else:
                                print(f"Failed to trigger GitHub Actions: {res.status_code} {res.text}")
                        else:
                            print(f"ERROR: GitHub config missing or invalid. gh_token present: {gh_token is not None}")

                    except Exception as e:
                        print(f"ERROR: Failed to process cleanup for project (...{pj[-4:] if pj else 'N/A'}): {e}")
            
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
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "🚨 *【最終警告】本日のうちに削除が開始されます！*\n" + "\n".join(final_warnings)}})
            if daily_warnings:
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "⚠️ *削除期限が近づいています (3日以内)*\n" + "\n".join(daily_warnings)}})

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
    except Exception:
        print("Security Notice: Failed to retrieve required credentials from Secret Manager.")
        return None
