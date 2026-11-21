# Rollback runbook

A deployment is a Git commit, so a rollback is too. Use the Git way whenever there is time; it keeps Git, Argo CD and
the cluster in agreement. The Argo CD way is for emergencies, and must be followed by the Git fix.

## Option A: revert in Git (preferred, every environment)

1. Find the commit that introduced the bad version:

   ```powershell
   git log --oneline -- services/order-service/overlays/kind/kustomization.yaml
   # e.g. 3f2a1c9 deploy: 1 image update(s) from 1a2b3c4  (github-actions[bot])
   ```

2. Revert it and push (in production: through a pull request):

   ```powershell
   git revert 3f2a1c9
   git push
   ```

3. Argo CD syncs the previous image (tag and digest) within about 3 minutes; click **Refresh** or run
   `argocd app get order-service --refresh` to make it immediate. Watch the rollout:

   ```powershell
   argocd app wait order-service --health --timeout 300
   kubectl rollout status deployment/order-service -n grocery
   ```

To pin a specific older version instead of reverting, set `newTag` and `digest` in the overlay to the values of a
known-good build. Every CI run lists them in its summary, and `git log -p` shows earlier ones.

For a production promotion, revert the merge commit of the promotion pull request (`git revert -m 1 <merge-sha>`)
through a new pull request.

## Option B: Argo CD rollback (emergency, minutes count)

Argo CD keeps the last 10 synced revisions of every Application (`revisionHistoryLimit: 10`).

With App of Apps, the root Application (`grocery-kind`) self-heals the child Application specs. Pausing a child's
auto-sync on its own is undone within seconds, so **pause the root first**. Only `admin` can do that, because the
root belongs to the platform project. This is an emergency, admin-level procedure by design.

```powershell
argocd login argocd.localtest.me:80 --grpc-web --plaintext --username admin
argocd app history order-service                     # ID, date, Git revision
argocd app set grocery-kind  --sync-policy none      # 1. stop the root from restoring the child's spec
argocd app set order-service --sync-policy none      # 2. stop auto-sync from re-applying Git's version
argocd app rollback order-service <ID>               # 3. roll back to a recorded revision
argocd app wait order-service --health
```

Then **fix Git** (option A: revert) and give the root its automation back. The root then restores every child's
automated sync, and the child syncs to the reverted Git state, which is what is already running:

```powershell
kubectl -n argocd patch application grocery-kind --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":false,\"selfHeal\":true}}}}'
# (or: kubectl apply -f roots/kind.yaml)
```

While auto-sync is off, the Application shows *OutOfSync*; that is expected.

Roles: `release-manager` may sync, roll back (option A, or `argocd app rollback` while the root is paused) and run
actions on `grocery-apps-*`. `developer` may not roll back. Only `admin` may pause the root or touch platform
Applications.

## Option C: Kubernetes rollout undo (never in GitOps)

`kubectl rollout undo` changes the cluster behind Argo CD's back. Self-heal reverts it within seconds, so it does not
work, and it shouldn't. Use A or B.

## What a rollback does NOT undo

- **Database schema changes** (Flyway migrations) stay applied. Releases must keep migrations backward-compatible
  (expand, then contract), so the previous version still runs on the new schema.
- **Events already published** stay in Kafka. Consumers are idempotent, and the Avro schemas are
  BACKWARD_TRANSITIVE.
- **Infrastructure data**: the infrastructure Applications never prune and their volumes are retained, so reverting
  an infrastructure change never deletes data. Restoring data is a separate procedure (database backups).

## Rollback drill (run on Kind, 2026-11-21)

| Step | What happened | Time |
|---|---|---|
| Deploy | commit `88e642a` adds `ORDER_PAYMENT_WINDOW=20m` to order-service; Argo CD syncs, the new pod is ready before the old one stops | 26 s from push to rolled out |
| B: Argo CD rollback | admin pauses `grocery-kind` and `order-service`, `argocd app rollback order-service 0` (revision `516f2e5`) | 31 s to Healthy, env var gone, app *OutOfSync* (Git still has the change) |
| A: Git revert | `git revert 88e642a` → `185b917`, root automation restored | 38 s to *Synced/Healthy*; no extra rollout, the cluster already matched Git |

History of `order-service` afterwards: `0 516f2e5` → `1 88e642a` → `2 516f2e5` (the rollback); Git `185b917`.
