#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
local_dir="$repo_root/.local"
mkdir -p "$local_dir"
chmod 700 "$local_dir"
if [[ ! -s "$local_dir/api-token" ]]; then openssl rand -hex 32 >"$local_dir/api-token"; fi
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -keyout "$local_dir/backend.key" -out "$local_dir/backend.crt" \
  -subj "/CN=bot-api.meeting-bot.svc" \
  -addext "subjectAltName=DNS:bot-api.meeting-bot.svc,DNS:bot-api.meeting-bot.svc.cluster.local" >/dev/null 2>&1
chmod 600 "$local_dir/api-token" "$local_dir/backend.key"
kubectl -n meeting-bot create secret generic meeting-bot-api-auth --from-file=token="$local_dir/api-token" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n meeting-bot create secret tls bot-api-backend-tls --cert="$local_dir/backend.crt" --key="$local_dir/backend.key" --dry-run=client -o yaml | kubectl apply -f -
echo "Secrets were installed in meeting-bot. The token/key remain in gitignored $local_dir."
