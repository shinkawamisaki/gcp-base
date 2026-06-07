import os
import requests
import time
import jwt
from datetime import datetime, timedelta
from google.cloud import resourcemanager_v3, secretmanager_v1

class GitHubAppAuth:
    """GitHub App 認証用のトークンを取得するクラス"""
    def __init__(self, app_id, private_key, installation_id):
        self.app_id = app_id
        self.private_key = private_key
        self.installation_id = installation_id

    def get_installation_access_token(self):
        # 1. JWT を生成 (GitHub App として認証)
        now = int(time.time())
        payload = {
            "iat": now - 60,
            "exp": now + (10 * 60),
            "iss": self.app_id
        }
        try:
            encoded_jwt = jwt.encode(payload, self.private_key, algorithm="RS256")
        except Exception:
            # §5: 例外詳細（鍵情報を含み得る）はログに出さず抽象化する。
            print("[ERROR] GitHub App 用 JWT の生成に失敗しました（詳細は非表示）")
            raise

        # 2. Installation Access Token (IAT) を取得
        url = f"https://api.github.com/app/installations/{self.installation_id}/access_tokens"
        headers = {
            "Authorization": f"Bearer {encoded_jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        }
        res = requests.post(url, headers=headers, timeout=30)
        res.raise_for_status()
        return res.json()["token"]

def run_lifecycle_check(event, context):
    """サンドボックスの期限チェックと通知（1時間おきに実行）"""
    project_id = os.environ.get('PROJECT_ID')
    admin_pj = os.environ.get('SECRET_PROJECT_ID', project_id)
    scan_folder = os.environ.get('SCAN_FOLDER_ID')
    slack_secret = os.environ.get('SANDBOX_SLACK_SECRET_NAME', 'infra-sandbox-slack-webhook')
    
    print(f"Lifecycle Check Start. Scan Folder: {scan_folder}")

    try:
        rm_client = resourcemanager_v3.ProjectsClient()
        if not scan_folder:
            print("Error: SCAN_FOLDER_ID is not set.")
            return

        projects = [p for p in rm_client.list_projects(parent=scan_folder)]
        print(f"Checking {len(projects)} projects...")

        deleted_projects = []
        final_warnings = []
        daily_warnings = []
        skipped_deletions = []   # app_base ラベル欠落等で自動削除をスキップ（要手動確認）
        failed_deletions = []    # 削除ワークフロー起動に失敗（沈黙させず通知に載せる）
        
        # 本ジョブは日次運用前提（既定 schedule は朝7時 / var.lifecycle_schedule）。
        # 期限切れ削除も警告通知も「実行ごと」に1回行うため、実行時刻でのゲートは設けない。
        now_jst = datetime.utcnow() + timedelta(hours=9)

        for project in projects:
            pj = project.project_id
            labels = getattr(project, 'labels', {})
            
            if labels.get('managed') != 'terraform-sandbox':
                continue

            expiry = labels.get('expiry_date')
            if not expiry:
                continue

            try:
                expiry_dt = datetime.strptime(expiry, '%Y-%m-%d')
                owner = labels.get('owner', '不明')
                diff_days = (expiry_dt.date() - now_jst.date()).days
                
                # カウントダウン通知（始業前に届くよう既定スケジュールは朝7時）。
                # 日次1回実行が前提なので時刻ゲートは不要。頻度を上げると警告も同回数送られる点に注意。
                if diff_days == 0:
                    final_warnings.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry})")
                elif 0 < diff_days <= 3:
                    daily_warnings.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry}) - ⚠️ あと {diff_days} 日")

                # 期限切れの物理削除トリガー
                if diff_days <= 0:
                    # fail-closed: 削除対象キーを ID から推測しない（不可逆な削除で推測は誤削除の温床）。
                    # app_base ラベルが無いサンドボックスは自動削除せずスキップし、警告に積む。
                    sandbox_key = labels.get('app_base')
                    if not sandbox_key:
                        print(f"[WARN] {pj}: app_base ラベル欠落のため自動削除をスキップ（要手動確認）")
                        skipped_deletions.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry}) — app_base ラベル欠落のため自動削除をスキップ")
                        continue

                    try:
                        print(f"Triggering cleanup for expired sandbox: {pj}")
                        # sandbox_key は app_base ラベルから取得済み（推測しない）。

                        # 1. まず既存の PAT を試行
                        gh_token = get_secret(admin_pj, os.environ.get('GH_TOKEN_SECRET_NAME', 'infra-github-token'))
                        
                        # 2. PAT がない、またはプレースホルダーの場合は GitHub App 認証を試行
                        if not gh_token or "PLACEHOLDER" in gh_token:
                            app_id = get_secret(admin_pj, "infra-github-app-id")
                            private_key = get_secret(admin_pj, "infra-github-app-private-key")
                            inst_id = get_secret(admin_pj, "infra-github-app-installation-id")
                            
                            if app_id and private_key and inst_id and "PLACEHOLDER" not in app_id:
                                print("Using GitHub App authentication...")
                                auth = GitHubAppAuth(app_id, private_key, inst_id)
                                gh_token = auth.get_installation_access_token()
                        
                        gh_org = os.environ.get('GH_ORG_NAME')
                        gh_repo = os.environ.get('GH_REPO_NAME')
                        
                        if gh_token and gh_org and gh_repo:
                            url = f"https://api.github.com/repos/{gh_org}/{gh_repo}/actions/workflows/platform-delete-sandbox.yml/dispatches"
                            headers = {
                                "Authorization": f"Bearer {gh_token}",
                                "Accept": "application/vnd.github+json",
                                "X-GitHub-Api-Version": "2022-11-28"
                            }
                            data = {"ref": "main", "inputs": {"sandbox_id": sandbox_key}}
                            
                            res = requests.post(url, json=data, headers=headers, timeout=30)
                            if res.status_code == 204:
                                print(f"Successfully triggered deletion workflow for {sandbox_key}")
                                deleted_projects.append(f"・`{pj}` (所有者: {owner}, 期限: {expiry})")
                            else:
                                # §5: レスポンス本文は出さない。失敗は握り潰さず通知に載せる。
                                print(f"[ERROR] 削除ワークフローの起動に失敗 (status={res.status_code}・詳細は非表示)")
                                failed_deletions.append(f"・`{pj}` (所有者: {owner}) — 削除ワークフローの起動失敗 (status={res.status_code})")
                        else:
                            # GitHub 設定/トークン欠落で削除をトリガーできない。沈黙させず通知に載せる。
                            print("[ERROR] GitHub 設定またはトークンが欠落しており削除をトリガーできません（詳細は非表示）")
                            failed_deletions.append(f"・`{pj}` (所有者: {owner}) — GitHub 設定/トークン欠落で削除トリガー不可")

                    except Exception:
                        # §5: 例外詳細は出さず抽象化。削除の失敗を握り潰さず通知に載せる。
                        print(f"[ERROR] サンドボックス削除処理に失敗 (...{pj[-4:] if pj else 'N/A'}・詳細は非表示)")
                        failed_deletions.append(f"・`{pj}` (所有者: {owner}) — 削除処理が例外で失敗（要確認）")
            
            except Exception:
                # §5: 例外詳細は出さず抽象化。expiry_date が不正で評価不能なサンドボックスは
                # 自動削除せず（fail-closed）スキップ扱いで通知に載せる。
                print(f"[WARN] {pj}: expiry_date ラベルの解釈に失敗（自動削除せずスキップ・要確認）")
                skipped_deletions.append(f"・`{pj}` (期限ラベル: {expiry}) — expiry_date が不正で評価不能")

        # Slack 通知
        if deleted_projects or final_warnings or daily_warnings or skipped_deletions or failed_deletions:
            slack_url = get_secret(admin_pj, slack_secret)
            if not slack_url:
                # 通知経路が確保できないのに削除等が走った可能性 → 沈黙させず関数を失敗扱いにする。
                raise RuntimeError("Slack webhook の取得に失敗し、ライフサイクル通知を送信できません")

            blocks = [{"type": "header", "text": {"type": "plain_text", "text": "📦 サンドボックス・ライフサイクル管理"}}]
            if deleted_projects:
                blocks.append({
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": "🗑️ *期限切れのため自動クリーンアップを開始したサンドボックス*\n" + "\n".join(deleted_projects) + "\n\n> ※ 台帳（`inventory.json`）から削除されました。この後 Terraform によりリソースが物理的に消去されます。"}
                })
            if failed_deletions:
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "🚨 *【要対応】自動削除のトリガーに失敗したサンドボックス*\n" + "\n".join(failed_deletions)}})
            if skipped_deletions:
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "⚠️ *【要手動確認】ラベル不備で自動削除をスキップしたサンドボックス*\n" + "\n".join(skipped_deletions)}})
            if final_warnings:
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "🚨 *【最終警告】本日のうちに削除が開始されます！*\n" + "\n".join(final_warnings)}})
            if daily_warnings:
                blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "⚠️ *削除期限が近づいています (3日以内)*\n" + "\n".join(daily_warnings)}})

            resp = requests.post(slack_url, json={"blocks": blocks}, timeout=30)
            resp.raise_for_status()
            print("Notification sent.")
        else:
            print("No action needed.")

    except Exception:
        # dead-man's-switch: 安全装置（削除/期限通知）が落ちたら「沈黙＝健全」の誤解を生むため、
        # best-effort で Slack に失敗を叫んでから raise（関数を失敗扱いにし監視に乗せる）。§5 で詳細は出さない。
        print("[ERROR] サンドボックス・ライフサイクル処理が予期せず失敗しました（詳細は非表示）")
        try:
            alert_url = get_secret(admin_pj, slack_secret)
            if alert_url:
                requests.post(
                    alert_url,
                    json={"text": "🚨 *[要確認] サンドボックス・ライフサイクル Bot が異常終了しました*\nログを確認してください（自動削除/期限通知が機能していない可能性があります）。"},
                    timeout=30,
                )
        except Exception:
            print("[ERROR] 失敗アラートの Slack 通知にも失敗しました（詳細は非表示）")
        raise

def get_secret(pj, name):
    client = secretmanager_v1.SecretManagerServiceClient()
    try:
        path = f"projects/{pj}/secrets/{name}/versions/latest"
        res = client.access_secret_version(request={"name": path})
        return res.payload.data.decode("UTF-8").strip()
    except Exception:
        print("Security Notice: Failed to retrieve required credentials from Secret Manager.")
        return None
