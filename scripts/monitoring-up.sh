#!/usr/bin/env bash
# Phase 3: Prometheus Operator + Prometheus + Alertmanager + Grafana (kube-prometheus-stack).
set -euo pipefail
cd "$(dirname "$0")/.."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install mon prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f monitoring/values.yaml --wait --timeout 10m

kubectl -n monitoring get pods
cat <<'EOF'

Open the UIs (each in its own terminal, or append & ):
  kubectl -n monitoring port-forward svc/mon-grafana 3000:80                        # http://localhost:3000  admin/admin
  kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090  # http://localhost:9090
  kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-alertmanager 9093 # http://localhost:9093
EOF
