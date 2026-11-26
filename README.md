# tgtg-lab — GitOps platform lab (Kubernetes · ArgoCD · GitHub Actions · Prometheus/Grafana)

A small "surplus food bags" API run the way a modern platform team runs services:
**CI builds an image, Git holds the desired state, ArgoCD reconciles the cluster, Prometheus watches it.**
Day 1 runs on a local kind cluster; Day 2 moves it to AWS EKS provisioned with OpenTofu.

```
 developer ── git push app/ ──► GitHub Actions: test → build → push image (GHCR)
                                        │
                                        └─ commits new image tag to deploy/overlays/dev
                                                          │
                       ArgoCD (in cluster) ◄── watches ───┘  Git = source of truth
                              │ sync
                              ▼
     Kubernetes: Deployment ─► ReplicaSet ─► Pods ◄── Service ◄── loadgen
                    ▲ HPA scales                │ /metrics
                                                ▼
                     Prometheus ─► alert rules ─► Alertmanager
                          └────► Grafana dashboard (shipped via Git too)
```

## Layout

| Path | What |
|---|---|
| `app/` | Python (Flask + gunicorn) service with Prometheus metrics and failure injection |
| `deploy/base/` | Deployment, Service, HPA, PDB, ServiceMonitor, PrometheusRule, Grafana dashboard |
| `deploy/overlays/dev/` | Environment overlay — CI bumps the image tag here |
| `argocd/` | ArgoCD `Application` |
| `monitoring/values.yaml` | kube-prometheus-stack Helm values |
| `.github/workflows/ci.yml` | Test → build → push → GitOps bump |
| `scripts/` | Tool install, cluster up, monitoring, ArgoCD, load generator, teardown |
| `RUNBOOK.md` | What to do when each alert fires |
| `docs/DAY1.md` | Step-by-step guide with explanations |

## Run it (WSL + Docker Desktop)

```bash
scripts/setup-tools.sh               # kind, kubectl, helm, kustomize, argocd
scripts/cluster-up.sh                # kind cluster + metrics-server + local image
scripts/monitoring-up.sh             # Prometheus, Grafana, Alertmanager
scripts/set-repo.sh <github-user>    # then commit + push
scripts/argocd-up.sh                 # ArgoCD + the bags-api Application
scripts/load.sh start                # traffic
scripts/teardown.sh                  # delete everything
```

## Incidents & drills

| # | Drill | Symptom | Root cause | Fix | Prevention |
|---|---|---|---|---|---|
| 1 | Bad deploy | | | | |
| 2 | Manual drift | | | | |
| 3 | OOMKilled | | | | |
| 4 | CrashLoopBackOff | | | | |
| 5 | Not ready | | | | |
| 6 | ImagePullBackOff | | | | |
| 7 | Slow, not broken | | | | |
| 8 | Autoscaling | | | | |
| 9 | Node drain | | | | |

## Trade-offs & what I'd change for production

- Multiple environments/regions: one overlay per env/region, ArgoCD **ApplicationSet** to generate apps per cluster; promotion by PR.
- Secrets via External Secrets Operator + AWS Secrets Manager (nothing secret in Git).
- Progressive delivery (Argo Rollouts canary with Prometheus analysis) instead of plain rolling updates.
- SLO burn-rate alerts instead of fixed thresholds; long-term metrics in Mimir; logs to Graylog/OpenSearch.
- Image signing + vulnerability scanning in CI, pinned action SHAs.
