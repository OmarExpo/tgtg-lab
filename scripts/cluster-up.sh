#!/usr/bin/env bash
# Phase 2: kind cluster + metrics-server + locally built image.
set -euo pipefail
cd "$(dirname "$0")/.."

kind get clusters | grep -qx lab || kind create cluster --config kind/kind-config.yaml

# metrics-server feeds CPU/memory usage to 'kubectl top' and to the HPA.
# kind's kubelets use self-signed certs -> --kubelet-insecure-tls (lab only!).
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true

# Build the app image and copy it straight into the kind nodes (no registry needed yet).
docker build -t bags-api:dev app
kind load docker-image bags-api:dev --name lab

kubectl get nodes -o wide
