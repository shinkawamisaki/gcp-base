# 設計書：プロジェクト台帳の物理分離 (apps.json / sandboxes.json)

## 1. 背景と目的 (Rationale)

現状、本基盤では `inventory.json` という単一のファイルで「正式なプロジェクト(Apps)」と「実験用のサンドボックス(Sandboxes)」の両方を管理しています。しかし、組織の成長に伴い以下の課題が顕在化します。

- **承認プロセスの衝突**: 正式なプロジェクト追加にはインフラチームの厳格なレビューが必要ですが、サンドボックスは開発者が即座に作成できるべきです。単一ファイルでは GitHub の `CODEOWNERS` 等による柔軟な権限設定が困難です。
- **変更履歴のノイズ**: 頻繁に追加・削除されるサンドボックスの履歴が、重要な正式プロジェクトの変更履歴（Git log）を埋め尽くしてしまいます。
- **ガバナンスの最適化**: 「インフラチームの目（承認）」が必要な領域と、そうでない領域を物理的に分けることで、統制とスピードを両立させます。

## 2. 修正方針 (Strategy)

### 2.1 台帳の物理分離
`inventory.json` を廃止し、役割の異なる 2 つのファイルに分割します。
- **`apps.json`**: 本番・検証用プロジェクト（インフラチームによる承認制）。
- **`sandboxes.json`**: 実験用サンドボックス（開発者によるセルフサービス・承認不要）。

### 2.2 オートメーションの一貫性維持
台帳を参照している全てのシステム（Terraform, GitHub Actions, AI Bot）を、新しい 2 ファイル構成に対応させます。

## 3. 具体的な修正箇所 (Implementation Details)

### 3.1 Terraform (Project Factory)
`governance/admin/factory/main.tf` において、2 つのファイルを個別に読み込み、Terraform の `merge()` 関数を用いて一つの `local.inventory` 変数に統合します。
これにより、既存のモジュールやループ処理への影響を最小限に抑えます。

### 3.2 GitHub Actions: 作成・削除
- **`platform-create-sandbox.yml`**: プロジェクト情報を追記する対象を `sandboxes.json` に変更します。
- **`platform-delete-sandbox.yml`**: プロジェクト情報を削除する対象を `sandboxes.json` に変更します。

### 3.3 GitHub Actions: 基盤デプロイと通知
- **`platform-admin.yml`**: 
    - `check-changes` ジョブにおいて、`apps.json` と `sandboxes.json` の両方の変更を監視対象に含めます。
    - `Notify Developer` ステップにおいて、それぞれのファイルの Git 差分から「今回追加されたプロジェクト」を特定するロジックに更新します。

### 3.4 権限制御 (GitHub CODEOWNERS)
リポジトリルートに `.github/CODEOWNERS` を配置（または更新）し、以下の設定を推奨します。
```text
# 正式プロジェクトはインフラチームの承認を必須とする
/governance/admin/factory/apps.json  @infra-team

# サンドボックスは全開発者に解放する（または特定の開発者グループを割り当てる）
/governance/admin/factory/sandboxes.json  *
```

## 4. 移行手順 (Migration Path)

1. **ファイル作成**: `apps.json` と `sandboxes.json` を作成し、現在の `inventory.json` の中身を振り分け。
2. **Terraform 修正**: ファイル合算ロジックの実装と `terraform apply` による整合性確認。
3. **ワークフロー修正**: GitHub Actions のターゲットファイルを一括置換。
4. **クリーンアップ**: 旧 `inventory.json` の物理削除。

---
**最終更新日**: 2026-04-08
**作成者**: AI Assistant (Gemini)
