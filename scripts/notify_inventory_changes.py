import json
import os
import requests
import sys
import time
import jwt

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
        encoded_jwt = jwt.encode(payload, self.private_key, algorithm="RS256")

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

def get_inventory(file_name):
    search_paths = [
        file_name,
        os.path.join('governance/admin/factory', file_name),
        os.path.join('../../../', file_name)
    ]
    for path in search_paths:
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    return json.load(f)
            except Exception:
                continue
    return {"apps": {}, "sandboxes": {}}

def set_github_variable(token, repo, var_name, value):
    """GitHub API を使ってリポジトリ変数を設定または更新する"""
    url = f"https://api.github.com/repos/{repo}/actions/variables"
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    data = {"name": var_name, "value": str(value)}
    
    res = requests.post(url, headers=headers, json=data)
    if res.status_code in [409, 422]: 
        url_patch = f"{url}/{var_name}"
        res_patch = requests.patch(url_patch, headers=headers, json=data)
        if res_patch.status_code not in [201, 204]:
            raise Exception(f"Failed to update variable {var_name}: {res_patch.status_code}")
    elif res.status_code != 201:
        raise Exception(f"Failed to create variable {var_name}: {res.status_code} {res.text}")

def notify_slack(webhook_url, text):
    if not webhook_url: return
    try:
        requests.post(webhook_url, json={"text": text}, timeout=30)
    except Exception as e:
        print(f"Error sending Slack: {e}")

def main():
    projects_json_str = os.environ.get('PROJECTS_JSON', '{}')
    projects_data = json.loads(projects_json_str)
    
    webhook_url = os.environ.get('SLACK_WEBHOOK_URL')
    deploy_webhook_url = os.environ.get('DEPLOY_SLACK_WEBHOOK_URL')
    admin_id = os.environ.get('GCP_PROJECT_ID')
    admin_num = os.environ.get('GCP_PROJECT_NUMBER')

    # 1. まず既存の PAT を試行
    gh_token = os.environ.get('GITHUB_TOKEN')
    
    # 2. PAT がない、またはプレースホルダーの場合は GitHub App 認証を試行
    if not gh_token or "PLACEHOLDER" in gh_token:
        app_id = os.environ.get('GITHUB_APP_ID')
        private_key = os.environ.get('GITHUB_APP_PRIVATE_KEY')
        inst_id = os.environ.get('GITHUB_APP_INSTALLATION_ID')
        
        if app_id and private_key and inst_id and "PLACEHOLDER" not in app_id:
            print("Using GitHub App authentication for variable sync...")
            try:
                auth = GitHubAppAuth(app_id, private_key, inst_id)
                gh_token = auth.get_installation_access_token()
            except Exception as e:
                print(f"Failed to authenticate with GitHub App: {e}")

    old_inv = get_inventory('inventory_old.json')
    new_inv = get_inventory('inventory.json')

    sync_results = {"success_admin": [], "success_dev": [], "failed": []}

    if not gh_token:
        print("ERROR: No valid GitHub token found (PAT or App).")

    # Apps の処理
    for app_name, config in new_inv.get('apps', {}).items():
        old_config = old_inv.get('apps', {}).get(app_name)
        if not old_config or config != old_config:
            repo = config.get('github_repo')
            if not repo or not gh_token: continue
            
            try:
                print(f"🔄 Syncing variables for {app_name} to {repo}...")
                set_github_variable(gh_token, repo, "APP_NAME", app_name)
                set_github_variable(gh_token, repo, "ADMIN_PROJECT_ID", admin_id)
                set_github_variable(gh_token, repo, "ADMIN_PROJECT_NUMBER", admin_num)
                
                app_out = projects_data.get('apps', {}).get(app_name, {})
                if app_out.get('dev'): set_github_variable(gh_token, repo, "ID_DEV", app_out['dev'])
                if app_out.get('stg'): set_github_variable(gh_token, repo, "ID_STG", app_out['stg'])
                if app_out.get('prd'): set_github_variable(gh_token, repo, "ID_PRD", app_out['prd'])
                
                app_info_admin = [f"・🚀 *{app_name}*"]
                # 開発者用ガイド (📦)
                app_info_dev = [
                    f"📦 *New Application Environment Ready!*\n"
                    f"アプリ名: `{app_name}` の払い出しが完了しました。\n\n"
                    f"⚠️ *リマインド (GitHub App 制限運用時)*:\n"
                    f"GitHub App の設定でリポジトリを制限している場合は、新リポジトリ `{repo}` を追加してください。\n"
                    f"（これを忘れるとデプロイ時に権限エラーとなります）\n\n"
                    f"🚀 **GitHub Variables は自動同期済みです！**\n"
                    f"そのまま `main` ブランチへ Push して `{app_name}` のデプロイを開始してください。"
                ]

                envs_info = []
                for env in config.get('environments', []):
                    p_id = app_out.get(env, "N/A")
                    envs_info.append(f"    - `{env}` : `{p_id}`")
                
                app_info_admin.extend(envs_info)
                app_info_dev.append("\n".join(envs_info))
                
                sync_results["success_admin"].append("\n".join(app_info_admin))
                sync_results["success_dev"].append("\n".join(app_info_dev))
            except Exception as e:
                sync_results["failed"].append(f"{app_name} ({e})")

    # Sandboxes の処理
    for sb_key, config in new_inv.get('sandboxes', {}).items():
        old_config = old_inv.get('sandboxes', {}).get(sb_key)
        if not old_config or config != old_config:
            repo = config.get('github_repo')
            if not repo or not gh_token: continue
            
            try:
                print(f"🧪 Syncing variables for Sandbox {sb_key} to {repo}...")
                set_github_variable(gh_token, repo, "APP_NAME", sb_key)
                set_github_variable(gh_token, repo, "ADMIN_PROJECT_ID", admin_id)
                set_github_variable(gh_token, repo, "ADMIN_PROJECT_NUMBER", admin_num)
                
                sb_id = projects_data.get('sandboxes', {}).get(sb_key)
                if sb_id: set_github_variable(gh_token, repo, "ID_SANDBOX", sb_id)
                
                expiry = config.get('expiry_date', '未設定')

                # 1. 管理者向けサマリー (Todoを明示)
                sync_results["success_admin"].append(
                    f"・🧪 *Sandbox: {sb_key}* (dev: `{sb_id}`)\n"
                    f"  👉 [TODO] GitHub App の許可設定に `{repo}` を追加してください。"
                )

                # 2. 開発者向けガイド (完成報告 + ID + 期限)
                msg_sb = (
                    f"🧪 *New Sandbox Ready!*\n"
                    f"サンドボックス `{sb_key}` が完成しました！\n\n"
                    f"・*プロジェクトID*: `{sb_id}`\n"
                    f"・*削除期限*: `{expiry}` (JST)\n\n"
                    f"🚀 **GitHub Variables は自動同期済みです！**\n"
                    f"そのまま `main` または `sandbox/**` ブランチへ Push してデプロイを開始してください。\n"
                    f"※ 期限を過ぎると自動削除されます。延長は台帳の `expiry_date` を更新してください。"
                )
                sync_results["success_dev"].append(msg_sb)
            except Exception as e:
                sync_results["failed"].append(f"{sb_key} ({e})")

    # Slack まとめ報告
    if sync_results["success_admin"] or sync_results["failed"]:
        msg_admin = "🚀 *GCP Infrastructure Provisioning Summary*\n"
        if sync_results["success_admin"]:
            msg_admin += "✅ *以下のプロジェクト資産が作成/更新されました*:\n"
            for s in sync_results["success_admin"]:
                msg_admin += f"{s}\n"
        if sync_results["failed"]:
            msg_admin += "\n❌ *同期失敗 (要確認)*:\n- " + "\n- ".join(sync_results["failed"])
        notify_slack(deploy_webhook_url or webhook_url, msg_admin)

    if sync_results["success_dev"]:
        for msg_dev in sync_results["success_dev"]:
            notify_slack(webhook_url, msg_dev)

    if sync_results["failed"]:
        sys.exit(1)

if __name__ == "__main__":
    main()
