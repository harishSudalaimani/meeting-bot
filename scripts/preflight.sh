#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <hosted-zone-id> <domain> <api-hostname> <region>" >&2
  exit 2
fi
zone_id=$1
domain=${2%.}
api_host=${3%.}
region=$4

command -v aws >/dev/null || { echo "AWS CLI v2 is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
identity=$(aws sts get-caller-identity --output json)
account=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<<"$identity")
arn=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<<"$identity")
printf 'AWS identity: %s\nAccount: %s\nRegion: %s\n' "$arn" "$account" "$region"

zone=$(aws route53 get-hosted-zone --id "$zone_id" --output json)
zone_name=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["HostedZone"]["Name"].rstrip("."))' <<<"$zone")
private=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["HostedZone"]["Config"]["PrivateZone"])' <<<"$zone")
[[ "$private" == "False" ]] || { echo "Hosted zone $zone_id is private" >&2; exit 1; }
[[ "$zone_name" == "$domain" ]] || { echo "Zone name is $zone_name, expected $domain" >&2; exit 1; }
[[ "$api_host" == *".$domain" && "$api_host" != "$domain" ]] || { echo "API host must be a dedicated subdomain of $domain" >&2; exit 1; }
existing=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --query "ResourceRecordSets[?Name=='${api_host}.'].[Name,Type]" --output text)
if [[ -n "$existing" ]]; then
  printf 'The API hostname already has a DNS record:\n%s\n' "$existing" >&2
  echo "Choose an unused dedicated hostname. No records were changed." >&2
  exit 1
fi

az_text=$(aws ec2 describe-availability-zones --region "$region" --filters Name=state,Values=available --query 'AvailabilityZones[0:3].ZoneName' --output text)
read -r -a chosen_azs <<<"$az_text"
[[ "${#chosen_azs[@]}" -eq 3 ]] || { echo "The design expects three available AZs in $region" >&2; exit 1; }
for az in "${chosen_azs[@]}"; do
  for instance_type in t3a.xlarge t3a.large; do
    offerings=$(aws ec2 describe-instance-type-offerings --region "$region" --location-type availability-zone \
      --filters "Name=instance-type,Values=$instance_type" "Name=location,Values=$az" \
      --query 'length(InstanceTypeOfferings)' --output text)
    [[ "$offerings" -gt 0 ]] || { echo "$instance_type is not offered in selected AZ $az" >&2; exit 1; }
  done
done
printf 'Selected AZs support t3a.xlarge baseline and t3a.large workers: %s\n' "${chosen_azs[*]}"
version=$(aws eks describe-cluster-versions --region "$region" --query "clusterVersions[?clusterVersion=='1.36' && status=='STANDARD_SUPPORT'] | length(@)" --output text)
[[ "$version" -gt 0 ]] || { echo "EKS 1.36 is not currently under standard support in $region; update the pinned version after checking all add-ons" >&2; exit 1; }

quota=$(aws service-quotas get-service-quota --region "$region" --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null || true)
if [[ -n "$quota" && "$quota" != "None" ]]; then
  printf 'Standard On-Demand vCPU quota: %s (demo maximum request is approximately 12 vCPU)\n' "$quota"
  awk -v q="$quota" 'BEGIN { exit !(q >= 12) }' || { echo "Request an EC2 quota increase or lower the Terraform Karpenter CPU cap before deployment." >&2; exit 1; }
else
  echo "Could not read the EC2 vCPU quota. Verify Service Quotas manually before deployment."
fi
echo "Preflight passed. This only performed read requests and created no AWS resources."
