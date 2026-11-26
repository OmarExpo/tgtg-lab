#!/usr/bin/env bash
# Generate traffic from INSIDE the cluster (same path real clients take: Service -> Ready pods).
#   scripts/load.sh start [bags|work] [parallel]   e.g. scripts/load.sh start work 4
#   scripts/load.sh stop
set -euo pipefail
action="${1:-start}"; target="${2:-bags}"; n="${3:-2}"

if [[ "$action" == "stop" ]]; then
  kubectl -n bags delete deploy loadgen --ignore-not-found
  exit 0
fi

kubectl -n bags delete deploy loadgen --ignore-not-found >/dev/null
kubectl -n bags create deployment loadgen --image=busybox:1.36 --replicas="$n" -- \
  sh -c "while true; do wget -q -O /dev/null http://bags-api/${target} || true; sleep 0.1; done"
echo "loadgen: ${n} pods hitting /${target}. Stop with: scripts/load.sh stop"
