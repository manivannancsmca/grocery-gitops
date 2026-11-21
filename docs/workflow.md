# CI/CD and GitOps workflow, step by step

Two repositories, two tools, one direction of flow:

| | Repository | Tool | Writes to |
|---|---|---|---|
| **Continuous integration** | `grocery-ai-app` (code) | GitHub Actions | the container registry (GHCR) and **image references** in `grocery-gitops` |
| **Continuous delivery** | `grocery-gitops` (desired state) | Argo CD, inside each cluster | the Kubernetes cluster |

GitHub Actions never gets Kubernetes credentials and never runs `kubectl`. Argo CD pulls from Git and is the only
thing that changes a cluster. Every change to a cluster is therefore a Git commit: reviewable, auditable and revertible.

```
 developer ──PR──▶ grocery-ai-app ──merge──▶ main
                         │
             GitHub Actions (ci.yml)
   1 detect changes ─▶ 2 libs ─▶ 3 per-service Maven verify (unit + Testcontainers ITs)
                     ─▶ 4 frontend lint / test / build
                     ─▶ 5 security: gitleaks, hadolint, Trivy (SARIF + gate), CodeQL
   main only:          6 images: build once from the tested jar ─▶ push ghcr.io/…:sha-<commit>
                          ─▶ Trivy image gate ─▶ provenance + SBOM attestations
                       7 gitops: write tag + digest into overlays/kind + overlays/staging, commit, push
                         │
                         ▼
                   grocery-gitops (main) ──▶ Argo CD (Kind / staging cluster) ─▶ sync, health, self-heal
                         │
          promote.yml: staging ─▶ prod as a pull request ─▶ review + merge ─▶ Argo CD (prod cluster)
```

## 1. A developer changes code

1. Branch, commit, open a pull request on `grocery-ai-app`.
2. **CI on the pull request** (`.github/workflows/ci.yml`):
   - **Detect changes** (`.github/scripts/detect-changes.sh`) decides what to build:
     - a changed service builds that service;
     - a changed library, the runtime Dockerfile or CI itself builds every service;
     - the frontend and the setup bundle build only when their own files changed.
   - **Shared libraries**: `grocery-event-schemas` and `grocery-common` are built, tested and installed once, then
     handed to every service job.
   - **Per service** (parallel matrix): `mvn verify` runs the unit tests and the Testcontainers integration tests
     (MySQL, Kafka, Redis… in Docker on the runner). Test reports are uploaded as artifacts.
   - **Frontend**: `npm ci`, ESLint, Vitest, `vite build`.
   - **Security and quality**:
     - gitleaks scans the whole git history for secrets (reviewed false positives are listed in `.gitleaks.toml` and
       `.gitleaksignore`);
     - hadolint lints the Dockerfiles;
     - Trivy scans dependencies, secrets and IaC / Dockerfile settings. Its full report goes to *Security → Code
       scanning*, and the gate fails on fixable HIGH / CRITICAL findings.
   - **CodeQL** (`codeql.yml`): static analysis of the Java and JavaScript code.
   - **Dependabot** (`dependabot.yml`) opens weekly update pull requests, and each one goes through the same checks.
3. Review and merge. Nothing is published from a pull request.

## 2. CI publishes images (push to `main`)

4. Every job above runs again on `main`.
5. **Images**: one job per changed image.
   - **Build once**: a service image is built from the exact jar the tests just verified
     (`infrastructure/ci/docker/Dockerfile.service`: JRE only, non-root, read-only, layered).
   - The frontend comes from `Dockerfile.prod` (nginx-unprivileged).
   - The setup bundle comes from `infrastructure/k8s/platform-init`.
   - Images are pushed to `ghcr.io/manivannancsmca/grocery-<name>:sha-<full commit sha>`. Tags are never reused,
     and the digest is recorded.
   - **Trivy image gate**: an image with a fixable HIGH / CRITICAL vulnerability fails here. It stays in the registry
     but never reaches the GitOps repository, so it is never deployed.
   - **Attestations**: build provenance (SLSA) and the SBOM, signed keyless with Sigstore. Verify one with
     `gh attestation verify oci://ghcr.io/manivannancsmca/grocery-order-service:sha-<sha> -R manivannancsmca/grocery-ai-app`.
6. **GitOps update** (`.github/scripts/update-gitops.sh`):
   - checks out `grocery-gitops` with a deploy key that can write to that one repository only (secret
     `GITOPS_DEPLOY_KEY`);
   - for each new image, sets `newName`, `newTag: sha-<commit>` and `digest: sha256:…` in
     `services/<svc>/overlays/{kind,staging}/kustomization.yaml` (or the frontend / platform-init overlay);
   - commits as `github-actions[bot]` (the message links the source commit and the CI run) and pushes, rebasing and
     retrying if another run pushed first. Only one update runs at a time.

## 3. Argo CD delivers (the cluster pulls)

7. Argo CD polls the GitOps repository every 3 minutes (a GitHub webhook can make it instant). It renders each
   Application with Kustomize and compares the result with the cluster.
8. **Automated sync**: the changed Applications (for example `order-service`) apply the new Deployment, and Kubernetes
   rolls it out with `maxSurge: 1, maxUnavailable: 0`.
   - Readiness probes keep traffic off pods that aren't ready.
   - The `preStop` sleep and Spring's graceful shutdown drain the old pods.
9. **Health assessment**: an Application is *Healthy* only when its Deployments are available, StatefulSets ready,
   Jobs complete and HTTPRoutes accepted (with custom Lua health checks for Gateway API). The root App of Apps waits
   for each wave to be Healthy before the next.
10. **Self-heal**: a manual `kubectl edit` or `scale` is reverted to Git within seconds.
11. **Deployment history**: every sync is recorded (`argocd app history <app>`), with the Git revision of each one.

## 4. Promotion to production

12. Staging receives every successful build automatically (step 6). When staging is good, run **Actions → Promote
    to production** in `grocery-gitops`, for all components or just one.
13. The workflow copies the staging image tag and digest into `overlays/prod` on a new branch and opens a **pull
    request**.
14. A release manager reviews and merges it. Argo CD on the production cluster syncs it inside the production sync
    window (Monday to Thursday, 06:00–14:00 UTC; `projects/prod/apps.yaml`).

## 5. Changing configuration (not code)

Configuration lives in the GitOps repository too, so the process is the same: a pull request to `grocery-gitops`
(validated by `.github/workflows/validate.yml`), merge, and Argo CD syncs.

| What | Where |
|---|---|
| Settings shared by every service | `services/_shared/overlays/<env>/runtime-config.yaml`; after a change, restart the services (the ConfigMap is read at start-up) |
| One service | `services/<svc>/base` (all environments) or `services/<svc>/overlays/<env>` |
| Replicas / resources / autoscaling | `overlays/<env>` (HPA in staging and prod) |
| A secret (Kind) | change the value in `%USERPROFILE%\.grocery-gitops\kind-secrets.json`, delete the sealed file, run `bootstrap/scripts/seal-kind-secrets.ps1`, commit |
| A secret (EKS) | in AWS Secrets Manager; External Secrets refreshes it within an hour |
| Argo CD itself | `bootstrap/argocd/values-*.yaml` (Argo CD manages itself) |

## 6. First-time setup (what was done once)

1. Create the GitHub repositories `grocery-ai-app` and `grocery-gitops`.
2. In `grocery-gitops`, add two deploy keys:
   - `argocd-kind (read-only)`: the public half of `%USERPROFILE%\.grocery-gitops\argocd-deploy-key`; Argo CD reads
     with it.
   - `grocery-ai-app CI (write)`: the public half of `ci-gitops-write-key`; CI writes image references with it.
3. In `grocery-ai-app`, set the Actions secret **`GITOPS_DEPLOY_KEY`** to the private half of `ci-gitops-write-key`.
4. In `grocery-gitops`, enable *Settings → Actions → General → Allow GitHub Actions to create and approve pull
   requests* (for the promote workflow).
5. Check that the images can be pulled anonymously. Packages that Actions publishes from this *public* repository
   came out public. If a package is private, make it public (*Package → Settings → Change visibility*) or give the
   cluster an image pull secret.
6. Run `bootstrap/scripts/bootstrap-kind.ps1`, then `bootstrap/scripts/seal-kind-secrets.ps1`.
7. Run the CI workflow once with **build_all** (*Actions → CI → Run workflow*). Once the images exist, enable
   `infra/platform-init.yaml`, `services/*` and `frontend/*` in `app-of-apps/kind/kustomization.yaml`.

On 2026-11-21 the first image references were committed by hand (commits `516f2e5` and `f4e01da`, labelled
*bootstrap*), with exactly the values the CI job writes. This was needed because the `GITOPS_DEPLOY_KEY` secret wasn't
set yet. Every later update comes from CI.

**First fully automatic run** (2026-11-21):

1. grocery-ai-app CI run 44874740690 (commit `a8308f2`): libraries, 17 services' tests, frontend, security
   checks and 19 images with their gates.
2. The CI job committed `dc0d356` *"deploy: 37 image update(s) from a8308f2"* as `github-actions[bot]`.
3. Argo CD found that commit by polling, with nobody touching it:
   - all 18 Deployments were on the new images after **264 s**;
   - all 35 Applications were Synced/Healthy after **464 s**;
   - there were zero pod restarts.

## 8. Setup Jobs and new bundles

The setup Jobs (`infrastructure/platform-init`) are Argo CD Sync hooks, and Argo CD leaves hooks out of its
comparison. A commit that changes *only* a hook therefore never makes the Application OutOfSync, so auto-sync never
re-runs it.

To make a new bundle image re-run the Jobs anyway:
- the ConfigMap `platform-init-revision` carries the bundle reference;
- a Kustomize replacement copies that reference from the Jobs.

Every new bundle then changes a tracked resource. Argo CD syncs the Application, and the Jobs run again.
(Verified: after `ee9fc36` all four Jobs re-ran with the new bundle on their own.) Use the same pattern for any
other hook whose input changes.

## 7. Validate the whole chain

```powershell
# Argo CD's view: every Application Synced + Healthy
kubectl get applications -n argocd
argocd app list                                   # after: argocd login argocd.localtest.me:80 --grpc-web --plaintext

# the app (browsers: *.localhost; CLIs: *.localtest.me - both reach the same routes)
curl.exe -s http://grocery.localtest.me/api/health/gateway       # gateway health through Envoy + nginx
start http://grocery.localhost                                    # sign in, e.g. dev.customer@grocery.local / Dev@12345
start http://mail.localhost                                       # e-mails sent by notification-service

# what runs where, and which image
kubectl get deploy -n grocery -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
argocd app history order-service

# a change end to end: commit to grocery-ai-app -> CI -> GitOps commit -> Argo CD sync
git -C ..\grocery-gitops log --oneline -5         # look for "deploy: …" commits by github-actions[bot]
```
