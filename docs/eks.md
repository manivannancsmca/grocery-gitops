# Moving to AWS EKS (staging, then production)

The staging and prod environments are already described in this repository:
`projects/<env>`, `roots/<env>.yaml`, `app-of-apps/<env>`, and `overlays/<env>` of every service and the frontend.
They are validated on every pull request (`kustomize build` + kubeconform), but no cluster runs them yet. This page
lists what to do when the clusters exist. Values marked `REPLACE` in the files are filled in at that point.

## Design differences from Kind

| Concern | Kind | EKS (staging / prod) |
|---|---|---|
| Isolation | one local cluster | **one EKS cluster per environment, each with its own Argo CD**: production credentials never live in a non-production Argo CD |
| Databases, Kafka, Redis, search | in-cluster StatefulSets (`infrastructure/`) | AWS managed services from Terraform (`grocery-ai-app/infrastructure/aws/terraform`): RDS MySQL, MSK (SASL/SCRAM), ElastiCache, Elastic Cloud / OpenSearch |
| Spring profile | `docker` (Compose-like host names) | `aws` (env-only, TLS to RDS, SASL_SSL to MSK; no defaults for endpoints) |
| Secrets | Sealed Secrets (`*.sealed.yaml`) | External Secrets Operator + AWS Secrets Manager (`external-secrets.yaml`, ClusterSecretStore `aws-secrets-manager`) |
| Traffic | Envoy Gateway NodePort → 127.0.0.1:80 | Envoy Gateway behind an internet-facing NLB with an ACM certificate (`platform/gateway/overlays/eks-common`) |
| Storage class | local-path, Retain | EBS gp3, encrypted, Retain (`platform/cluster-base/overlays/eks`) |
| Scaling | 1 replica | HPA (staging 2–4, prod 3–10), PDB, spread over zones (prod: `DoNotSchedule`) |
| Pod Security | `baseline` enforced, `restricted` warned | `restricted` enforced in namespace `grocery` |
| Argo CD | local accounts, admin on | GitHub SSO through Dex (teams → roles), admin off, HA (`bootstrap/argocd/values-eks.yaml`) |
| Production changes | – | pull request (`promote.yml`), sync window Mon–Thu 06:00–14:00 UTC |

## Steps for one environment (repeat for prod)

1. **Cluster**: EKS 1.35 or newer (the Kind node is 1.36), with managed node groups across 3 AZs and these add-ons:
   - EBS CSI driver;
   - EKS Pod Identity agent;
   - AWS Load Balancer Controller.

   A Terraform `eks` module next to the existing modules is the natural place for this.
2. **Managed services**: apply the existing Terraform environment. Copy its outputs into
   `services/_shared/overlays/<env>/runtime-config.yaml`:
   - the RDS endpoint;
   - the MSK SASL/SCRAM bootstrap brokers;
   - the ElastiCache endpoint;
   - the search endpoint;
   - the domain.
3. **Secrets**: the Terraform `secrets` module already creates `grocery/<env>/<service>/db` and the MSK SCRAM
   secrets. Add `grocery/<env>/identity-service/bootstrap-admin`. Give the External Secrets controller's service
   account read access to `grocery/<env>/*` and `AmazonMSK_grocery/<env>/*` (Pod Identity association), and set the
   region in `platform/external-secrets/base/cluster-secret-store.yaml`.
4. **TLS and DNS**: an ACM certificate for the domain and `*.domain`. Put its ARN in
   `platform/gateway/overlays/eks-common/gatewayclass.yaml`, and point DNS at the NLB once it exists.
5. **SSO**: create a GitHub OAuth app (callback `https://argocd.<domain>/api/dex/callback`) and the teams
   `grocery-developers` and `grocery-release-managers`. Fill in `bootstrap/argocd/values-eks.yaml`, and store the
   client secret in the `argocd-secret` key `dex.github.clientSecret` (from Secrets Manager, never Git).
6. **Still to add for EKS** (in-cluster pieces that are AWS services or Terraform one-off tasks on ECS today):
   - Schema Registry in namespace `grocery-infra`, pointing at MSK with SASL;
   - the setup Jobs (`platform-init`) against RDS and MSK;
   - Kafka Connect: MSK Connect from Terraform, or Debezium in-cluster.

   Add them as `infrastructure/<name>/overlays/<env>` plus `app-of-apps/<env>/infra/*.yaml`.
7. **Bootstrap Argo CD** on the cluster (once, like `bootstrap-kind.ps1`):

   ```bash
   helm upgrade --install argocd argo/argo-cd --version 10.18.2 -n argocd --create-namespace \
     -f bootstrap/argocd/values-common.yaml -f bootstrap/argocd/values-eks.yaml
   kubectl create secret generic repo-grocery-gitops -n argocd \
     --from-literal=type=git --from-literal=url=git@github.com:manivannancsmca/grocery-gitops.git \
     --from-file=sshPrivateKey=<read-only deploy key for this cluster>
   kubectl label secret repo-grocery-gitops -n argocd argocd.argoproj.io/secret-type=repository
   kubectl apply -k bootstrap/argocd -k projects/<env>
   kubectl apply -f roots/<env>.yaml
   ```

   Use a separate read-only deploy key per cluster, so a cluster can be cut off on its own.
8. **First production release**: run *Promote to production* in GitHub Actions, review and merge.

## Things to keep in mind

- CI already updates `overlays/staging` on every build, so staging deploys automatically once its cluster exists.
- GHCR packages must be public, or each EKS cluster needs an image pull secret (through External Secrets). Mirroring
  the images into ECR is an option for production.
- Image signatures: CI attaches Sigstore-signed provenance attestations. Enforcing them at admission (Kyverno or
  Sigstore policy-controller) is a good next step for production.
