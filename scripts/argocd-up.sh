#!/usr/bin/env bash
# Phase 4: install ArgoCD and register the bags-api Application.
set -euo pipefail
cd "$(dirname "$0")/.."

grep -q CHANGE_ME argocd/bags-api.yaml && {
  echo "Run scripts/set-repo.sh <your-github-user> first (and push), so ArgoCD knows your repo URL."; exit 1; }

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m

kubectl apply -f argocd/bags-api.yaml

echo
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
cat <<'EOF'

UI:   kubectl -n argocd port-forward svc/argocd-server 8080:443   ->  https://localhost:8080  (user: admin)
CLI:  argocd login localhost:8080 --username admin --insecure
      argocd app get bags-api
EOF
