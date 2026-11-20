# grocery-gitops

The **desired state of every FreshCart environment**, as Kubernetes manifests. Argo CD watches this repository and
keeps each cluster equal to it. Nothing is deployed with `kubectl apply` or from CI. To change what runs, change
this repository.

| Repository | Holds | Written by |
|---|---|---|
| [grocery-ai-app](https://github.com/manivannancsmca/grocery-ai-app) | source code, tests, Dockerfiles, CI workflows | developers |
| **grocery-gitops** (this one) | Kubernetes manifests, Argo CD Applications, environment settings | developers (pull requests) and CI (image tags only) |

## How it fits together

```
developer ──push──▶ grocery-ai-app ──GitHub Actions──▶ build, test, scan, image to GHCR
                                                         │
                                                         └─ commits the new image tag ──▶ grocery-gitops
                                                                                             │
                     Kubernetes cluster ◀── sync, self-heal, health ── Argo CD (pulls) ◀─────┘
```

GitHub Actions never holds cluster credentials. Argo CD, running inside each cluster, is the only thing that
changes the cluster.

## Layout

```
bootstrap/
  kind/cluster.yaml          Kind cluster: 1 control plane + 1 worker, ports 80/443 on 127.0.0.1
  argocd/                    Argo CD Helm values (common + per environment) and Helm chart sources
  scripts/                   bootstrap-kind.ps1, backup-sealing-key.ps1, destroy-kind.ps1
projects/<env>/              AppProjects: who may deploy what, where, from which repository
roots/<env>.yaml             the ROOT Application of an environment (App of Apps), applied once
app-of-apps/<env>/           the child Applications the root creates, ordered by sync waves
platform/                    cluster add-ons: namespaces, storage, Sealed Secrets, metrics-server, Envoy Gateway
infrastructure/              stateful services and their setup Jobs (MySQL, Kafka, ...)        [step 2]
services/                    the 17 Spring Boot services: base + overlays per environment     [step 3]
frontend/                    grocery-web-ui: base + overlays per environment                  [step 3]
docs/                        workflow, troubleshooting, rollback                               [step 5]
```

## App of Apps on Kind

`roots/kind.yaml` (root `grocery-kind`) creates everything in `app-of-apps/kind`, wave by wave. Each wave waits until
the Applications of the previous one are **Healthy**.

| Wave | Application | Project | Auto sync | Self-heal | Prune |
|---|---|---|---|---|---|
| -100 | AppProjects | – | via root | via root | – |
| -40 | `cluster-base`: namespaces, Retain storage class | grocery-platform | ✓ | ✓ | ✗ |
| -30 | `sealed-secrets`, `envoy-gateway` | grocery-platform | ✓ | ✓ | ✗ |
| -30 | `metrics-server` | grocery-platform | ✓ | ✓ | ✓ |
| -20 | `gateway`: public Gateway and Argo CD route | grocery-platform | ✓ | ✓ | ✓ |
| -10 | `argocd`: Argo CD manages itself | grocery-platform | ✓ | ✓ | ✗ |

**Pruning is a deliberate choice per Application, not a default.** It is off for anything that holds state or
defines types: namespaces, CRDs, the sealing key, Argo CD itself and every database. Where it is off, the
Application also has no cascade-delete finalizer, and the critical objects carry
`argocd.argoproj.io/sync-options: Delete=false`. The root Application never prunes. Removing an Application from
Git leaves it in place until a person removes it on purpose.

App of Apps only organises Applications. It is not what isolates environments. That comes from separate clusters
(Kind locally, one EKS cluster each for staging and production, each with its own Argo CD), separate AppProjects and
namespaces, and RBAC.

## Access control

- **AppProjects** (`projects/kind`):
  - `grocery-platform` is the only project that may create cluster-wide resources, and only admins use it.
  - `grocery-infra-kind` may deploy only to namespace `grocery-infra`.
  - `grocery-apps-kind` may deploy only to namespace `grocery`.
  - Each project accepts only this repository and an allow-list of resource kinds.
- **RBAC** (`bootstrap/argocd/values-common.yaml`): everything is denied by default.

  | Role | Can |
  |---|---|
  | `developer` | view and sync non-production apps, restart Deployments, read logs |
  | `release-manager` | sync and roll back in every environment |
  | `admin` | the break-glass account |

  On Kind these are local accounts. On EKS they become SSO groups.
- **Repository credential:** a read-only SSH deploy key. The bootstrap script creates the Argo CD secret from a
  local file. Neither the key nor any plain Secret is ever committed (see `.gitignore`).

## Run it locally (Kind)

Requirements: Docker Desktop with about 13 GiB free for the full platform (stop the Compose stack of
grocery-ai-app first), plus `kind`, `kubectl`, `helm`, `argocd` and `kubeseal`.

```powershell
# one-time: the deploy key Argo CD uses to read this repository (add the .pub as a read-only deploy key on GitHub)
ssh-keygen -t ed25519 -N '""' -C argocd-kind -f $HOME\.grocery-gitops\argocd-deploy-key

# create the cluster and hand it to Argo CD
.\bootstrap\scripts\bootstrap-kind.ps1
```

Then open <http://argocd.localtest.me>. The passwords for `developer` and `release-manager` are in
`%USERPROFILE%\.grocery-gitops\argocd-accounts.txt`. `argocd admin initial-password -n argocd` prints the admin
password.

Check what is running:

```powershell
kubectl get applications -n argocd          # every Application, with sync and health status
argocd app list                             # same, after: argocd login argocd.localtest.me --grpc-web --plaintext
argocd app get grocery-kind                 # the root and its children
```

Delete the cluster with `.\bootstrap\scripts\destroy-kind.ps1`. It backs up the Sealed Secrets key first.

## Pinned versions

| Component | Version |
|---|---|
| Kubernetes (Kind node) | v1.36.4, pinned by image digest |
| Argo CD | Helm chart 10.18.2 (Argo CD v3.6.2) |
| Envoy Gateway | 1.10.0 (with the Gateway API CRDs) |
| Sealed Secrets | chart 2.22.0 (controller 0.41.2) |
| metrics-server | chart 3.14.0 |

Upgrades are pull requests that change these versions; Argo CD then rolls them out.
