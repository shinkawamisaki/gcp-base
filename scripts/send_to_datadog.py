import os
import sys
import time
import urllib.request
import json
import subprocess

def get_datadog_api_key():
    # 1. CI/CD環境などで環境変数として注入されている場合
    api_key = os.environ.get("DATADOG_API_KEY")
    if api_key:
        return api_key

    # 2. GCP Secret Managerから取得する場合
    project_id = os.environ.get("GOOGLE_CLOUD_PROJECT")
    # 憲法3.3: ハードコーディング排除のため、シークレット名は環境変数から取得
    secret_name = os.environ.get("DATADOG_SECRET_NAME")

    if not project_id or not secret_name:
        print("[WARN] GOOGLE_CLOUD_PROJECT and DATADOG_SECRET_NAME must be set to fetch secrets.")
        return None
        
    try:
        api_key = subprocess.check_output(
            ["gcloud", "secrets", "versions", "access", "latest", 
             "--secret", secret_name, "--project", project_id],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        return api_key
    except Exception:
        print(f"[WARN] Failed to fetch secret '{secret_name}'. (Error details hidden for security)")
        
    return None

def send_metric(metric_name, value):
    api_key = get_datadog_api_key()
    if not api_key:
        print("[WARN] DATADOG_API_KEY could not be retrieved from env or Secret Manager. Skipping Datadog metrics.")
        return

    # 憲法3.3: ハードコーディング排除のため、URLは環境変数から取得
    url = os.environ.get("DATADOG_API_URL")
    if not url:
        print("[WARN] DATADOG_API_URL is not set. Skipping Datadog metrics.")
        return
    
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "DD-API-KEY": api_key
    }
    
    data = {
        "series": [
            {
                "metric": metric_name,
                "type": 3, # gauge
                "points": [
                    {
                        "timestamp": int(time.time()),
                        "value": float(value)
                    }
                ]
            }
        ]
    }
    
    req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req) as response:
            if response.status == 202:
                print(f"[INFO] Successfully sent metric '{metric_name}' to Datadog.")
            else:
                print(f"[WARN] Datadog API returned status: {response.status}")
    except Exception:
        print("[ERROR] Failed to send metric to Datadog. (Error details hidden for security)")

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/send_to_datadog.py <pass|fail>")
        sys.exit(1)
        
    result = sys.argv[1].lower()
    
    if result == "pass":
        send_metric("ai.verification.success", 1)
    elif result == "fail":
        send_metric("ai.verification.fail", 1)
    else:
        print(f"[ERROR] Unknown result: {result}")
        sys.exit(1)

if __name__ == "__main__":
    main()
