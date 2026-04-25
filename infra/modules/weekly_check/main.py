import os
import json
import base64
import requests
import sys
from datetime import datetime, timedelta
from google.cloud import compute_v1, storage, iam_admin_v1, resourcemanager_v3, secretmanager_v1
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
            except Exception as e:
                print(f"Error scanning folder {folder_id}: {e}")

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
            # ※ 自動削除は sandbox_lifecycle モジュールに集約されました
            is_sandbox = labels.get('managed') == 'terraform-sandbox'
            if is_sandbox:
                expiry = labels.get('expiry_date')
                if expiry:
                    try:
                        expiry_dt = datetime.strptime(expiry, '%Y-%m-%d')
                        if today + timedelta(hours=48) >= expiry_dt:
                            warning_projects.append(f"{pj} (Owner: {labels.get('owner', 'Unknown')}, Expiry: {expiry})")
                    except: pass

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
            except: pass
            
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
                    except: pass
            except: pass
            
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
            except: pass
            
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
            except: pass
            
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
            except: pass
            
            if sql_count == 0: report_chunk += "| 該当なし | – | – |\n"
            report_chunk += "\n"

            # --- ⑥ API Keys (制限なしキー) ---
            report_chunk += "### API Keys (制限なし)\n| Key ID | Risk | Priority |\n|---|---|---|\n"
            api_count = 0
            try:
                apikeys_svc = discovery.build('apikeys', 'v2', cache_discovery=False)
                keys_res = apikeys_svc.projects().locations().keys().list(parent=f"projects/{pj}/locations/global").execute()
                for key in keys_res.get('keys', []):
                    # 制限（restrictions）がない、または不十分なものを検知
                    if 'restrictions' not in key:
                        key_id = key['name'].split('/')[-1][:8]
                        report_chunk += f"| {key_id}... | 🚨 無制限 | High |\n"
                        api_count += 1
                        counts["High"] += 1
            except: pass
            
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
            except: pass
            
            if sa_count == 0: report_chunk += "| 該当なし | – | – | – |\n"
            report_chunk += "\n"

            # --- ⑧ Cloud Audit Logs (Data Access Logs) ---
            report_chunk += "### Audit Logs (重要サービスのログ欠如)\n| Service | Risk | Priority |\n|---|---|---|\n"
            log_count = 0
            try:
                # 監査対象とする重要サービスのリスト
                required_audit_services = ["iam.googleapis.com", "secretmanager.googleapis.com", "storage.googleapis.com"]
                # 組織レベルから継承されているはずのサービス（環境変数から取得）
                inherited_services = os.environ.get('INHERITED_AUDIT_SERVICES', '').split(',')
                
                # プロジェクトレベルの IAM ポリシーを取得して Audit Config を確認
                policy = rm_client.get_iam_policy(resource=f"projects/{pj}")
                configs = [c.service for c in policy.audit_configs]
                
                # allServices があれば全てOK、なければ個別にチェック
                if "allServices" not in configs:
                    for svc in required_audit_services:
                        # プロジェクトの設定にも組織の継承設定にもなければ警告
                        if svc not in configs and svc not in inherited_services:
                            report_chunk += f"| {svc.split('.')[0]} | 🚨 ログ欠如 | High |\n"
                            log_count += 1
                            counts["High"] += 1
            except: pass
            
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
                        # IAP 帯域以外からの 22 番ポート開放があるかチェック
                        for src in fw.source_ranges:
                            if src != iap_range and src != "10.0.0.0/8": # IAP と内部以外
                                report_chunk += f"| {fw.name} | 22 | 🚨 直接露出 | High |\n"
                                iap_count += 1
                                counts["High"] += 1
                                break
            except: pass
            
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
                
                # レポートへのリンク生成 (環境変数から取得。なければデフォルト)
                url_template = os.environ.get(
                    'GCP_CONSOLE_URL_STORAGE', 
                    'https://console.cloud.google.com/storage/browser/_details/{bucket}/{filename}?project={project_id}'
                )
                report_link = url_template.format(bucket=report_bucket, filename=filename, project_id=project_id)
            except Exception as e:
                print(f"Error uploading report to GCS: {e}")
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
            requests.post(slack_url, json={"text": security_msg}, timeout=30)

        # ② サンドボックス削除予告・報告
        if deleted_projects or warning_projects:
            sandbox_msg = ""
            if deleted_projects:
                sandbox_msg += f"🗑️ *期限切れのため自動削除したサンドボックス*\n- " + "\n- ".join(deleted_projects) + "\n\n"
            if warning_projects:
                sandbox_msg += f"⚠️ *48時間以内に削除予定のサンドボックス (延長はラベルを更新してください)*\n- " + "\n- ".join(warning_projects) + "\n\n"
            
            sandbox_slack_url = get_secret(admin_pj, os.environ.get('SANDBOX_SLACK_SECRET_NAME', 'infra-sandbox-slack-webhook'))
            if sandbox_slack_url:
                requests.post(sandbox_slack_url, json={"text": sandbox_msg})
            elif slack_url:
                requests.post(slack_url, json={"text": f"(Notice) Sandbox Lifecycle:\n{sandbox_msg}"})

    except Exception as e:
        print(f"Error: {e}")

def get_secret(pj, name):
    client = secretmanager_v1.SecretManagerServiceClient()
    try:
        name_path = f"projects/{pj}/secrets/{name}/versions/latest"
        res = client.access_secret_version(request={"name": name_path})
        return res.payload.data.decode("UTF-8").strip()
    except: return None

def get_ai_summary(api_key, text):
    # Gemini 2.5-flash (2026年最新モデル) を使用
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
        return res.json()['candidates'][0]['content']['parts'][0]['text']
    except: return "Gemini 解析エラーが発生しました。"
