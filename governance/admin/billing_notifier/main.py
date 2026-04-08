import base64
import json
import requests
import os
from google.cloud import secretmanager

def get_secret(secret_id):
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{os.environ['PROJECT_ID']}/secrets/{secret_id}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8").strip()

def notify_slack(event, context):
    try:
        # 1. メッセージの受信
        pubsub_message = base64.b64decode(event['data']).decode('utf-8')
        data = json.loads(pubsub_message)
        
        # 2. 通知のしきい値チェック
        threshold = data.get('alertThresholdExceeded', 0)
        if threshold == 0:
            return

        # 3. 必要データの抽出
        cost = data.get('costAmount', 0)
        budget = data.get('budgetAmount', 0)
        project_id = os.environ.get('PROJECT_ID', 'Unknown')
        
        # 環境変数からシークレット名を取得（OSS/マルチ環境対応）
        slack_secret_name = os.environ.get('SLACK_SECRET_NAME', 'billing-slack-webhook-url')
        slack_url = get_secret(slack_secret_name)
        
        # 4. 請求レポートへのディープリンク作成
        report_url = f"https://console.cloud.google.com/billing/reports?project={project_id}&grouping=SERVICE"
        
        # 5. Slackメッセージの構築
        message = {
            "text": f"⚠️ *GCP予算アラート ({project_id})*",
            "attachments": [{
                "color": "warning" if threshold < 1.0 else "danger",
                "fields": [
                    {"title": "現在の利用額合計", "value": f"¥{int(cost):,}", "short": True},
                    {"title": "予算設定", "value": f"¥{int(budget):,}", "short": True},
                    {"title": "通知タイミング", "value": f"予算の{int(threshold*100)}%を超過", "short": False}
                ],
                "footer": f"👉 [サービス別の明細（ログやAPI）を確認する]({report_url})\n※クリックするとGCPコンソールの詳細内訳グラフが開きます。"
            }]
        }
        
        # 6. 通知実行
        requests.post(slack_url, json=message)
        print(f"Notification sent for project {project_id} (cost: {cost})")
        
    except Exception as e:
        print(f"Error in notify_slack: {e}")
