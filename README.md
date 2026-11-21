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
  scripts/                   bootstrap-kind.ps1, seal-kind-secrets.ps1, backup-sealing-key.ps1, destroy-kind.ps1
projects/<env>/              AppProjects: who may deploy what, where, from which repository (kind, staging, prod)
roots/<env>.yaml             the ROOT Application of an environment (App of Apps), applied once
app-of-apps/<env>/           the child Applications the root creates, ordered by sync waves
platform/                    cluster add-ons: namespaces, storage, Sealed Secrets / External Secrets, metrics-server,
                             Envoy Gateway + the public Gateway (Kind NodePort, EKS NLB)
infrastructure/<name>/       Kind only: MySQL, Kafka, Redis, Elasticsearch, Mailpit, Schema Registry, Kafka Connect,
                             network policies, platform-init (setup Jobs). EKS uses AWS managed services instead.
services/_components/        the spring-boot Kustomize Component shared by all 17 services
services/_shared/            ConfigMap grocery-runtime (per environment) + network policies of namespace grocery
services/<svc>/              base + overlays/kind|staging|prod (CI writes the image tag + digest into kind/staging)
frontend/grocery-web-ui/     nginx + React build, HTTPRoute; base + overlays/kind|staging|prod
docs/                        workflow.md (CI/CD step by step), rollback.md, troubleshooting.md, eks.md
.github/workflows/           validate.yml (every PR), promote.yml (staging -> prod pull request)
```

| Read this | For |
|---|---|
| [docs/workflow.md](docs/workflow.md) | the complete CI/CD + GitOps flow, step by step, and how to validate it |
| [docs/rollback.md](docs/rollback.md) | rolling back (Git revert, Argo CD rollback), and what a rollback does not undo |
| [docs/troubleshooting.md](docs/troubleshooting.md) | symptoms → causes → fixes for Argo CD, workloads, Kind and CI |
| [docs/eks.md](docs/eks.md) | moving staging and production to AWS EKS |

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
| -5 | `network-policies` (grocery-infra) | grocery-infra-kind | ✓ | ✓ | ✗ |
| 0 | `mysql`, `kafka`, `redis`, `elasticsearch`, `mailpit` | grocery-infra-kind | ✓ | ✓ | ✗ |
| 2 / 3 | `schema-registry`, `kafka-connect` | grocery-infra-kind | ✓ | ✓ | ✗ |
| 5 | `platform-init`: setup Jobs as Sync hooks (databases + users, topics, schemas, connectors) | grocery-infra-kind | ✓ | ✓ | ✗ |
| 15 | `grocery-shared`: runtime ConfigMap + network policies (grocery) | grocery-apps-kind | ✓ | ✓ | ✓ |
| 20 | the 17 services | grocery-apps-kind | ✓ | ✓ | ✓ |
| 30 | `grocery-web-ui` | grocery-apps-kind | ✓ | ✓ | ✓ |

The stateful infrastructure has every safeguard at once:
- no automatic pruning;
- no cascade-delete finalizer;
- `Delete=false,Prune=false` on the StatefulSets;
- `persistentVolumeClaimRetentionPolicy: Retain`;
- volumes on the `grocery-retain` StorageClass (`reclaimPolicy: Retain`).

Deleting data is always a deliberate, manual step.

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

# once per new cluster (or new key): random passwords for MySQL users, services and the bootstrap admin,
# committed only as SealedSecrets (plain values stay in %USERPROFILE%\.grocery-gitops\kind-secrets.json)
.\bootstrap\scripts\seal-kind-secrets.ps1
```

Every route answers under two local names that both reach 127.0.0.1 with no hosts-file entry: `*.localhost`
(browsers resolve it themselves) and `*.localtest.me` (public DNS; use it for CLI tools).

| URL | What |
|---|---|
| <http://argocd.localhost> | Argo CD. `developer` / `release-manager` passwords are in `%USERPROFILE%\.grocery-gitops\argocd-accounts.txt`; `argocd admin initial-password -n argocd` prints the admin password |
| <http://grocery.localhost> | the FreshCart web app. Sign in with a seeded `dev.*@grocery.local` account (password `Dev@12345`, see grocery-ai-app's README), or as `admin@grocery.local` (password in `kind-secrets.json`) |
| <http://mail.localhost> | Mailpit: every e-mail the platform sends |

Check what is running:

```powershell
kubectl get applications -n argocd          # every Application, with sync and health status
argocd login argocd.localtest.me:80 --grpc-web --plaintext --username developer   # :80 is required
argocd app list                             # the Applications this account may see
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
| External Secrets Operator (EKS) | chart 2.15.0 |
| MySQL / Kafka / Redis / Elasticsearch | 8.4.13 / 4.3.2 / 8.8.4 / 9.4.6 (same as local Compose) |
| Schema Registry / Debezium Connect / Mailpit | 8.2.4 / 3.7.1.Final / v1.32.0 |

Upgrades are pull requests that change these versions; Argo CD then rolls them out.
