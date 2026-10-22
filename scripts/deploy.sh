#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
infra="$repo_root/terraform/environments/learning"
addons="$repo_root/terraform/environments/cluster-addons"
apply=false
if [[ "${1:-}" == "--apply" ]]; then apply=true; fi

terraform fmt -check -recursive "$repo_root/terraform"
tfvars="$infra/terraform.tfvars"
[[ -f "$tfvars" ]] || { echo "Create $tfvars from terraform.tfvars.example first." >&2; exit 1; }
read_tfvar() {
  local key=$1
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*(#.*)?$/\\1/p" "$tfvars" | head -n 1
}
zone_id=$(read_tfvar hosted_zone_id)
domain=$(read_tfvar domain_name)
region=$(read_tfvar region)
subdomain=$(read_tfvar api_subdomain)
region=${region:-ap-south-1}
subdomain=${subdomain:-api}
[[ -n "$zone_id" && -n "$domain" ]] || { echo "terraform.tfvars must set hosted_zone_id and domain_name." >&2; exit 1; }
"$repo_root/scripts/preflight.sh" "$zone_id" "$domain" "${subdomain}.${domain}" "$region"
terraform -chdir="$infra" init
terraform -chdir="$infra" validate
terraform -chdir="$infra" plan -out=tfplan
if [[ "$apply" != true ]]; then
  echo "Plan saved. Review it, then run scripts/deploy.sh --apply to enter the explicit confirmation flow."
  exit 0
fi

cluster="meeting-bot-learning"
if [[ -f "$infra/terraform.tfvars" ]]; then cluster=$(awk -F ' *= *' '/^cluster_name[[:space:]]*=/ {gsub(/"/,"",$2); print $2}' "$infra/terraform.tfvars" || true); fi
[[ -n "$cluster" ]] || cluster="meeting-bot-learning"
echo "Type APPLY $cluster to create the infrastructure shown in the plan:"
read -r confirmation
[[ "$confirmation" == "APPLY $cluster" ]] || { echo "No changes applied."; exit 1; }
terraform -chdir="$infra" apply tfplan

region=$(terraform -chdir="$infra" output -raw region)
cluster=$(terraform -chdir="$infra" output -raw cluster_name)
aws eks update-kubeconfig --region "$region" --name "$cluster"
terraform -chdir="$addons" init
terraform -chdir="$addons" validate
terraform -chdir="$addons" plan -out=tfplan
echo "Review the add-on plan. Type APPLY ADDONS $cluster to install the platform components:"
read -r addon_confirmation
[[ "$addon_confirmation" == "APPLY ADDONS $cluster" ]] || { echo "Infrastructure exists; add-ons were not applied."; exit 1; }
"$repo_root/scripts/install-gateway-api-crds.sh"
terraform -chdir="$addons" apply tfplan
echo "Platform provisioned. Application deployment is a separate reviewed GitOps step."
