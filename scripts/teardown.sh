#!/usr/bin/env bash
# Delete the whole lab cluster (everything lives in Git, so you can rebuild it in ~10 minutes).
set -euo pipefail
kind delete cluster --name lab
