#!/usr/bin/env bash
# Replace CHANGE_ME with your GitHub user/org in the ArgoCD app and the alert runbook links.
set -euo pipefail
cd "$(dirname "$0")/.."
user="${1:?usage: scripts/set-repo.sh <github-user>}"
grep -rl CHANGE_ME argocd deploy README.md RUNBOOK.md | xargs sed -i "s/CHANGE_ME/${user}/g"
grep -rn "github.com/${user}" argocd deploy | head
echo "Now: git add -A && git commit -m 'point to my repo' && git push"
