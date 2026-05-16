import os
import requests
from datetime import datetime, timedelta
from google.cloud import compute_v1, storage, iam_admin_v1, resourcemanager_v3, secretmanager_v1
from google.api_core import exceptions as gcp_exceptions
from googleapiclient import discovery

def run_security_check(event, context):
    """メイン実行関数 (Pub/Sub トリガー)"""
    project_id = os.environ.get('PROJECT_ID')
    admin_pj = os.environ.get('SECRET_PROJECT_ID', project_id)
    report_bucket = os.environ.get('REPORT_BUCKET')
    scan_folders = os.environ.get('SCAN_FOLDER_IDS', '').split(',')
    enable_ai = os.environ.get('ENABLE_AI_SUMMARY', 'true').lower() == 'true'

    print(f"Security Audit Process Started. (Target: ...{project_id[-4:] if project_id else 'N/A'})")

    try:
        # 1. 監査対象プロジェクトの列挙 (フォルダ配下をスキャン)
        rm_client = resourcemanager_v3.ProjectsClient()
        projects = []
        project_ids_seen = set()

        for folder_id in scan_folders:
            if not folder_id.strip(): continue
            print(f"Scanning folder: {folder_id}")
            try:
                for p in rm_client.list_projects(parent=folder_id.strip()):
                    if p.project_id not in project_ids_seen:
                        projects.append(p)
                        project_ids_seen.add(p.project_id)
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] Folder {folder_id}: 権限不足のためスキップ (resourcemanager.projects.list)")
            except Exception as e:
                print(f"[ERROR] Folder {folder_id}: スキャン失敗: {e}")

        if not projects:
            # フォルダIDがない、または空の場合はラベルで検索 (フォールバック)
            query = 'labels.managed:terraform-project-factory OR labels.managed:terraform-sandbox'
            projects = list(rm_client.search_projects(query=query))

        print(f"Found {len(projects)} projects to audit.")

        counts = {"Critical": 0, "High": 0, "Medium": 0, "Low": 0}
        deleted_projects = []
        warning_projects = []
        today = datetime.now()

        raw_report = f"# 🛡️ GCP セキュリティ監査レポート ({today.strftime('%Y-%m-%d')})\n\n"

        for project in projects:
            pj = project.project_id
            labels = getattr(project, 'labels', {})

            # --- サンドボックスの期限チェック (警告のみ) ---
            is_sandbox = labels.get('managed') == 'terraform-sandbox'
            if is_sandbox:
                expiry = labels.get('expiry_date')
                if expiry:
                    try:
                        expiry_dt = datetime.strptime(expiry, '%Y-%m-%d')
                        if today + timedelta(hours=48) >= expiry_dt:
                            warning_projects.append(f"{pj} (Owner: {labels.get('owner', 'Unknown')}, Expiry: {expiry})")
                    except ValueError as e:
                        print(f"[WARN] {pj}: expiry_date のパース失敗 (値: {expiry}): {e}")

            report_chunk = f"## Project: {pj}\n\n"

            # --- ① Firewall ---
            report_chunk += "### Firewall (0.0.0.0/0 開放)\n| Rule | Port | Protocol | Risk | Priority |\n|---|---|---|---|---|\n"
            fw_count = 0
            try:
                fw_client = compute_v1.FirewallsClient()
                for fw in fw_client.list(project=pj):
                    if "0.0.0.0/0" in fw.source_ranges:
                        allowed_ports = []
                        for allow in fw.allowed:
                            port_list = ",".join(allow.ports) if allow.ports else "All"
                            allowed_ports.append(f"{allow.I_p_protocol}:{port_list}")
                        report_chunk += f"| {fw.name} | {' / '.join(allowed_ports)} | TCP/UDP | ⚠️ 全開放 | High |\n"
                        fw_count += 1
                        counts["High"] += 1
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ①Firewall: 権限不足のためスキップ (compute.firewalls.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ①Firewall: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – | – | – |\n"

            if fw_count == 0: report_chunk += "| 該当なし | – | – | – | – |\n"
            report_chunk += "\n"

            # --- ② Storage ---
            report_chunk += "### Storage (公開バケット)\n| Bucket | Risk | Priority |\n|---|---|---|\n"
            st_count = 0
            try:
                st_client = storage.Client(project=pj)
                for bucket in st_client.list_buckets():
                    try:
                        policy = bucket.get_iam_policy(requested_policy_version=3)
                        bindings = getattr(policy, 'bindings', policy if isinstance(policy, list) else [])
                        is_p = False
                        for b in bindings:
                            role = b.get('role') if isinstance(b, dict) else getattr(b, 'role', '')
                            members = b.get('members', []) if isinstance(b, dict) else getattr(b, 'members', [])
                            if role == "roles/storage.objectViewer" and "allUsers" in members:
                                is_p = True; break
                        if is_p:
                            report_chunk += f"| {bucket.name} | 🚨 公開中 | Critical |\n"
                            st_count += 1
                            counts["Critical"] += 1
                    except gcp_exceptions.PermissionDenied:
                        print(f"[WARN] {pj} ②Storage bucket {bucket.name}: IAMポリシー取得権限なし")
                    except Exception as e:
                        print(f"[ERROR] {pj} ②Storage bucket {bucket.name}: {e}")
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ②Storage: 権限不足のためスキップ (storage.buckets.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ②Storage: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – |\n"

            if st_count == 0: report_chunk += "| 該当なし | – | – |\n"
            report_chunk += "\n"

            # --- ③ IAM ---
            report_chunk += "### IAM (手動発行キー)\n| SA Name | Key ID | Risk | Priority |\n|---|---|---|---|\n"
            iam_count = 0
            try:
                iam_client = iam_admin_v1.IAMClient()
                for sa in iam_client.list_service_accounts(name=f"projects/{pj}"):
                    res = iam_client.list_service_account_keys(name=sa.name)
                    keys = getattr(res, 'keys', [])
                    for key in keys:
                        if int(getattr(key, 'key_type', 0)) == 1:
                            key_id = key.name.split('/')[-1][:8]
                            report_chunk += f"| {sa.email.split('@')[0]} | {key_id} | ⚠️ 漏洩 | High |\n"
                            iam_count += 1
                            counts["High"] += 1
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ③IAM: 権限不足のためスキップ (iam.serviceAccounts.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ③IAM: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – | – |\n"

            if iam_count == 0: report_chunk += "| 該当なし | – | – | – |\n"
            report_chunk += "\n"

            # --- ④ VM ---
            report_chunk += "### Compute Engine (外部IP)\n| Instance | Public IP | Risk | Priority |\n|---|---|---|---|\n"
            vm_count = 0
            try:
                vm_client = compute_v1.InstancesClient()
                for zone, out in vm_client.aggregated_list(project=pj):
                    instances = getattr(out, 'instances', [])
                    if instances:
                        for vm in instances:
                            ext_ip = None
                            for ni in vm.network_interfaces:
                                for ac in ni.access_configs:
                                    if ac.nat_i_p: ext_ip = ac.nat_i_p; break
                            if ext_ip:
                                report_chunk += f"| {vm.name} | {ext_ip} | ⚠️ 露出 | Medium |\n"
                                vm_count += 1
                                counts["Medium"] += 1
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ④VM: 権限不足のためスキップ (compute.instances.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ④VM: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – | – |\n"

            if vm_count == 0: report_chunk += "| 該当なし | – | – | – |\n"
            report_chunk += "\n"

            # --- ⑤ SQL ---
            report_chunk += "### Cloud SQL (パブリックIP)\n| Instance | Risk | Priority |\n|---|---|---|\n"
            sql_count = 0
            try:
                sql_svc = discovery.build('sqladmin', 'v1beta4', cache_discovery=False)
                res = sql_svc.instances().list(project=pj).execute()
                for instance in res.get('items', []):
                    if instance.get('settings', {}).get('ipConfiguration', {}).get('ipv4Enabled'):
                        report_chunk += f"| {instance['name']} | 🚨 露出 | High |\n"
                        sql_count += 1
                        counts["High"] += 1
            except Exception as e:
                err_str = str(e)
                if "403" in err_str or "PERMISSION_DENIED" in err_str:
                    print(f"[WARN] {pj} ⑤SQL: 権限不足のためスキップ (cloudsql.instances.list)")
                    report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – |\n"
                else:
                    print(f"[ERROR] {pj} ⑤SQL: スキャン失敗: {e}")
                    report_chunk += "| ⚠️ スキャンエラー | – | – |\n"

            if sql_count == 0: report_chunk += "| 該当なし | – | – |\n"
            report_chunk += "\n"

            # --- ⑥ API Keys (制限なしキー) ---
            report_chunk += "### API Keys (制限なし)\n| Key ID | Risk | Priority |\n|---|---|---|\n"
            api_count = 0
            try:
                apikeys_svc = discovery.build('apikeys', 'v2', cache_discovery=False)
                keys_res = apikeys_svc.projects().locations().keys().list(parent=f"projects/{pj}/locations/global").execute()
                for key in keys_res.get('keys', []):
                    if 'restrictions' not in key:
                        key_id = key['name'].split('/')[-1][:8]
                        report_chunk += f"| {key_id}... | 🚨 無制限 | High |\n"
                        api_count += 1
                        counts["High"] += 1
            except Exception as e:
                err_str = str(e)
                if "403" in err_str or "PERMISSION_DENIED" in err_str:
                    print(f"[WARN] {pj} ⑥APIKeys: 権限不足のためスキップ (apikeys.keys.list)")
                    report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – |\n"
                else:
                    print(f"[ERROR] {pj} ⑥APIKeys: スキャン失敗: {e}")
                    report_chunk += "| ⚠️ スキャンエラー | – | – |\n"

            if api_count == 0: report_chunk += "| 該当なし | – | – |\n"
            report_chunk += "\n"

            # --- ⑦ Default Service Account (過剰権限) ---
            report_chunk += "### IAM (デフォルトSAの利用)\n| Instance | SA Type | Risk | Priority |\n|---|---|---|---|\n"
            sa_count = 0
            try:
                vm_client = compute_v1.InstancesClient()
                for zone, out in vm_client.aggregated_list(project=pj):
                    instances = getattr(out, 'instances', [])
                    if instances:
                        for vm in instances:
                            for sa in vm.service_accounts:
                                if "compute@developer.gserviceaccount.com" in sa.email:
                                    report_chunk += f"| {vm.name} | デフォルト | ⚠️ 過剰権限 | Medium |\n"
                                    sa_count += 1
                                    counts["Medium"] += 1
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ⑦DefaultSA: 権限不足のためスキップ (compute.instances.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ⑦DefaultSA: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – | – |\n"

            if sa_count == 0: report_chunk += "| 該当なし | – | – | – |\n"
            report_chunk += "\n"

            # --- ⑧ Cloud Audit Logs (Data Access Logs) ---
            report_chunk += "### Audit Logs (重要サービスのログ欠如)\n| Service | Risk | Priority |\n|---|---|---|\n"
            log_count = 0
            try:
                required_audit_services = ["iam.googleapis.com", "secretmanager.googleapis.com", "storage.googleapis.com"]
                inherited_services = os.environ.get('INHERITED_AUDIT_SERVICES', '').split(',')

                policy = rm_client.get_iam_policy(resource=f"projects/{pj}")
                configs = [c.service for c in policy.audit_configs]

                if "allServices" not in configs:
                    for svc in required_audit_services:
                        if svc not in configs and svc not in inherited_services:
                            report_chunk += f"| {svc.split('.')[0]} | 🚨 ログ欠如 | High |\n"
                            log_count += 1
                            counts["High"] += 1
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ⑧AuditLogs: 権限不足のためスキップ (resourcemanager.projects.getIamPolicy)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ⑧AuditLogs: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – |\n"

            if log_count == 0: report_chunk += "| 該当なし | – | – |\n"
            report_chunk += "\n"

            # --- ⑨ IAP (SSH 露出チェック) ---
            report_chunk += "### IAP (SSH 直接露出)\n| Rule | Port | Risk | Priority |\n|---|---|---|---|\n"
            iap_count = 0
            try:
                fw_client = compute_v1.FirewallsClient()
                iap_range = "35.235.240.0/20"
                for fw in fw_client.list(project=pj):
                    if fw.direction == "INGRESS" and any(p == "22" for a in fw.allowed for p in a.ports or []):
                        for src in fw.source_ranges:
                            if src != iap_range and src != "10.0.0.0/8":
                                report_chunk += f"| {fw.name} | 22 | 🚨 直接露出 | High |\n"
                                iap_count += 1
                                counts["High"] += 1
                                break
            except gcp_exceptions.PermissionDenied:
                print(f"[WARN] {pj} ⑨IAP: 権限不足のためスキップ (compute.firewalls.list)")
                report_chunk += "| ⚠️ 権限不足のためスキャン不可 | – | – | – |\n"
            except Exception as e:
                print(f"[ERROR] {pj} ⑨IAP: スキャン失敗: {e}")
                report_chunk += "| ⚠️ スキャンエラー | – | – | – |\n"

            if iap_count == 0: report_chunk += "| 該当なし | – | – | – |\n"
            report_chunk += "\n---\n\n"
            raw_report += report_chunk

        # GCS 保存
        report_link = "N/A"
        if report_bucket:
            try:
                filename = f"report_{today.strftime('%Y%m%d_%H%M%S')}.md"
                storage_client = storage.Client()
                blob = storage_client.bucket(report_bucket).blob(filename)
                blob.upload_from_string(raw_report.encode('utf-8'), content_type='text/markdown; charset=utf-8')

                url_template = os.environ.get(
                    'GCP_CONSOLE_URL_STORAGE',
                    'https://console.cloud.google.com/storage/browser/_details/{bucket}/{filename}?project={project_id}'
                )
                report_link = url_template.format(bucket=report_bucket, filename=filename, project_id=project_id)
            except Exception as e:
                print(f"[ERROR] GCSへのレポートアップロード失敗: {e}")
                report_link = "N/A (Upload Failed)"

        # --- 2. 各チャンネルへの通知実行 ---

        # ① セキュリティ監査結果 (AI要約版)
        ai_comment = "AI要約をスキップしました。"
        if enable_ai:
            gemini_secret = os.environ.get('GEMINI_SECRET_NAME', 'infra-gemini-api-key')
            key = get_secret(admin_pj, gemini_secret)
            if key: ai_comment = get_ai_summary(key, raw_report)

        summary_text = f"*📊 セキュリティサマリー*\n- 🔴 Critical: {counts['Critical']} 件\n- 🟠 High: {counts['High']} 件\n- 🟡 Medium: {counts['Medium']} 件\n- 🔵 Low: {counts['Low']} 件\n\n"
        security_msg = f"{ai_comment}\n\n{summary_text}🔗 *詳細レポート (GCPコンソールで確認)*\n{report_link}"

        slack_url = get_secret(admin_pj, os.environ.get('SLACK_SECRET_NAME', 'infra-audit-slack-webhook'))
        if slack_url:
            try:
                requests.post(slack_url, json={"text": security_msg}, timeout=30)
            except requests.exceptions.RequestException as e:
                print(f"[ERROR] Slack通知失敗 (audit): {e}")

        # ② サンドボックス削除予告・報告
        if deleted_projects or warning_projects:
            sandbox_msg = ""
            if deleted_projects:
                sandbox_msg += f"🗑️ *期限切れのため自動削除したサンドボックス*\n- " + "\n- ".join(deleted_projects) + "\n\n"
            if warning_projects:
                sandbox_msg += f"⚠️ *48時間以内に削除予定のサンドボックス (延長はラベルを更新してください)*\n- " + "\n- ".join(warning_projects) + "\n\n"

            sandbox_slack_url = get_secret(admin_pj, os.environ.get('SANDBOX_SLACK_SECRET_NAME', 'infra-sandbox-slack-webhook'))
            target_url = sandbox_slack_url or slack_url
            msg_body = sandbox_msg if sandbox_slack_url else f"(Notice) Sandbox Lifecycle:\n{sandbox_msg}"
            if target_url:
                try:
                    requests.post(target_url, json={"text": msg_body}, timeout=30)
                except requests.exceptions.RequestException as e:
                    print(f"[ERROR] Slack通知失敗 (sandbox): {e}")

    except Exception as e:
        print(f"[ERROR] 監査プロセス全体で予期しないエラー: {e}")
        raise

def get_secret(pj, name):
    client = secretmanager_v1.SecretManagerServiceClient()
    try:
        name_path = f"projects/{pj}/secrets/{name}/versions/latest"
        res = client.access_secret_version(request={"name": name_path})
        return res.payload.data.decode("UTF-8").strip()
    except gcp_exceptions.PermissionDenied:
        print("Security Notice: Secret Manager へのアクセス権限がありません")
        return None
    except gcp_exceptions.NotFound:
        print("Security Notice: シークレットが見つかりません")
        return None
    except Exception:
        print("Security Notice: シークレットの取得に失敗しました")
        return None

def get_ai_summary(api_key, text):
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={api_key}"
    sys_prompt = (
        "あなたは客観的ですが、冒頭に一言だけ親しみやすい挨拶を添えるセキュリティ監査員です。以下の指示を厳守してください:\n"
        "1. 冒頭に、季節に合わせた短い挨拶（例：もうすっかり春ですね、など）や『お疲れ様です！監査レポートをお届けします』といった、一言だけ柔らかい挨拶を必ず含めてください。\n"
        "2. 渡されたデータの🚨や⚠️の項目のみを抽出し『### 🔴 今すぐ対応（Top5）』を作成してください。不備がなければ『現在、緊急の対応を要する不備は検出されていません。』と書いてください。\n"
        "3. 最後に『📝 総評』を2行以内で記述してください。"
    )
    payload = {"contents": [{"parts": [{"text": f"{sys_prompt}\n\n監査対象データ:\n\n{text}"}]}]}
    try:
        res = requests.post(url, json=payload, timeout=60)
        res.raise_for_status()
        return res.json()['candidates'][0]['content']['parts'][0]['text']
    except requests.exceptions.Timeout:
        print("[ERROR] Gemini API タイムアウト (60s)")
        return "Gemini 解析エラーが発生しました。(タイムアウト)"
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Gemini API リクエスト失敗: {e}")
        return "Gemini 解析エラーが発生しました。"
    except (KeyError, IndexError) as e:
        print(f"[ERROR] Gemini API レスポンス形式が不正: {e}")
        return "Gemini 解析エラーが発生しました。"
