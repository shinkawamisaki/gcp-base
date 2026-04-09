import json
import os
import requests
import sys

def get_inventory(file_name):
    # 1. カレントディレクトリで探す (factory内で実行された場合)
    # 2. governance/admin/factory/ 配下で探す (ルートで実行された場合)
    search_paths = [
        file_name,
        os.path.join('governance/admin/factory', file_name),
        os.path.join('../../../', file_name) # factoryから見たルート (万が一用)
    ]
    
    for path in search_paths:
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    return json.load(f)
            except Exception:
                continue
    return {"apps": {}, "sandboxes": {}}

def notify_slack(webhook_url, text):
    if not webhook_url:
        print("Webhook URL is empty. Skipping notification.")
        return
    try:
        response = requests.post(webhook_url, json={"text": text}, timeout=30)
        response.raise_for_status()
    except Exception as e:
        print(f"Error sending Slack notification: {e}")

def main():
    projects_json_str = os.environ.get('PROJECTS_JSON', '{}')
    projects_data = json.loads(projects_json_str)
    
    webhook_url = os.environ.get('SLACK_WEBHOOK_URL')
    admin_project_id = os.environ.get('GCP_PROJECT_ID')
    admin_project_number = os.environ.get('GCP_PROJECT_NUMBER')

    # インベントリファイルの読み込み (新旧比較)
    old_inv = get_inventory('inventory_old.json')
    new_inv = get_inventory('inventory.json')

    # 1. Apps の差分抽出 (新規追加 or 変更)
    for app_name, new_config in new_inv.get('apps', {}).items():
        old_config = old_inv.get('apps', {}).get(app_name)
        if not old_config or new_config != old_config:
            app_out = projects_data.get('apps', {}).get(app_name, {})
            if not app_out: continue

            msg = f"*📦 New Application Environment Ready!*\n"
            msg += f"アプリ名: `{app_name}` の払い出し/更新が完了しました。\n\n"
            msg += "以下の設定を `app-deploy.yml` の `env:` セクションに貼り付けてください：\n"
            msg += "```yaml\n"
            msg += "  # ===============================================================\n"
            msg += "  # ⚙️ App 設定エリア (払い出し済み環境)\n"
            msg += "  # ===============================================================\n"
            msg += f"  APP_NAME:             \"{app_name}\"\n"
            msg += f"  ADMIN_PROJECT_ID:     \"{admin_project_id}\"\n"
            msg += f"  ADMIN_PROJECT_NUMBER: \"{admin_project_number}\"\n\n"
            msg += "  # 🚀 以下のプロジェクトIDを app-deploy.yml に貼り付けてください\n"
            if app_out.get('dev'):   msg += f"  ID_DEV:     \"{app_out['dev']}\"\n"
            if app_out.get('stg'):   msg += f"  ID_STG:     \"{app_out['stg']}\"\n"
            if app_out.get('prd'):   msg += f"  ID_PRD:     \"{app_out['prd']}\"\n"
            if app_out.get('audit'): msg += f"  # ID_AUDIT:   \"{app_out['audit']}\" (監査専用環境)\n"
            msg += "  # ===============================================================\n"
            msg += "```\n"
            msg += "🚀 準備が整いました。開発を開始しましょう！"
            notify_slack(webhook_url, msg)

    # 2. Sandboxes の差分抽出 (新規追加 or 変更)
    for sb_key, new_config in new_inv.get('sandboxes', {}).items():
        old_config = old_inv.get('sandboxes', {}).get(sb_key)
        if not old_config or new_config != old_config:
            sb_id = projects_data.get('sandboxes', {}).get(sb_key)
            if not sb_id: continue

            expiry = new_config.get('expiry_date', '未設定')
            repo = new_config.get('github_repo', '未設定')

            msg = f"*🧪 New Sandbox Ready!*\n"
            msg += f"サンドボックス: `{sb_key}` の払い出し/更新が完了しました。\n\n"
            msg += f"📅 *自動削除の予定期限:* `{expiry}`\n"
            msg += f"🔗 *デプロイ元リポジトリ:* `{repo}`\n\n"
            msg += "以下の設定を `sandbox-deploy.yml` の `env:` セクションに貼り付けてください：\n"
            msg += "```yaml\n"
            msg += "  # ===============================================================\n"
            msg += "  # 🧪 Sandbox 設定エリア\n"
            msg += "  # ===============================================================\n"
            msg += f"  APP_NAME:             \"{sb_key}\"\n"
            msg += f"  ADMIN_PROJECT_ID:     \"{admin_project_id}\"\n"
            msg += f"  ADMIN_PROJECT_NUMBER: \"{admin_project_number}\"\n\n"
            msg += f"  ID_SANDBOX:           \"{sb_id}\"\n"
            msg += "  # ===============================================================\n"
            msg += "```\n"
            msg += "⚠️ 期限が来ると自動削除されますのでご注意ください。"
            notify_slack(webhook_url, msg)

if __name__ == "__main__":
    main()
