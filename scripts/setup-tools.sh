#!/usr/bin/env bash
# Installs kind, kubectl, helm, kustomize and the argocd CLI into /usr/local/bin (WSL Ubuntu, amd64).
# Safe to re-run: skips anything already installed.
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"

need docker || { echo "Docker not found. Enable WSL integration in Docker Desktop (Settings > Resources > WSL integration)."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable. Start Docker Desktop."; exit 1; }

if ! need kubectl; then
  echo ">> kubectl"
  v=$(curl -sSfL https://dl.k8s.io/release/stable.txt)
  curl -sSfLO "https://dl.k8s.io/release/${v}/bin/linux/amd64/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl
fi

if ! need kind; then
  echo ">> kind"
  curl -sSfLo kind https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64
  sudo install -m 0755 kind /usr/local/bin/kind
fi

if ! need helm; then
  echo ">> helm"
  curl -sSfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! need kustomize; then
  echo ">> kustomize"
  curl -sSfL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  sudo install -m 0755 kustomize /usr/local/bin/kustomize
fi

if ! need argocd; then
  echo ">> argocd CLI"
  curl -sSfLo argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo install -m 0755 argocd /usr/local/bin/argocd
fi

echo
for c in docker kubectl kind helm kustomize argocd; do printf "%-10s " "$c"; command -v "$c"; done
kubectl version --client | head -1
