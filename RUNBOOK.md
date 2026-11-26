# bags-api runbook

Every alert links here. A runbook answers: *what does this mean, how bad is it, what do I check first, how do I mitigate.*

Dashboard: Grafana → **bags-api (RED)** · ArgoCD app: `bags-api` · Namespace: `bags`

## BagsApiHighErrorRate

**Meaning:** > 5 % of `/bags` requests return 5xx for 2 minutes. Users see failures.

1. **Recent change?** ArgoCD → bags-api → *History*. Did a sync happen just before the alert? `git log --oneline -5 deploy/`
2. **If yes → mitigate first:** `git revert <commit> && git push` (ArgoCD rolls back). Investigate after.
3. **If no:** `kubectl -n bags logs deploy/bags-api --since=10m | grep -v ' 200 '` · `kubectl -n bags get pods` (restarts?) · dependencies healthy?
4. Afterwards: write a short postmortem (timeline, root cause, why it wasn't caught, action items).

## BagsApiHighLatency

**Meaning:** p95 of `/bags` > 500 ms for 3 minutes. No errors needed — slow is also broken.

1. Saturation? `kubectl -n bags get hpa` (at max?), `kubectl top pods -n bags`, `kubectl top nodes`.
2. Recent config change (e.g. `EXTRA_LATENCY`)? Check ArgoCD history.
3. Mitigate: roll back, or raise HPA max / add nodes if it's real load.

## BagsApiNoReadyPods

**Meaning:** zero available pods. Full outage of the service.

1. `kubectl -n bags get pods` → status column tells you where to look:
   - `CrashLoopBackOff` → `kubectl -n bags logs <pod> --previous`
   - `ImagePullBackOff` → `kubectl -n bags describe pod <pod>` (wrong tag? registry auth?)
   - `Pending` → `describe pod` events (insufficient CPU/memory? node selector?)
   - `Running` but `0/1` READY → readiness probe failing: `describe pod`, check `/readyz`
2. Mitigate: revert the last change in Git.
