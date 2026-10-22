#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
infra="$repo_root/terraform/environments/learning"
tag=${1:-}
if [[ -z "$tag" ]]; then echo "usage: $0 <immutable-image-tag>" >&2; exit 2; fi
account=$(aws sts get-caller-identity --query Account --output text)
region=$(terraform -chdir="$infra" output -raw region)
repos=$(terraform -chdir="$infra" output -json ecr_repositories)
registry="${account}.dkr.ecr.${region}.amazonaws.com"
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
for service in api controller meeting-bot delivery-worker; do
  repository=$(jq -r --arg service "$service" '.value[$service]' <<<"$repos")
  docker build --file "$repo_root/services/Dockerfile" --build-arg "SERVICE=$service" --tag "$repository:$tag" "$repo_root/services"
  docker push "$repository:$tag"
done
"$repo_root/scripts/configure-gitops.sh" "$tag"
echo "Images are in ECR. Commit the generated image references to the protected GitOps branch to trigger Argo CD."
