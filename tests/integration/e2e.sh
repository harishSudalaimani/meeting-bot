#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
infra="$repo_root/terraform/environments/learning"
host=${API_HOST:-$(terraform -chdir="$infra" output -raw api_hostname)}
token_file=${API_TOKEN_FILE:-"$repo_root/.local/api-token"}
duration=${DURATION_SECONDS:-60}
wait_for_ttl=${WAIT_FOR_TTL_CLEANUP:-0}

for tool in aws curl dig jq kubectl terraform; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done
[[ -r "$token_file" ]] || { echo "API token file missing: $token_file" >&2; exit 2; }
token=$(<"$token_file")
region=$(terraform -chdir="$infra" output -raw region)
zone=$(terraform -chdir="$infra" output -raw hosted_zone_id)
table=$(terraform -chdir="$infra" output -raw jobs_table_name)
bucket=$(terraform -chdir="$infra" output -raw artifact_bucket)

echo "Checking dedicated Route 53 record and DNS for $host"
records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json)
jq -e --arg name "${host}." '[.ResourceRecordSets[] | select(.Name == $name and .Type == "A" and .AliasTarget.DNSName != null)] | length == 1' <<<"$records" >/dev/null
dig +short "$host" | grep -q .

echo "Checking valid HTTPS certificate and API health"
curl --fail --silent --show-error --output /dev/null "https://$host/healthz"

echo "Checking ALB, WAF association, and healthy pod-IP targets"
alb_dns=$(kubectl -n meeting-bot get gateway bot-api -o jsonpath='{.status.addresses[0].value}')
[[ -n "$alb_dns" ]] || { echo "Gateway has no ALB hostname" >&2; exit 1; }
lbs=$(aws elbv2 describe-load-balancers --region "$region" --output json)
alb_arn=$(jq -r --arg dns "$alb_dns" '.LoadBalancers[] | select(.DNSName == $dns) | .LoadBalancerArn' <<<"$lbs")
[[ -n "$alb_arn" && "$alb_arn" != "null" ]] || { echo "ALB $alb_dns was not found" >&2; exit 1; }
aws wafv2 get-web-acl-for-resource --region "$region" --resource-arn "$alb_arn" >/dev/null
target_groups=$(aws elbv2 describe-target-groups --region "$region" --load-balancer-arn "$alb_arn" --output json)
target_arn=$(jq -r '.TargetGroups[0].TargetGroupArn // empty' <<<"$target_groups")
[[ -n "$target_arn" ]] || { echo "ALB has no target group" >&2; exit 1; }
health=$(aws elbv2 describe-target-health --region "$region" --target-group-arn "$target_arn" --output json)
jq -e '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length > 0' <<<"$health" >/dev/null

echo "Checking API validation, idempotency, and DynamoDB persistence"
bad_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST "https://$host/bots" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' --data '{"meetingUrl":"https://invalid.example/room","durationSeconds":30}')
[[ "$bad_status" == 400 ]] || { echo "Invalid request returned HTTP $bad_status, expected 400" >&2; exit 1; }

idempotency_key="e2e-$(date +%s)-$RANDOM"
payload=$(jq -cn --arg url "https://meet.google.com/demo-e2e" --argjson duration "$duration" '{meetingUrl:$url,durationSeconds:$duration}')
first=$(curl --fail-with-body --silent --show-error --request POST "https://$host/bots" \
  --header "Authorization: Bearer $token" --header "Idempotency-Key: $idempotency_key" \
  --header 'Content-Type: application/json' --data "$payload")
job_id=$(jq -r '.jobId' <<<"$first")
[[ -n "$job_id" && "$job_id" != "null" ]] || { echo "Create response has no jobId: $first" >&2; exit 1; }
second=$(curl --fail-with-body --silent --show-error --request POST "https://$host/bots" \
  --header "Authorization: Bearer $token" --header "Idempotency-Key: $idempotency_key" \
  --header 'Content-Type: application/json' --data "$payload")
[[ "$(jq -r '.jobId' <<<"$second")" == "$job_id" ]] || { echo "Idempotent retry produced a different job ID" >&2; exit 1; }
conflict_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST "https://$host/bots" \
  --header "Authorization: Bearer $token" --header "Idempotency-Key: $idempotency_key" \
  --header 'Content-Type: application/json' --data "$(jq -cn --arg url "https://meet.google.com/demo-e2e" --argjson duration "$((duration + 1))" '{meetingUrl:$url,durationSeconds:$duration}')")
[[ "$conflict_status" == 409 ]] || { echo "Reused key with a different body returned HTTP $conflict_status, expected 409" >&2; exit 1; }

ddb_item=$(aws dynamodb get-item --region "$region" --table-name "$table" \
  --key "{\"PK\":{\"S\":\"JOB#$job_id\"},\"SK\":{\"S\":\"META\"}}" --consistent-read --output json)
jq -e '.Item.PK.S != null and .Item.jobId.S != null' <<<"$ddb_item" >/dev/null
aws sqs get-queue-attributes --region "$region" --queue-url "$(terraform -chdir="$infra" output -raw request_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible >/dev/null

echo "Checking controller Job, bot completion, and S3 artifact for $job_id"
seen_job=false
for _ in $(seq 1 90); do
  if kubectl -n meeting-bot get job "meeting-$job_id" >/dev/null 2>&1; then seen_job=true; break; fi
  sleep 2
done
[[ "$seen_job" == true ]] || { echo "Controller did not create the Kubernetes Job" >&2; exit 1; }

for _ in $(seq 1 150); do
  current=$(curl --fail-with-body --silent --show-error "https://$host/bots/$job_id" --header "Authorization: Bearer $token")
  state=$(jq -r '.status' <<<"$current")
  echo "job $job_id: $state"
  [[ "$state" == COMPLETED ]] && break
  [[ "$state" == FAILED || "$state" == CANCELLED ]] && { jq . <<<"$current"; exit 1; }
  sleep 2
done
[[ "$(jq -r '.status' <<<"$current")" == COMPLETED ]] || { echo "Job did not complete" >&2; exit 1; }
artifact_key=$(jq -r '.artifactKey' <<<"$current")
aws s3api head-object --region "$region" --bucket "$bucket" --key "$artifact_key" >/dev/null
download=$(curl --fail --location --silent --show-error "https://$host/bots/$job_id/artifact" --header "Authorization: Bearer $token")
grep -Fq "$job_id" <<<"$download" || { echo "Downloaded artifact did not contain the completed job ID" >&2; exit 1; }

echo "Checking cancellation of a second session"
cancel_key="cancel-$(date +%s)-$RANDOM"
cancel_payload='{"meetingUrl":"https://meet.google.com/demo-cancel","durationSeconds":600}'
cancel_job=$(curl --fail-with-body --silent --show-error --request POST "https://$host/bots" \
  --header "Authorization: Bearer $token" --header "Idempotency-Key: $cancel_key" \
  --header 'Content-Type: application/json' --data "$cancel_payload" | jq -r '.jobId')
curl --fail-with-body --silent --show-error --request POST "https://$host/bots/$cancel_job/cancel" \
  --header "Authorization: Bearer $token" >/dev/null
for _ in $(seq 1 90); do
  cancelled=$(curl --fail-with-body --silent --show-error "https://$host/bots/$cancel_job" --header "Authorization: Bearer $token")
  cancel_state=$(jq -r '.status' <<<"$cancelled")
  [[ "$cancel_state" == CANCELLED ]] && break
  sleep 2
done
[[ "$(jq -r '.status' <<<"$cancelled")" == CANCELLED ]] || { echo "Cancellation did not reach CANCELLED state: $cancelled" >&2; exit 1; }

if [[ "$wait_for_ttl" == 1 ]]; then
  echo "Waiting for Kubernetes Job TTL cleanup (up to four minutes)"
  for _ in $(seq 1 120); do
    if ! kubectl -n meeting-bot get job "meeting-$job_id" >/dev/null 2>&1; then break; fi
    sleep 2
  done
  if kubectl -n meeting-bot get job "meeting-$job_id" >/dev/null 2>&1; then echo "Completed Job has not been TTL-cleaned yet" >&2; exit 1; fi
fi

echo "Integration workflow passed for job $job_id."
