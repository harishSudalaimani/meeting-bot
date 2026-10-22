#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
infra="$repo_root/terraform/environments/learning"
addons="$repo_root/terraform/environments/cluster-addons"
cluster=$(terraform -chdir="$infra" output -raw cluster_name)
region=$(terraform -chdir="$infra" output -raw region)
account=$(aws sts get-caller-identity --query Account --output text)

echo "AWS account: $account; region: $region; project cluster: $cluster"
echo "Tagged EC2 instances:"
aws ec2 describe-instances --region "$region" --filters Name=tag:Project,Values=meeting-bot-platform Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output table
echo "Tagged NAT gateways:"
aws ec2 describe-nat-gateways --region "$region" --filter Name=tag:Project,Values=meeting-bot-platform --query 'NatGateways[].[NatGatewayId,State]' --output table
echo "Tagged AWS resources:"
aws resourcegroupstaggingapi get-resources --region "$region" --tag-filters Key=Project,Values=meeting-bot-platform --query 'ResourceTagMappingList[].ResourceARN' --output table
echo ""
active_jobs=$(kubectl -n meeting-bot get jobs -o json | jq '[.items[] | select((.status.active // 0) > 0)] | length')
nodeclaims=$(kubectl get nodeclaims.karpenter.sh -o json | jq '.items | length')
[[ "$active_jobs" == 0 ]] || { echo "$active_jobs active meeting Jobs remain; wait or cancel them first." >&2; exit 1; }
[[ "$nodeclaims" == 0 ]] || { echo "$nodeclaims Karpenter NodeClaims remain; wait until they are terminated." >&2; exit 1; }
if kubectl -n argocd get application meeting-bot-platform >/dev/null 2>&1; then
  echo "Delete only this Argo CD application, then rerun teardown after the Gateway and DNS record are gone:"
  echo "  kubectl -n argocd delete application meeting-bot-platform"
  exit 1
fi
if kubectl -n meeting-bot get gateway bot-api >/dev/null 2>&1; then
  echo "The Gateway still exists. Wait for its finalizer to delete the ALB, then rerun teardown." >&2
  exit 1
fi
project_albs=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters Key=Project,Values=meeting-bot-platform \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
[[ -z "$project_albs" || "$project_albs" == "None" ]] || {
  echo "Project ALB(s) still exist; wait for their deletion before removing EKS:" >&2
  printf '%s\n' "$project_albs" >&2
  exit 1
}
host=$(terraform -chdir="$infra" output -raw api_hostname)
zone=$(terraform -chdir="$infra" output -raw hosted_zone_id)
host_records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json | jq --arg name "${host}." '[.ResourceRecordSets[] | select(.Name == $name)] | length')
[[ "$host_records" == 0 ]] || { echo "Route 53 still contains records at $host. Wait for ExternalDNS to remove its owned records." >&2; exit 1; }
echo "No active meeting jobs, Karpenter nodes, Gateway/ALB, or records for $host remain."
read -r -p "Type DELETE $cluster to destroy only the two Terraform stacks: " confirmation
[[ "$confirmation" == "DELETE $cluster" ]] || { echo "No resources destroyed."; exit 1; }

terraform -chdir="$addons" destroy
terraform -chdir="$infra" destroy

echo "Post-destroy project-resource checks:"
aws ec2 describe-instances --region "$region" --filters Name=tag:Project,Values=meeting-bot-platform Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
aws ec2 describe-nat-gateways --region "$region" --filter Name=tag:Project,Values=meeting-bot-platform --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output table
aws ec2 describe-volumes --region "$region" --filters Name=tag:Project,Values=meeting-bot-platform Name=status,Values=available,in-use --query 'Volumes[].[VolumeId,State,Size]' --output table
aws ec2 describe-addresses --region "$region" --filters Name=tag:Project,Values=meeting-bot-platform --query 'Addresses[].[AllocationId,PublicIp,AssociationId]' --output table
aws resourcegroupstaggingapi get-resources --region "$region" --tag-filters Key=Project,Values=meeting-bot-platform --query 'ResourceTagMappingList[].ResourceARN' --output table
echo "Verify no project-owned ALB/ECR/log group/S3/DynamoDB/EKS resources and no api-host or _external-dns records remain. The existing hosted zone is intentionally preserved. Keep Terraform state until cleanup is confirmed."
