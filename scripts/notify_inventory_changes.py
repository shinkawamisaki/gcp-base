import json
import os
import requests
import sys

def get_inventory(file_name):
    # 実行ディレクトリに関わらずファイルを探す (factory 内なら ./ 、ルートなら governance/admin/factory/)
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
    
    # まずは作成を試みる
    res = requests.post(url, headers=headers, json=data)
    if res.status_code in [409, 422]: # 409: Already exists, 422: Unprocessable Entity
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
    gh_token = os.environ.get('GITHUB_TOKEN') # PAT
    admin_id = os.environ.get('GCP_PROJECT_ID')
    admin_num = os.environ.get('GCP_PROJECT_NUMBER')

    old_inv = get_inventory('inventory_old.json')
    new_inv = get_inventory('inventory.json')

    sync_results = {"success_admin": [], "success_dev": [], "failed": []}

    # 1. Apps の処理
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
                
                # 管理者用サマリー (🚀)
                app_info_admin = [f"・🚀 *{app_name}*"]
                # 開発者用ガイド (📦)
                app_info_dev = [f"📦 *New Application Environment Ready!*\nアプリ名: `{app_name}` の払い出しが完了しました。\n\n🚀 **GitHub Variables は自動同期済みです！**\nそのまま `main` ブランチへ Push して `{app_name}` のデプロイを開始してください。"]
                
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

    # 2. Sandboxes の処理
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
                
                sync_results["success_dev"].append(f"・🚀 *{sb_key}* (dev: `{sb_id}`)")
            except Exception as e:
                sync_results["failed"].append(f"{sb_key} ({e})")

    # Slack まとめ報告
    # A. 管理者向け通知 (#gcp-infra)
    if sync_results["success_admin"] or sync_results["failed"]:
        msg_admin = "🚀 *GCP Infrastructure Provisioning Summary*\n"
        if sync_results["success_admin"]:
            msg_admin += "✅ *以下のプロジェクト資産が作成/更新されました*:\n"
            for s in sync_results["success_admin"]:
                msg_admin += f"{s}\n"

        if sync_results["failed"]:
            msg_admin += "\n❌ *同期失敗 (要確認)*:\n- " + "\n- ".join(sync_results["failed"])

        notify_slack(deploy_webhook_url or webhook_url, msg_admin)

    # B. 開発者向け通知 (#gcp-sandbox)
    if sync_results["success_dev"]:
        for msg_dev in sync_results["success_dev"]:
            notify_slack(webhook_url, msg_dev)

    # 1件でも失敗があれば、Action 自体はエラーで落とす（ただし処理は最後までやりきった状態）
    if sync_results["failed"]:
        sys.exit(1)

if __name__ == "__main__":
    main()
