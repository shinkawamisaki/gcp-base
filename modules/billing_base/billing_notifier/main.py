import base64
import hashlib
import json
import os

import functions_framework
import requests
from google.cloud import secretmanager, storage

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


def _marker_name(budget_display_name, cost_interval_start, threshold_exceeded):
    """デデュープ鍵（予算名 × 期間 × 閾値）を GCS オブジェクト名として安全な形（ハッシュ）にする。
    予算名にスペースや記号が含まれても安全。期間（costIntervalStart）が変わると鍵も変わり自然にリセットされる。"""
    raw = f"{budget_display_name}|{cost_interval_start}|{threshold_exceeded}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _already_notified(bucket_name, marker_name):
    """この「閾値 × 期間」を既に通知済みかを判定する。
    OPS-007: マーカーは「配信前の関所」にしない。確認できない時は fail-open（False=通知側へ倒す）とし、
    取りこぼし（サイレントロス）より「重複1回」を選ぶ。バケット未設定時もデデュープせず通知する。"""
    if not bucket_name:
        return False
    try:
        client = storage.Client()
        return client.bucket(bucket_name).blob(marker_name).exists()
    except Exception:
        # §5: 詳細は出さない。確認不能でも通知は止めない（fail-open）。
        print("[WARN] 重複抑制マーカーの確認に失敗。fail-open で通知を継続します（詳細は非表示）")
        return False


def _mark_notified(bucket_name, marker_name):
    """配信成功後にのみ呼ぶ。OPS-007: 書き込み失敗は best-effort（最悪でも次サイクルで重複1回。
    取りこぼしは発生しない）。"""
    if not bucket_name:
        return
    try:
        client = storage.Client()
        client.bucket(bucket_name).blob(marker_name).upload_from_string("", content_type="text/plain")
    except Exception:
        # §5: 詳細は出さない。通知自体は成功しているため、記録失敗は WARN に留める（握り潰しではない）。
        print("[WARN] 重複抑制マーカーの記録に失敗。次サイクルで重複し得ますが取りこぼしはありません（詳細は非表示）")


@functions_framework.cloud_event
def notify_slack(cloud_event):
    """
    Pub/Sub からの予算アラートを受け取り、Slack に通知を送信する。
    """
    project_id = os.environ.get("PROJECT_ID")

    # --- 1. Pub/Sub メッセージの解釈とメッセージ整形 ---
    # 解釈/整形の失敗は「壊れたメッセージ」であり再試行しても直らないため return（無限リトライ回避）。
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
        # デデュープ鍵に使う「予算期間の開始時刻」。期間が変わると鍵が変わり、抑制は自然にリセットされる。
        cost_interval_start = data.get("costIntervalStart", "")

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
    except Exception:
        # §5: 詳細は出さない。メッセージ自体が壊れている場合はリトライ不要なので return。
        print("[ERROR] 予算アラートメッセージの解釈に失敗しました（詳細は非表示）")
        return

    # --- 1.5 重複抑制（デデュープ） ---
    # GCP 予算 Pub/Sub は超過後も毎メッセージで同じ閾値を再送するため、抑制しないと鳴り続ける。
    # OPS-007: マーカーは「配信成功の記録」であって「配信前の関所」にしない。順序を厳守する。
    # 期間（costIntervalStart）が取れない場合はデデュープせず通知する（期間跨ぎの過剰抑制＝取りこぼしを防ぐ fail-open）。
    marker_bucket = os.environ.get("MARKER_BUCKET")
    marker_name = (
        _marker_name(budget_display_name, cost_interval_start, threshold_exceeded)
        if cost_interval_start else None
    )
    if marker_name and _already_notified(marker_bucket, marker_name):
        print("Skipping duplicate notification: this threshold for this budget period was already notified.")
        return

    # --- 2. Slack 送信 ---
    # 予算超過は最重要シグナル。未達を握り潰さず、失敗時は関数を失敗扱いにして可視化＋リトライさせる。
    # OPS-007: 送信失敗時は raise し、マーカーは書かない（Pub/Sub リトライで再送＝at-least-once）。
    try:
        slack_secret_id = os.environ.get("SLACK_SECRET_ID")
        if not slack_secret_id:
            raise RuntimeError("SLACK_SECRET_ID が未設定")
        slack_webhook_url = get_secret(slack_secret_id)
        resp = requests.post(slack_webhook_url, json={"text": message}, timeout=10)
        resp.raise_for_status()
    except Exception:
        # §5: 例外詳細（webhook URL / Secret 情報を含み得る）は出さない。
        print("[ERROR] 予算アラートの Slack 送信に失敗しました（詳細は非表示）")
        # §5: from None で例外連結を遮断し、元例外（webhook URL / Secret 情報）がトレースに漏れるのを防ぐ。
        raise RuntimeError("予算アラートの Slack 送信に失敗しました") from None

    # --- 3. 配信成功後にのみマーカーを記録（OPS-007: 関所にしない＝ここで初めて「通知済み」を刻む） ---
    if marker_name:
        _mark_notified(marker_bucket, marker_name)
    print(f"Notification sent for {budget_display_name} at {threshold_percent}%")
