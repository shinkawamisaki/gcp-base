#!/usr/bin/env python3
"""
スタンドアロン Datadog メトリクス送信スクリプト。
DATADOG_ENABLED=false の場合は何もせず終了する。
使用例: python3 scripts/send_to_datadog.py <pass|fail>
"""

import os
import sys
import time
import urllib.request
import urllib.parse
import json

DATADOG_ENABLED = os.environ.get("DATADOG_ENABLED", "false").lower() == "true"


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """リダイレクトを追わない。

    urllib は既定でリダイレクトを追い、DD-API-KEY ヘッダーもリダイレクト先へ送る。
    https から http へのリダイレクトも許すので、送り先が http:// へリダイレクトすると
    API キーが平文で送られる（下の https の確認は最初の URL にしか効かない）。
    Datadog の API はリダイレクトを返さないので、追わずに送信失敗として扱う
    （3xx は HTTPError になり、send_metric の except で抽象化したメッセージを出す）。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def send_metric(result):
    if not DATADOG_ENABLED:
        print("[INFO] DATADOG_ENABLED=false のためスキップします。")
        return

    api_key = os.environ.get("DATADOG_API_KEY", "").strip()
    if not api_key:
        print("[WARN] DATADOG_API_KEY が未設定です。スキップします。")
        return

    url = os.environ.get("DATADOG_API_URL", "https://api.datadoghq.com/api/v2/series")
    # file:// 等の想定外スキームで開かせない（CWE-22）。
    # DATADOG_API_URL は外部入力（環境変数）であり、https 以外は弾く。
    # 形の崩れた URL（閉じていない IPv6 の [ など）では urlparse が ValueError を出すので、
    # スタックトレースを出さずにスキップする。
    try:
        scheme = urllib.parse.urlparse(url).scheme
    except ValueError:
        print("[WARN] DATADOG_API_URL を URL として解釈できないためスキップします。")
        return
    if scheme != "https":
        print("[WARN] DATADOG_API_URL が https ではないためスキップします。")
        return
    metric_name = f"gcp.ai_verifier.{'pass' if result == 'pass' else 'fail'}_count"

    payload = {
        "series": [{
            "metric": metric_name,
            "type": 1,  # count
            "points": [{"timestamp": int(time.time()), "value": 1}],
        }]
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"DD-API-KEY": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        # 直前で scheme を https に限定済み（file:// や独自スキームは開かない）。
        # urlopen でなく、リダイレクトを追わない opener で送る（API キーを別の URL へ送らない）。
        opener = urllib.request.build_opener(_NoRedirectHandler)
        with opener.open(req) as resp:
            print(f"[INFO] Datadog 送信完了 (metric={metric_name}, status={resp.status})")
    except Exception:
        print("[ERROR] Datadog への送信に失敗しました。(詳細は非表示)")


def main():
    if len(sys.argv) != 2 or sys.argv[1].lower() not in ("pass", "fail"):
        print("Usage: python3 scripts/send_to_datadog.py <pass|fail>")
        sys.exit(1)
    send_metric(sys.argv[1].lower())


if __name__ == "__main__":
    main()
