FROM python:3.11-slim

# OSパッケージのインストール (git, jq等)
RUN apt-get update && apt-get install -y \
    git \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 依存パッケージのインストール
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# メインスクリプトは Cloud Build 時点のワークスペースからマウントされるか、
# もしくは COPY される想定ですが、汎用性のために残します。
# COPY すると古いスクリプトが使われる可能性もあるので、実行時に指定パスを呼ぶようにします。
