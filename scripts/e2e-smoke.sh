#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
infra="$repo_root/terraform/environments/learning"
host=${API_HOST:-$(terraform -chdir="$infra" output -raw api_hostname)}
token_file=${API_TOKEN_FILE:-"$repo_root/.local/api-token"}
duration=${DURATION_SECONDS:-30}
[[ -r "$token_file" ]] || { echo "API token file missing: $token_file" >&2; exit 1; }

echo "== DNS =="
dig +short "$host"
echo "== Public HTTPS certificate =="
curl --silent --show-error --output /dev/null --write-out 'HTTPS status %{http_code}; TLS verify %{ssl_verify_result}\n' "https://$host/healthz"

key="e2e-$(date +%s)-$RANDOM"
created=$(curl --fail-with-body --silent --show-error --request POST "https://$host/bots" \
  --header "Authorization: Bearer $(<"$token_file")" --header "Idempotency-Key: $key" \
  --header 'Content-Type: application/json' --data "{\"meetingUrl\":\"https://meet.google.com/demo-e2e\",\"durationSeconds\":$duration}")
job_id=$(jq -r '.jobId' <<<"$created")
[[ -n "$job_id" && "$job_id" != "null" ]] || { echo "API did not return a jobId: $created" >&2; exit 1; }
echo "Created job $job_id; polling state."

for _ in $(seq 1 90); do
  job=$(curl --fail-with-body --silent --show-error "https://$host/bots/$job_id" --header "Authorization: Bearer $(<"$token_file")")
  state=$(jq -r '.status' <<<"$job")
  echo "$state"
  if [[ "$state" == "COMPLETED" ]]; then break; fi
  if [[ "$state" == "FAILED" || "$state" == "CANCELLED" ]]; then echo "$job" | jq .; exit 1; fi
  sleep 2
done
[[ "$(jq -r '.status' <<<"$job")" == "COMPLETED" ]] || { echo "Job did not complete before timeout" >&2; exit 1; }
artifact_key=$(jq -r '.artifactKey' <<<"$job")
bucket=$(terraform -chdir="$infra" output -raw artifact_bucket)
region=$(terraform -chdir="$infra" output -raw region)
aws s3api head-object --bucket "$bucket" --key "$artifact_key" --region "$region"
echo "E2E smoke completed for $job_id. Wait at least three minutes, then verify its Kubernetes Job was TTL-cleaned."
