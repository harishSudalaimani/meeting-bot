#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then echo "usage: $0 <https://github.com/owner/repository.git>" >&2; exit 2; fi
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export GIT_REPOSITORY_URL=$1
envsubst < "$repo_root/gitops/applications/meeting-bot-platform.yaml.tpl" | kubectl apply -f -
echo "Argo CD follows the main branch. Check with: kubectl -n argocd get applications"
