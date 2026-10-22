#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then echo "usage: $0 <count 1..8> [duration-seconds]" >&2; exit 2; fi
count=$1
duration=${2:-300}
[[ "$count" =~ ^[1-8]$ ]] || { echo "count must be 1..8 for the default Karpenter cap" >&2; exit 2; }
[[ "$duration" =~ ^[0-9]+$ ]] && (( duration >= 10 && duration <= 3600 )) || { echo "duration must be 10..3600 seconds" >&2; exit 2; }
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
token_file=${API_TOKEN_FILE:-"$repo_root/.local/api-token"}
api_host=${API_HOST:-$(terraform -chdir="$repo_root/terraform/environments/learning" output -raw api_hostname)}
[[ -r "$token_file" ]] || { echo "API token file not found: $token_file" >&2; exit 1; }
mkdir -p "$repo_root/.local"
for i in $(seq 1 "$count"); do
  key="demo-$(date +%s)-$i-$RANDOM"
  curl --fail-with-body --silent --show-error --request POST "https://$api_host/bots" \
    --header "Authorization: Bearer $(<"$token_file")" \
    --header "Idempotency-Key: $key" --header 'Content-Type: application/json' \
    --data "{\"meetingUrl\":\"https://meet.google.com/demo-room-$i\",\"durationSeconds\":$duration}" \
    | tee -a "$repo_root/.local/submitted-jobs.jsonl"
done
