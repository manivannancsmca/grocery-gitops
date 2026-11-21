# Troubleshooting and validation

Start from Argo CD: the Application tells you which resource is unhappy, and the resource's events tell you why.

```powershell
kubectl get applications -n argocd                          # sync + health of everything
argocd app get <app> --show-operation                       # last sync, failed resources, messages
argocd app diff <app>                                       # what differs between Git and the cluster
kubectl describe <kind>/<name> -n <namespace>               # events (pull errors, probe failures, scheduling)
kubectl logs deploy/<name> -n grocery --previous            # the crashed container's last log
kubectl get events -n grocery --sort-by=.lastTimestamp | Select-Object -Last 20
```

## Argo CD

| Symptom | Cause | Fix |
|---|---|---|
| App *Unknown*, "repository not accessible" / `ssh: handshake failed` | deploy key missing or wrong | `kubectl get secret repo-grocery-gitops -n argocd`; rerun `bootstrap-kind.ps1`; check the key on GitHub (*Settings → Deploy keys*) |
| App *OutOfSync* forever, sync succeeds | a field the cluster changes (defaults, a controller-managed field) | `argocd app diff`; add `ignoreDifferences` for that field (the HPA's `/spec/replicas` is already ignored in staging and prod) |
| Root stuck at a wave | a child Application of that wave is not Healthy | `argocd app get grocery-kind`, then open the child |
| "application destination … is not permitted in project" | the AppProject forbids the namespace or kind | intended: change `projects/<env>/*.yaml` deliberately, in a pull request |
| "permission denied" in the UI or CLI | RBAC | `argocd account can-i sync applications 'grocery-apps-kind/*'`; roles are in `bootstrap/argocd/values-common.yaml` |
| `argocd login` hangs: "gRPC connection not ready" | port missing | `argocd login argocd.localtest.me:80 --grpc-web --plaintext` (the CLI assumes 443) |
| `helm upgrade` of Argo CD fails: "conflict with argocd-controller" | Argo CD manages itself | change `bootstrap/argocd/values-*.yaml` in Git instead |
| Changes in Git not picked up for 3 minutes | polling interval | **Refresh** in the UI, or `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=normal --overwrite` |
| A Job hook keeps an old image although Git changed | hooks are not compared, so a hook-only change triggers no sync. platform-init has a revision ConfigMap for this (docs/workflow.md §8); for a one-off, run `argocd app sync platform-init` |
| Deleted Application, resources still there | intended for infrastructure (no cascade finalizer) | delete the resources deliberately, if that is really wanted |

## Workloads

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff`, "denied" / "unauthorized" | GHCR package is private | make the package public (*Package settings → Change visibility*) or add an image pull secret |
| `ImagePullBackOff`, "manifest unknown" | the overlay points at an image CI never pushed (`unset`) | let CI run (`build_all`), or check the deploy record in the CI run summary |
| `CreateContainerConfigError: secret … not found` | SealedSecret not decrypted | `kubectl get sealedsecret -A`; controller logs: `kubectl logs -n kube-system deploy/sealed-secrets-controller`; after a cluster rebuild, restore the key (`bootstrap-kind.ps1` does this from `%USERPROFILE%\.grocery-gitops\sealed-secrets-key.yaml`) |
| `no key could decrypt secret` | sealed for a different cluster key | reseal: delete the `*.sealed.yaml`, run `seal-kind-secrets.ps1`, commit |
| Pod `OOMKilled` | JVM above its memory limit | raise the limit in `overlays/<env>`, or `MaxRAMPercentage` in `grocery-runtime` |
| Startup probe fails after 6 minutes | the JVM starts slowly (CPU contention on a laptop) or can't reach MySQL / Kafka | `kubectl logs`; check that the `grocery-infra` pods are ready; raise `failureThreshold` in the spring-boot component |
| `Access denied for user 'x_user'` | user password differs from the service secret | rerun the setup Jobs: `argocd app sync platform-init` (the `mysql-init` Job sets every password from `mysql-users`) |
| Kafka `UnknownTopicOrPartition` | topics not created | `kubectl logs job/kafka-topics -n grocery-infra`; `argocd app sync platform-init` |
| Events not published (outbox rows pile up) | Debezium connector failed | `kubectl exec -n grocery-infra deploy/kafka-connect -- curl -s localhost:8083/connectors?expand=status`; `argocd app sync platform-init` re-registers them |
| `Schema not found` / serialization errors | schemas not registered | `kubectl logs job/schema-init -n grocery-infra` |
| A pod is blocked from a service it needs | NetworkPolicy | `kubectl get networkpolicy -A`; grocery-infra accepts traffic only from namespace `grocery` |
| Pod rejected: "violates PodSecurity" | security context | the namespaces enforce `baseline` (Kind) / `restricted` (EKS `grocery`); fix the manifest, not the label |

## Kind and the local machine

| Symptom | Fix |
|---|---|
| `http://grocery.localtest.me` does not answer | `docker ps` (the `grocery-worker` container publishes 127.0.0.1:80); `kubectl get gateway -n grocery-edge` must be Programmed; `kubectl get svc -n envoy-gateway-system` must show NodePort 30080 |
| A browser refuses `*.localtest.me` (e.g. "blocked by client") | use `*.localhost` (`grocery.localhost`, `argocd.localhost`, `mail.localhost`): same routes, resolved by the browser itself |
| Sign-in fails with 403 on a new host name | the gateway's CORS list: add the origin to `GATEWAY_ALLOWED_ORIGINS` in `services/_shared/overlays/kind/runtime-config.yaml`, then restart `api-gateway` |
| `*.localtest.me` slow at first | it resolves to `::1` (IPv6) and to 127.0.0.1; Kind listens on IPv4 only, so clients fall back after a moment. `curl.exe -4` avoids it. |
| Port 80 already in use | stop the other program, or change `hostPort` in `bootstrap/kind/cluster.yaml` and recreate the cluster |
| Everything slow, pods evicted | Docker memory: the full platform needs about 13 GiB. Stop the Compose stack (`docker compose -p grocery stop`) and raise WSL memory (`%USERPROFILE%\.wslconfig`, `memory=20GB`) |
| Cluster gone after a reboot | Kind nodes are containers with restart policy on; start Docker Desktop and wait. Recreate with `bootstrap-kind.ps1` if needed (the volumes are lost with the node containers; the Sealed Secrets key is restored from the backup) |

## CI (GitHub Actions)

| Symptom | Fix |
|---|---|
| "Secrets in the git history (gitleaks)" fails | open the job log. A real secret must be removed from history and rotated. A reviewed false positive goes into `.gitleaksignore` (fingerprint) or `.gitleaks.toml` |
| Trivy gate fails | upgrade the dependency or base image; accept only with an expiry date in `infrastructure/ci/docker/.trivyignore` |
| "Require the GitOps deploy key" fails | the `GITOPS_DEPLOY_KEY` secret is missing in `grocery-ai-app`; add the private half of `ci-gitops-write-key`, then **Re-run failed jobs** (the run's images are reused) |
| "Update the GitOps repository" fails: permission denied (publickey) / 403 | its public key is not a *write* deploy key on `grocery-gitops` |
| GitOps push rejected repeatedly | another writer keeps pushing; the job retries 5 times with rebase. Rerun the job |
| Service tests fail only on the runner | Testcontainers needs Docker (Ubuntu runners have it); look at the uploaded `test-reports-<service>` artifact |
| No images built after a docs-only change | intended: `paths-ignore` skips CI for Markdown and docs |

## Health checks and smoke tests

```powershell
kubectl get pods -A | Select-String -NotMatch 'Running|Completed'     # anything not running
kubectl top pods -n grocery                                            # memory per service (metrics-server)
curl.exe -s -o NUL -w "%{http_code}`n" http://grocery.localtest.me/              # 200: frontend
curl.exe -s http://grocery.localtest.me/api/health/gateway                       # gateway health
kubectl exec -n grocery-infra deploy/kafka-connect -- curl -s localhost:8083/connectors
kubectl exec -n grocery-infra statefulset/kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:29092 --list
```
