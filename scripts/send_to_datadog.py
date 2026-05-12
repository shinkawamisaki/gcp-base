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
import json

DATADOG_ENABLED = os.environ.get("DATADOG_ENABLED", "false").lower() == "true"


def send_metric(result):
    if not DATADOG_ENABLED:
        print("[INFO] DATADOG_ENABLED=false のためスキップします。")
        return

    api_key = os.environ.get("DATADOG_API_KEY", "").strip()
    if not api_key:
        print("[WARN] DATADOG_API_KEY が未設定です。スキップします。")
        return

    url = os.environ.get("DATADOG_API_URL", "https://api.datadoghq.com/api/v2/series")
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
        with urllib.request.urlopen(req) as resp:
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
