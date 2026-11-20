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

```powershell
argocd login argocd.localtest.me:80 --grpc-web --plaintext --username release-manager
argocd app history order-service             # ID, date, Git revision
# Auto-sync would immediately re-apply Git's version, so pause it for this Application first:
argocd app set order-service --sync-policy none
argocd app rollback order-service <ID>
argocd app wait order-service --health
```

Then **fix Git** (option A) and turn automated sync back on:

```powershell
argocd app set order-service --sync-policy automated --self-heal --auto-prune
```

While auto-sync is off, the Application shows *OutOfSync*. The root Application (`grocery-kind`) re-enables
automated sync on its next self-heal. To keep it off during a longer investigation, change the child Application in
Git, or pause the root for that time with `argocd app set grocery-kind --sync-policy none`.

Roles: `release-manager` may roll back (the `update` permission on `grocery-apps-*`); `developer` may not, and nobody
but `admin` may roll back platform Applications.

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

## Rollback drill (recorded on Kind, 2026-11-21)

See the "Rollback drill" section of the README for the commands and timings of the drill run while setting this up.
