#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
infra="$repo_root/terraform/environments/learning"
cluster=$(terraform -chdir="$infra" output -raw cluster_name)
region=$(terraform -chdir="$infra" output -raw region)
echo "== EKS nodes =="
kubectl get nodes -o wide
echo "== Pending Pods =="
kubectl get pods -A --field-selector=status.phase=Pending -o wide
echo "== Meeting-bot Jobs and events =="
kubectl -n meeting-bot get jobs,pods
kubectl -n meeting-bot get events --sort-by=.lastTimestamp | tail -30
echo "== Karpenter controller logs =="
kubectl -n kube-system logs deployment/karpenter --all-containers --tail=100 || true
echo "== Karpenter resources =="
kubectl get nodepools,nodeclaims,ec2nodeclasses -o wide
echo "== Cluster API logs in CloudWatch =="
aws logs tail "/aws/eks/$cluster/cluster" --region "$region" --since 30m || true
echo "== Request queue counters =="
for output in request_queue_url delivery_queue_url; do
  url=$(terraform -chdir="$infra" output -raw "$output")
  aws sqs get-queue-attributes --region "$region" --queue-url "$url" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage
done
