import base64
import json
import os

import functions_framework
import requests
from google.cloud import secretmanager

def get_secret(secret_id):
    """Secret Managerから最新版のシークレットを取得する"""
    client = secretmanager.SecretManagerServiceClient()
    project_id = os.environ.get("PROJECT_ID")
    
    if "/secrets/" not in secret_id:
        name = f"projects/{project_id}/secrets/{secret_id}/versions/latest"
    else:
        base_name = secret_id.split("/versions/")[0]
        name = f"{base_name}/versions/latest"
        
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8").strip()

@functions_framework.cloud_event
def notify_slack(cloud_event):
    """
    Pub/Sub からの予算アラートを受け取り、Slack に通知を送信する。
    """
    project_id = os.environ.get("PROJECT_ID")
    try:
        pubsub_message = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
        data = json.loads(pubsub_message)

        # データの取得
        threshold_exceeded = data.get("alertThresholdExceeded", 0.0)
        cost_amount = data.get("costAmount", 0.0)
        
        # 【ガード】閾値が0（未超過）またはコストが発生していない場合は通知をスキップ
        # これにより、30分おきの定期的なコスト報告（超過なし）を無視し、通知スパムを防ぎます。
        if threshold_exceeded == 0.0 or cost_amount == 0.0:
            print(f"Skipping notification: threshold={threshold_exceeded}, cost={cost_amount}")
            return

        # 表示用データの整形
        threshold_percent = threshold_exceeded * 100
        budget_display_name = data.get("budgetDisplayName", "Unknown Budget")
        budget_amount = data.get("budgetAmount", 0.0)
        currency_code = data.get("currencyCode", "JPY")

        # メッセージの構築
        emoji = "🚨" if threshold_percent >= 100 else "⚠️"
        timing_text = f"予算の *{threshold_percent:.0f}%* を超過"
        
        # 請求レポートへのディープリンク作成 (環境変数から取得。なければデフォルト)
        url_template = os.environ.get(
            'BILLING_REPORT_URL_TEMPLATE', 
            'https://console.cloud.google.com/billing/reports?project={project_id}&grouping=SERVICE'
        )
        report_url = url_template.format(project_id=project_id)
        
        message = (
            f"{emoji} *GCP予算アラート: {budget_display_name}*\n"
            f"*プロジェクトID (通知元):* `{project_id}`\n"
            f"*通知タイミング:* {timing_text}\n"
            f"*現在の利用額合計:* `{cost_amount:,.0f} {currency_code}`\n"
            f"*予算設定:* `{budget_amount:,.0f} {currency_code}`\n\n"
            f"👉 *<{report_url}|サービス別の明細（ログやAPI）を確認する>*\n"
            f"※クリックするとGCPコンソールの詳細内訳グラフが開きます。"
        )

        slack_secret_id = os.environ.get("SLACK_SECRET_ID")
        slack_webhook_url = get_secret(slack_secret_id)
        
        requests.post(slack_webhook_url, json={"text": message}, timeout=10).raise_for_status()
        print(f"Notification sent for {budget_display_name} at {threshold_percent}%")

    except Exception as e:
        print(f"Error processing budget notification: {e}")
