# Day 1 — GitOps platform on a local Kubernetes cluster

**Goal by tonight:** a service running on Kubernetes, deployed **only** through Git by ArgoCD, built by GitHub Actions, watched by Prometheus/Grafana with alerts, and 9 incidents you caused, diagnosed and fixed yourself. That gives you real answers for the Kubernetes, GitOps and monitoring questions in the Too Good To Go interview.

How to read this: every phase has **🧠 Concepts** (the gap: read these properly), **▶ Do** (commands) and **✅ Checkpoint** (what you should see). **🎤 Interview line** = how to say it out loud.

---

## 0. The design (read first, 20 min)

### 0.1 What we're building

```
                ┌──────────── BUILD LOOP (CI) ─────────────┐
 you ─ git push │ GitHub Actions: test → docker build →     │
   app/ change  │ push ghcr.io/…/bags-api:<sha> →           │
                │ commit "image tag = <sha>" to deploy/     │
                └───────────────────────┬───────────────────┘
                                        ▼
                ┌──────────── DEPLOY LOOP (CD / GitOps) ───┐
                │ ArgoCD (inside the cluster) polls Git,    │
                │ renders kustomize, diffs vs cluster,      │
                │ applies the difference, keeps it in sync  │
                └───────────────────────┬───────────────────┘
                                        ▼
                ┌──────────── RUN LOOP (Kubernetes) ───────┐
                │ Deployment → ReplicaSet → Pods            │
                │ Service routes to Ready pods; HPA scales  │
                │ kubelet restarts unhealthy containers     │
                └───────────────────────┬───────────────────┘
                                        ▼  /metrics every 15 s
                ┌──────────── OBSERVE LOOP ────────────────┐
                │ Prometheus scrapes → rules → alerts →     │
                │ Alertmanager; Grafana dashboard           │
                └──────────────────────────────────────────┘
```

Four loops, and **every one of them is a control loop**: *desired state → observe actual state → diff → act*. Kubernetes controllers, ArgoCD, the HPA and OpenTofu's `plan/apply` all work like this. If you say that clearly in the interview, it shows you understand how the whole platform fits together.

### 0.2 How it maps to Too Good To Go's stack

| Their stack | Today (local) | Day 2 (AWS) |
|---|---|---|
| EKS | kind (Kubernetes in Docker) | EKS via OpenTofu |
| GitHub Actions / Jenkins | GitHub Actions | GitHub Actions + OIDC to AWS |
| ArgoCD | ArgoCD | ArgoCD |
| Prometheus + Mimir + Grafana | Prometheus + Grafana | same; Mimir = scaled long-term store (concept) |
| Graylog | `kubectl logs` | concept only |
| Aurora / DynamoDB | not used today | discussion |

### 0.3 Key design decisions (and the trade-off for each)

1. **Pull-based GitOps.** CI never runs `kubectl`. *Why:* no cluster credentials in CI, Git history = audit log, rollback = `git revert`, drift gets corrected automatically. *Trade-off:* deploy waits for ArgoCD to notice (poll ~3 min or a webhook); two repos/folders to reason about.
2. **Image tag = commit SHA, never `latest`.** Immutable, traceable from pod → image → commit. `latest` makes rollbacks and "what's running?" impossible to answer.
3. **Kustomize base + overlays.** Same manifests, small per-env differences. *Alternative:* Helm (templating, packaging, good for 3rd-party apps — we use it for Prometheus). Many teams use both.
4. **HPA owns replicas** → `replicas:` is not in Git (otherwise ArgoCD and the HPA fight).
5. **Monitoring config lives with the app** (ServiceMonitor, alert rules, dashboard in `deploy/base`). The team that owns the service owns its alerts.

### 0.4 Plan & timebox

| Phase | What | Time |
|---|---|---|
| 1 | Tools + GitHub repo | 45 min |
| 2 | App in a container | 30 min |
| 3 | Cluster + Kubernetes by hand (**main gap**) | 2 h |
| 4 | Monitoring | 1 h |
| 5 | GitOps with ArgoCD | 1 h |
| 6 | CI with GitHub Actions | 1 h |
| 7 | Incident drills | 2 h |
| 8 | Write-up + teardown | 30 min |

If you run out of time: phases 1–5 + drills 1, 2, 3, 5 are the minimum worth putting on the CV.

---

## Phase 1 — Tools and repo (45 min)

▶ **Do**

1. Raise WSL memory to 10 GB with your switcher, restart WSL, start Docker Desktop (WSL integration on).
2. Unzip the repo into your WSL home (not `/mnt/c/...` — it's slow and breaks file permissions):
   ```bash
   cd ~ && unzip /mnt/c/Users/<you>/Downloads/tgtg-lab.zip && cd tgtg-lab
   chmod +x scripts/*.sh
   scripts/setup-tools.sh
   ```
3. Create a **public** GitHub repo called `tgtg-lab` (public so ArgoCD can read it without credentials), then:
   ```bash
   git init -b main && git add -A && git commit -m "Day 1 skeleton"
   git remote add origin git@github.com:<you>/tgtg-lab.git   # your github.com SSH key from ~/.ssh/config
   git push -u origin main
   ```
4. `scripts/set-repo.sh <you>` → commit → push.

✅ **Checkpoint:** `setup-tools.sh` prints a path for all six tools; the repo is on GitHub. The first CI run will start on push. **Let it fail or succeed for now** — we'll look at it in Phase 6. (If it succeeds it bumps the overlay to a GHCR image, which is fine: just `git pull` before you edit anything.)

---

## Phase 2 — The app in a container (30 min)

Mostly familiar ground. Only two points are new.

🧠 **Concepts**

- **Instrumentation.** The app exposes `/metrics` in Prometheus text format. Two metric types:
  - `Counter` (`http_requests_total{path,status}`) only goes up. You never graph the raw value; you graph its **rate**.
  - `Histogram` (`http_request_duration_seconds_bucket{le=...}`) counts requests per latency bucket, which is how you get p95/p99.
  - Labels must be **low cardinality** (path, status). A label with user IDs would create millions of time series and take Prometheus or Mimir down. This comes up in interviews.
- **One worker, four threads** in gunicorn: metrics live in process memory, and multiple worker processes would give inconsistent scrapes. Being able to explain a gotcha like this is a good sign of real experience.
- **Liveness vs readiness endpoints** are separate on purpose (`/healthz` vs `/readyz`). See Phase 3.

▶ **Do**

```bash
docker build -t bags-api:dev app
docker run --rm -p 8080:8080 -e ERROR_RATE=0.2 bags-api:dev
# another terminal:
for i in $(seq 20); do curl -s -o /dev/null -w "%{http_code} " localhost:8080/bags; done; echo
curl -s localhost:8080/metrics | grep http_requests_total
```

✅ **Checkpoint:** you see a mix of `200` and `500`, and counters per status in `/metrics`. Stop the container.

---

## Phase 3 — Kubernetes, properly (2 h) — **the main gap**

### 🧠 3.1 What Kubernetes actually is

Kubernetes is a **database of desired state** (etcd) behind an **API** (kube-apiserver), with lots of small **controllers** that each watch one kind of object and keep reality matching it. You never tell Kubernetes "start a container on server 3". You declare "I want 2 copies of this pod template", and the controllers keep making it true, even after crashes, node failures or someone deleting a pod.

```
                    CONTROL PLANE  (on EKS: run and paid for by AWS — you never see these machines)
 kubectl / ArgoCD ─► kube-apiserver ◄──► etcd (all objects: desired + observed state)
                      ▲   ▲   ▲
        ┌─────────────┘   │   └───────────────┐
   scheduler        controller-manager    cloud-controller-manager
   "which node      Deployment, ReplicaSet,  "create an AWS load balancer
    for this pod?"  Node, Job, EndpointSlice  for this Service"
                    ... controllers
 ───────────────────────────────────────────────────────────────────────────
                    WORKER NODES  (on EKS: EC2 in managed node groups / Karpenter, or Fargate)
   kubelet ── talks to the API, starts containers via containerd, runs probes, reports status
   kube-proxy ── programs iptables/IPVS so Service IPs reach pod IPs
   CNI plugin ── gives each pod an IP (on EKS: the VPC CNI, so pods get real VPC IPs)
   CoreDNS ── bags-api.bags.svc.cluster.local → Service IP
```

**🎤 Interview line:** *"Everything in Kubernetes is a reconcile loop. The API server stores desired state in etcd, controllers compare it with actual state and act on the difference. On EKS, AWS runs the control plane and we run the nodes."*

### 🧠 3.2 What happens when you apply a Deployment (classic interview question)

1. `kubectl apply` sends YAML to **kube-apiserver**: authentication → authorization (RBAC) → admission controllers (validate and mutate, e.g. inject defaults or policies) → stored in **etcd**.
2. The **Deployment controller** sees a new Deployment and creates a **ReplicaSet** for this pod template (each template version gets its own ReplicaSet, and that's what makes rollbacks possible).
3. The **ReplicaSet controller** sees "want 2, have 0" and creates 2 **Pod** objects. They are `Pending` with no node yet.
4. The **scheduler** picks a node for each pod: enough *requested* CPU/memory free, node selectors/affinity, taints/tolerations, spread across zones. It writes `nodeName` on the pod.
5. The **kubelet** on that node sees a pod assigned to it, then pulls the image (`ContainerCreating`), sets up networking via CNI, mounts volumes and starts the container (`Running`).
6. The kubelet runs the **startup → readiness / liveness probes**. When readiness passes, the pod is `Ready`.
7. The **EndpointSlice controller** adds the Ready pod's IP behind the **Service**; **kube-proxy** on every node updates the routing rules. Traffic flows.

If the service is broken, the step where this chain stops tells you which component to look at. That's the basis of the troubleshooting drills in Phase 7.

### 🧠 3.3 The objects we use (open each file in `deploy/base/` while reading)

| Object | Purpose | What to notice in our file |
|---|---|---|
| **Pod** | Smallest unit: 1+ containers sharing network and volumes. Disposable. | Never created by hand; it comes from the template inside the Deployment |
| **Deployment** | Desired pod template + rollout strategy | `maxUnavailable: 0, maxSurge: 1` → zero-downtime rolling update |
| **ReplicaSet** | Keeps N pods of one template version | Created automatically; old ones kept for rollback (`revisionHistoryLimit`) |
| **Service** | Stable IP + DNS name; load-balances to **Ready** pods matching its selector | `ClusterIP` (internal). On EKS, `LoadBalancer` → NLB, Ingress → ALB via AWS Load Balancer Controller |
| **HPA** | Changes replica count from metrics | Target 70 % of **requested** CPU, 2–6 replicas |
| **PDB** | Limits voluntary disruption (drains, upgrades) | `minAvailable: 1` |
| **Namespace** | Isolation scope for names, RBAC, quotas | `bags` |
| **ConfigMap** | Non-secret config / files | Our Grafana dashboard |
| ServiceMonitor, PrometheusRule | **CRDs**, i.e. custom object types added by an operator | Phase 4 |

**Labels and selectors connect everything:** the Deployment finds its pods with `app: bags-api`, the Service routes to pods with `app: bags-api`, the PDB protects pods with `app: bags-api`, and the ServiceMonitor finds the Service with `app: bags-api`. Get one label wrong and the chain breaks *without an error*. In an outage, check labels and selectors early.

### 🧠 3.4 Probes (often asked, often misused)

| Probe | Question it answers | If it fails |
|---|---|---|
| **startup** | "Have I finished booting?" | Liveness/readiness are paused until it passes. Essential for slow starters like **JVM / Spring Boot** apps |
| **readiness** | "Can I take traffic *right now*?" | Pod removed from Service endpoints. **Not restarted** |
| **liveness** | "Am I stuck beyond repair?" | Container **restarted** |

The classic outage: a liveness probe that checks the database. The DB has a 30-second blip, every pod fails liveness, Kubernetes restarts every pod at once, and a small problem becomes a full outage. Keep liveness simple ("is the process alive?"). Put dependency checks, if anywhere, in readiness, and even there be careful.

### 🧠 3.5 Resources: requests vs limits

- **requests** = what the scheduler *reserves* on a node. It drives bin-packing, node count (cost!) and the HPA percentage.
- **limits** = the hard cap. Memory over the limit means **OOMKilled** (exit code 137). CPU over the limit means **throttling** (the app slows down but doesn't die), which is why many teams set no CPU limit, as we do.
- QoS classes: requests = limits → *Guaranteed* (evicted last). Requests < limits → *Burstable*. Nothing set → *BestEffort* (evicted first).
- For JVM apps: set `-XX:MaxRAMPercentage=75` so the heap fits inside the memory limit with room for non-heap memory. (Covered in the Java refresher.)

### 🧠 3.6 Rolling update with `maxUnavailable: 0`

New ReplicaSet +1 pod → wait until it's **Ready** → old ReplicaSet −1 → repeat. If new pods never become Ready (bad config, crash, failing probe), the rollout **stalls and the old pods keep serving**. Users notice nothing. After `progressDeadlineSeconds` (10 min) the Deployment is marked `Progressing=False`. You'll see this in the drills, and it's the best argument for readiness probes.

### 🧠 3.7 Kustomize in one minute

`deploy/base` = plain YAML, no templating. `deploy/overlays/dev/kustomization.yaml` says: use the base, put everything in namespace `bags`, and replace image `bags-api` with `name:tag`. `kubectl apply -k` and ArgoCD both run kustomize. **Helm** is the other tool: templates plus versioned charts. It's great for installing third-party software (we use it for Prometheus). Kustomize is simpler for your own apps.

### ▶ 3.8 Do it — build the cluster (start monitoring install in parallel)

```bash
scripts/cluster-up.sh            # ~3 min: kind cluster (1 control-plane + 2 workers), metrics-server, image loaded
kubectl get nodes -o wide
kubectl get pods -A              # the system pods: CoreDNS, kindnet (CNI), kube-proxy, etcd, apiserver...
scripts/monitoring-up.sh         # ~5 min (needed before step 3.9: our base includes ServiceMonitor/PrometheusRule CRDs)
```

While that installs, re-read 3.2.

### ▶ 3.9 Deploy by hand once (to understand what ArgoCD will automate)

```bash
kustomize build deploy/overlays/dev | less        # exactly what will be sent to the API
kubectl create namespace bags
kubectl apply -k deploy/overlays/dev

kubectl -n bags get deploy,rs,pods,svc,hpa,pdb -o wide
kubectl -n bags rollout status deploy/bags-api
kubectl -n bags describe pod -l app=bags-api | sed -n '/Events/,$p'   # read the events: Scheduled → Pulled → Created → Started
kubectl -n bags get endpointslices -l kubernetes.io/service-name=bags-api -o wide
```

Look around (each command answers one interview question):

```bash
kubectl -n bags get pods -o wide                                   # which node is each pod on? (scheduler spread)
kubectl -n bags get pod -l app=bags-api -o jsonpath='{.items[0].status.qosClass}'; echo  # Burstable
kubectl explain deployment.spec.strategy.rollingUpdate             # built-in docs
kubectl -n bags run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'nslookup bags-api; wget -qO- http://bags-api/bags'          # DNS + Service from inside the cluster
kubectl -n bags port-forward svc/bags-api 8081:80 &                 # from your laptop
curl -s localhost:8081/bags; kill %1
kubectl top nodes; kubectl -n bags top pods                         # metrics-server
kubectl get events -n bags --sort-by=.lastTimestamp | tail
```

Self-healing — delete a pod and watch it come back:

```bash
kubectl -n bags get pods -w &      # watch in background
kubectl -n bags delete pod -l app=bags-api --wait=false
sleep 15; kill %1
```

Rolling update and rollback by hand:

```bash
kubectl -n bags set env deploy/bags-api APP_VERSION=v2
kubectl -n bags rollout status deploy/bags-api
kubectl -n bags rollout history deploy/bags-api
kubectl -n bags get rs                         # two ReplicaSets: old one scaled to 0, kept for rollback
kubectl -n bags rollout undo deploy/bags-api
```

Now remove it all. From here on, **only Git deploys**:

```bash
kubectl delete -k deploy/overlays/dev
```

✅ **Checkpoint:** you can explain, without notes, the 7 steps in 3.2 and the 3 probes. Say them out loud once.

---

## Phase 4 — Monitoring (1 h)

### 🧠 4.1 How the stack fits together

```
 bags-api pods ──/metrics──┐
 kube-state-metrics ───────┤  (object state: replicas available, restarts, pod phase...)
 node-exporter ────────────┤  (node CPU, memory, disk)
 kubelet/cAdvisor ─────────┤  (container CPU/memory)
                           ▼  PULL every 15 s
                      Prometheus ── evaluates rules every 30 s ──► Alertmanager ──► Slack/PagerDuty/email
                        │  ▲                                        (group, dedupe, route, silence)
                 PromQL │  │ remote_write (at TGTG: to Mimir for long-term, multi-cluster storage)
                        ▼
                     Grafana
```

- **Pull model.** Prometheus scrapes targets; apps don't push. Benefits: Prometheus knows when a target is *down* (`up == 0`), and apps stay simple.
- **Prometheus Operator.** Instead of editing `prometheus.yml`, you create Kubernetes objects: a **ServiceMonitor** ("scrape Services with these labels") and a **PrometheusRule** ("these alert rules"). The operator turns them into Prometheus config. That's why our app's monitoring can ship in Git with the app.
- Prometheus adds **target labels** to every series it scrapes: `namespace`, `pod`, `service`, `job`, `instance`. Our queries filter on `service="bags-api"`.
- **Mimir** (their stack): Prometheus on its own is one server with local disk and limited retention. Each cluster's Prometheus `remote_write`s to Mimir, which scales horizontally, stores to S3 and gives one global query view across regions. Grafana queries Mimir with the same PromQL.
- **Graylog** (their stack): central logs (Fluent Bit/agents ship container logs → Graylog, backed by OpenSearch). Metrics tell you *something* is wrong; logs tell you *why*.

### 🧠 4.2 PromQL you must be fluent in

```promql
up{service="bags-api"}                                                      # 1 = scrape OK, 0 = target down
rate(http_requests_total{service="bags-api"}[5m])                          # per-second rate, per series
sum(rate(http_requests_total{service="bags-api"}[5m]))                     # total req/s across pods
sum by (status) (rate(http_requests_total{service="bags-api"}[5m]))        # split by status code
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))   # error ratio
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))  # p95 latency
kube_deployment_status_replicas_available{namespace="bags"}                # from kube-state-metrics
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="bags",container="bags-api"}[5m]))
increase(kube_pod_container_status_restarts_total{namespace="bags"}[1h])   # restarts in the last hour
```

Rules of thumb: `rate()` only on counters; `sum` *after* `rate`, never before; `histogram_quantile` needs `le` kept in the `by`.

**RED** for services (Rate, Errors, Duration) and **USE** for resources (Utilisation, Saturation, Errors). Our dashboard is laid out as RED plus saturation.

### 🧠 4.3 Alert lifecycle

`inactive` → condition true → `pending` (waiting for `for: 2m`, which filters out brief spikes) → `firing` → sent to Alertmanager, which **groups** related alerts, **routes** by labels (e.g. `team: infrastructure`, `severity: critical` → pager), **inhibits** (cluster down → mute the 50 pod alerts) and supports **silences** during maintenance. Every alert in our rules has a `runbook_url`. Good alerts are symptom-based, actionable and have a runbook.

▶ **Do** (stack is already installed; apps come via ArgoCD next, so first explore the platform itself)

```bash
kubectl -n monitoring get pods,svc        # check service names; adjust port-forwards below if they differ
kubectl get crd | grep monitoring.coreos.com
kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090 &
kubectl -n monitoring port-forward svc/mon-grafana 3000:80 &
```

- Prometheus http://localhost:9090 → *Status → Targets* (what's scraped), *Alerts* (built-in rules), *Graph*: try `up`, `kube_pod_info`, `sum by (namespace) (kube_pod_info)`.
- Grafana http://localhost:3000 (admin/admin) → Dashboards → *Kubernetes / Compute Resources / Namespace (Pods)*.

✅ **Checkpoint:** you can explain why `rate()` is needed on counters and what a ServiceMonitor does. Our app's target and dashboard appear in Phase 5.

---

## Phase 5 — GitOps with ArgoCD (1 h)

### 🧠 5.1 What GitOps is

Four principles: **declarative** (desired state as files), **versioned** (in Git), **pulled automatically** (an agent pulls, CI doesn't push), **continuously reconciled** (drift is detected and corrected).

```
 Git repo (desired) ──► ArgoCD repo-server: clones + renders (kustomize/helm) ──► manifests
                                                                                     │ diff
 Cluster (actual)   ◄── ArgoCD application-controller: compares, applies, reports ◄──┘
```

ArgoCD components: **api-server** (UI/CLI/API, SSO, RBAC), **repo-server** (git clone + render), **application-controller** (diff and sync, the reconcile loop), **redis** (cache), **applicationset-controller** (generates many Applications from templates), **notifications** (Slack on sync/degraded).

### 🧠 5.2 The two statuses (don't mix them up)

| Sync status | Health status |
|---|---|
| Does the cluster match Git? | Is what's running working? |
| `Synced` / `OutOfSync` | `Healthy` / `Progressing` / `Degraded` / `Missing` / `Suspended` |

A bad deploy can be **Synced and Degraded**: Git was applied correctly, but the pods crash. A manual `kubectl edit` makes it **OutOfSync and Healthy**.

### 🧠 5.3 Settings in our Application

- `automated` → sync when Git changes (polls about every 3 min; a Git webhook makes it instant).
- `prune: true` → a file deleted from Git means the resource is deleted from the cluster. Without it, orphans pile up.
- `selfHeal: true` → manual changes are reverted. During a live incident you might *disable* auto-sync to hotfix by hand, then put the fix in Git.
- `CreateNamespace=true`, `retry` with backoff.

### 🧠 5.4 Scaling the idea (what TGTG likely needs: multi-region)

- **App of apps:** one root Application points at a folder full of Application YAMLs, which bootstraps a whole cluster from Git.
- **ApplicationSet:** a template plus a *generator* (list of clusters, Git directories, PRs). For example, "for every cluster labelled `env=prod`, deploy `overlays/prod-<region>`". One definition, every region.
- **Sync waves / hooks:** order things (CRDs → namespaces → DB migration Job as `PreSync` → app).
- **Projects:** limit which repos, clusters and namespaces a team's apps may touch (RBAC boundary).
- **Image Updater** (alternative to our CI bump commit): ArgoCD watches the registry and updates tags itself.
- **Rollback:** prefer `git revert` (Git stays the truth). `argocd app rollback` works but turns off auto-sync, so Git and the cluster disagree.

**🎤 Interview line:** *"With GitOps the cluster pulls its state from Git. CI only builds and publishes an image and opens or commits the tag change, so CI has no cluster credentials, every change is reviewed and auditable, and rollback is a git revert. ArgoCD keeps reconciling, so manual drift is reverted automatically."*

### ▶ 5.5 Do

```bash
git pull                                  # in case CI already bumped the image tag
scripts/argocd-up.sh                      # installs ArgoCD, creates the Application, prints admin password
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure
argocd app get bags-api
argocd app sync bags-api                  # don't wait for the 3-min poll
kubectl -n bags get all
```

Open https://localhost:8080 and click into `bags-api`. The resource tree shows Deployment → ReplicaSet → Pods, plus Service, HPA, PDB, ServiceMonitor, PrometheusRule and ConfigMap.

Start traffic and look at the result:

```bash
scripts/load.sh start            # 2 loadgen pods hitting /bags
```

- Prometheus → *Targets*: `serviceMonitor/bags/bags-api` UP (2 endpoints). *Alerts*: the three `BagsApi*` rules, inactive.
- Grafana → dashboard **bags-api (RED)**. It came from Git through the ConfigMap and the sidecar.

✅ **Checkpoint:** the ArgoCD app is **Synced + Healthy**, and the dashboard shows traffic.

---

## Phase 6 — CI with GitHub Actions (1 h)

### 🧠 6.1 Anatomy of `.github/workflows/ci.yml`

- **Triggers** (`on`): push to `main` touching `app/**`, PRs, manual. The bump commit touches only `deploy/`, so it doesn't re-trigger CI (no infinite loop).
- **Jobs** run on fresh **runners** (VMs). `build-and-deploy` `needs: test`, so they run in sequence. PRs run tests only and never deploy.
- **Steps** use **actions** (reusable building blocks: `actions/checkout`, `docker/build-push-action`...). In production, pin third-party actions to a commit SHA (supply-chain security).
- **`permissions`**: the built-in `GITHUB_TOKEN` gets only `contents: write` + `packages: write`. Least privilege.
- **`concurrency`**: one run at a time per branch, so two quick pushes can't race their bump commits.
- **Cache** (`type=gha`) reuses Docker layers between runs.
- **Day 2 preview:** to push to AWS ECR you won't store AWS keys. GitHub issues a short-lived **OIDC token**, AWS IAM trusts it only for `repo:<you>/tgtg-lab:ref:refs/heads/main`, and you get temporary credentials. Expect a question on this.

**vs Jenkins** (they run both): Jenkins = self-hosted server, Groovy `Jenkinsfile`, plugins, agents you maintain. Very flexible, but you own upgrades, plugin security and scaling. GitHub Actions = hosted, YAML next to the code, marketplace actions, built-in OIDC. Your Jenkins experience (job promotion, fixing pipelines) transfers directly: same concepts, different syntax.

### ▶ 6.2 Do

1. GitHub → your repo → **Actions** tab. Open the run from your first push.
2. If the image pushed: GitHub → your profile → **Packages** → `tgtg-lab/bags-api` → *Package settings* → **Change visibility → Public** (otherwise the cluster can't pull it without a pull secret).
3. Make a real change and watch the full loop:
   ```bash
   git pull
   sed -i 's/Bakery Nørrebro/Bakery Nørrebro (v2)/' app/main.py
   git commit -am "feat: v2 store name" && git push
   ```
4. Watch: Actions run (≈2 min) → new commit `deploy(dev): bags-api abc1234` → `git pull` and look at `deploy/overlays/dev/kustomization.yaml` → `argocd app sync bags-api` (or wait) → rolling update:
   ```bash
   kubectl -n bags get pods -w
   kubectl -n bags get deploy bags-api -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
   ```

✅ **Checkpoint:** you can trace running pod → image tag → Git SHA → commit message. That traceability is the reason for SHA tags.

---

## Phase 7 — Incident drills (2 h) — the part that wins interviews

For each drill: **change → observe → diagnose → fix → fill one row of the README table.** Use the GitOps way (edit, commit, push, `argocd app sync bags-api`) unless a drill says otherwise. Keep `scripts/load.sh start` running and Grafana open.

Useful in every drill:

```bash
kubectl -n bags get pods -w
kubectl -n bags describe pod <pod>        # Events at the bottom
kubectl -n bags logs <pod> [--previous]
kubectl -n bags rollout status deploy/bags-api
argocd app get bags-api                   # sync + health
```

### Drill 1 — Bad deploy that passes health checks
`deploy/base/deployment.yaml`: `ERROR_RATE` → `"0.3"`. Push, sync.
**Observe:** pods roll fine (healthy, ready), but Grafana error ratio ~30 %. Prometheus alert `BagsApiHighErrorRate` goes pending → firing after ~2 min. Check Alertmanager on :9093.
**Fix:** `git revert HEAD && git push` → sync.
**Lesson:** probes check that the process is alive, not that it's *correct*. This is why canary deploys with metric analysis (Argo Rollouts) exist. 🎤 *"Mitigate first: roll back via git revert, then investigate."*

### Drill 2 — Manual drift
```bash
kubectl -n bags set env deploy/bags-api ERROR_RATE=0.5
kubectl -n bags delete svc bags-api
```
**Observe:** within seconds ArgoCD shows OutOfSync, then self-heals: the env var is reverted and the Service recreated (UI → *History and Events*).
**Lesson:** Git is the source of truth. In an emergency, disable auto-sync, hotfix, then commit.

### Drill 3 — OOMKilled
`resources.limits.memory: 20Mi`. Push, sync.
**Observe:** new pods `OOMKilled` / `CrashLoopBackOff`. `describe` shows `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`. **But the old pods keep serving.** The rollout is stuck because `maxUnavailable: 0`. ArgoCD: Synced + Progressing/Degraded.
**Fix:** revert. **Lesson:** size limits from observed usage (`kubectl top`, Grafana); for JVMs keep the heap below the limit.

### Drill 4 — CrashLoopBackOff from bad config
`ERROR_RATE: "abc"` (Python can't parse it at startup).
**Observe:** `kubectl logs <new-pod> --previous` → `ValueError: could not convert string to float`. Back-off doubles each restart (10s, 20s, 40s… max 5 min). Old pods keep serving.
**Fix:** revert. **Lesson:** validate config in CI (or fail fast with a clear message). `--previous` is the key flag.

### Drill 5 — Running but not Ready
`NOT_READY: "true"`.
**Observe:** new pods `Running` but `0/1` READY; `describe` → `Readiness probe failed: HTTP probe failed with statuscode: 503`. The rollout stalls and the old pods keep traffic. Confirm only the old pods are behind the Service:
```bash
kubectl -n bags get endpointslices -l kubernetes.io/service-name=bags-api -o wide   # only old pod IPs
```
**Fix:** revert. 🎤 *"Readiness removes a pod from the Service, liveness restarts it. Mixing them up causes outages."*

### Drill 6 — ImagePullBackOff
In `deploy/overlays/dev/kustomization.yaml` set `newTag: does-not-exist`.
**Observe:** `ErrImagePull` → `ImagePullBackOff`; events: `manifest unknown` / `not found`. (Private registry without credentials would show `unauthorized`.)
**Fix:** revert. **Lesson:** on EKS, also check ECR permissions on the node role and whether the image exists for the node's CPU architecture (arm64 vs amd64).

### Drill 7 — Slow, not broken
`EXTRA_LATENCY: "0.8"`.
**Observe:** zero errors and pods healthy, but p95 ≈ 0.8 s and `BagsApiHighLatency` fires after 3 min.
**Fix:** revert. **Lesson:** alert on latency, not only errors. Users experience slow as broken.

### Drill 8 — Autoscaling
```bash
scripts/load.sh start work 4
kubectl -n bags get hpa -w            # TARGETS climbs past 70 %, REPLICAS 2 → up to 6
kubectl -n bags top pods
scripts/load.sh stop                  # after ~1 min of low load it scales back down
```
**Then break it:** remove `requests.cpu` from the Deployment (push, sync) → `kubectl -n bags describe hpa bags-api` shows `missing request for cpu` and TARGETS `<unknown>`. Revert.
**Lesson:** HPA % is relative to *requests*. On EKS, when pods don't fit on the nodes, they stay `Pending` until Cluster Autoscaler/**Karpenter** adds nodes. That's the second scaling layer.

### Drill 9 — Node drain (maintenance / upgrade)
```bash
kubectl -n bags get pods -o wide                       # note nodes
kubectl drain lab-worker --ignore-daemonsets --delete-emptydir-data
kubectl -n bags get pods -o wide                       # moved to lab-worker2; PDB kept ≥1 up
kubectl uncordon lab-worker
```
**Lesson:** this is what an EKS node-group upgrade or Karpenter consolidation does. Without a PDB and ≥2 replicas, a drain causes downtime.

---

## Phase 8 — Wrap up (30 min)

1. Fill the **Incidents & drills** table in `README.md` (one line each, in your own words), add 2–3 screenshots (`docs/img/`): ArgoCD tree, Grafana during drill 1, firing alert.
2. Commit and push. This is the repo you link on the CV.
3. `scripts/teardown.sh` (rebuild any time in ~10 min: everything is in Git, which shows GitOps working).
4. Set WSL memory back.

### 🎤 Your 60-second project pitch

*"To get hands-on with the stack you run, I built a small GitOps platform. A Python service with Prometheus metrics runs on Kubernetes. GitHub Actions tests it, builds an image tagged with the commit SHA, pushes it to GHCR and commits the new tag to a kustomize overlay. ArgoCD in the cluster syncs that with prune and self-heal on. The ServiceMonitor, alert rules with runbooks, and the Grafana dashboard ship in Git with the app. Then I broke it nine ways (bad deploy, OOMKill, crash loop, failing readiness, image pull, latency, drift, autoscaling, node drain) and documented diagnosis and prevention for each. Day 2 moves it to EKS provisioned with OpenTofu, with GitHub OIDC instead of stored AWS keys."*

---

## kubectl cheat sheet

```bash
kubectl get pods -A -o wide                    # everything, with nodes and IPs
kubectl get <kind> <name> -o yaml              # full object incl. status
kubectl describe <kind> <name>                 # human view + Events
kubectl get events -A --sort-by=.lastTimestamp
kubectl logs <pod> [-c container] [--previous] [-f] [--since=10m]
kubectl logs deploy/bags-api -n bags           # one pod of the deployment
kubectl exec -it <pod> -- sh                   # (our image has no shell tools — use a debug pod:)
kubectl debug -it <pod> --image=busybox:1.36 --target=bags-api
kubectl port-forward svc/<svc> <local>:<port>
kubectl top nodes / pods
kubectl rollout status|history|undo|restart deploy/<name>
kubectl scale deploy/<name> --replicas=3
kubectl explain <kind>.<field>
kubectl auth can-i create deployments -n bags --as=system:serviceaccount:bags:default
kubectl cordon|drain|uncordon <node>
kubectl config get-contexts / use-context <ctx>  # which cluster am I talking to?! (check before every prod command)
```

## If something doesn't work

| Symptom | Likely fix |
|---|---|
| `kind create cluster` hangs / pods evicted | Docker Desktop memory too low → raise WSL to 10 GB, restart |
| `kubectl apply -k` → `no matches for kind ServiceMonitor` | Run `scripts/monitoring-up.sh` first (installs the CRDs) |
| ArgoCD `repository not found` | Repo must be public, URL in `argocd/bags-api.yaml` must be correct (run `set-repo.sh`, push) |
| ArgoCD OutOfSync forever after `set-repo.sh` | You didn't push, or wait/refresh: `argocd app get bags-api --refresh` |
| Pods `ImagePullBackOff` on ghcr.io image | Make the GHCR package public (Phase 6 step 2) |
| HPA `<unknown>` | metrics-server not ready yet (`kubectl -n kube-system get pods`), or no CPU request |
| CI push fails `403` | Repo → Settings → Actions → General → Workflow permissions → *Read and write* |
| No `bags-api` target in Prometheus | Check Service has label `app: bags-api` and port name `http`; `kubectl -n bags get servicemonitor` |
| Port-forward names differ | `kubectl -n monitoring get svc` and use the names shown |
