<!--
Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Hybrid Cloud AI Agents on Distributed Cloud software only reference implementation

## Overview

This Solution Reference Implementation (SRI) deploys the base platform resources
for the Hybrid Cloud AI Agents solution on Distributed Cloud software only
clusters and Google Cloud. It covers cluster setup and fleet registration,
External Secrets Operator, and the tiered internal PKI and model-tier HTTPS
ingress. It also deploys the Apigee hybrid 1.17.3 runtime through one Connect
Gateway Helm pipeline, Google Cloud Platform prerequisites, and the Cloud Build
and Config Delivery pipeline setup. Finally, it deploys the agent-agnostic
platform `FleetPackage` (`hybridcloud-agents-platform`, delivering baseline
`agent-workloads` policies, MCP Toolbox, and the OpenTelemetry Collector). For
the architecture, see **Architecture and design** in the
[SRA](../README.md#high-level-architecture).

This solution includes a companion GitHub repository,
[Hybrid Cloud AI Agents on Distributed Cloud software only (`GoogleCloudPlatform/gdc-solutions`)](https://github.com/GoogleCloudPlatform/gdc-solutions/tree/main/software-only/bare-metal/hybridcloud-agents)
(folder `software-only/bare-metal/hybridcloud-agents`), which serves as a
kickstart sample containing all solution artifacts. It provides Config Delivery
Fleet packages, agent and Envoy Kubernetes Resource Model (KRM) manifests, and
Apigee hybrid proxy bundles and environment configuration. It also includes
Agent Registry declarations and Cloud Build synchronization scripts, sample ADK
agent source code, and optional test harnesses (`tests/a2a/`,
`tests/data-tier/`, `tests/model-tier/`, and `tests/verify/`). All code samples
and repository paths linked below point to this companion repository.

This SRI covers Day-0 and Day-1 base platform resources and finishes with a
running, observable platform (`FleetPackage/hybridcloud-agents-platform`, with
no agents deployed). Configuring the Apigee AI Gateway covers the Model Armor
template, proxies, API products, model routing, LLM token quotas, Model Armor
wiring, key value maps, and developer apps. Next steps include building the
sample agent images and deploying the agent-specific `FleetPackage`
(`hybridcloud-agents`), which ships the ADK agents, agent-tier Envoy proxies,
and per-agent `NetworkPolicy` objects. All of those steps and end-to-end
verification are covered in the
[SUG](user-guide.md#step-1-configure-the-ai-gateway-and-onboard-the-first-agent-v110).
Each step is shown explicitly for auditability and learning. For production
deployments, several of these steps, mainly the Google Cloud resources, could be
automated with Terraform in the future. Run every step from a workstation that
reaches all clusters through
[Connect Gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway/setup).

<!-- prettier-ignore -->
> [!NOTE]
> Platform operators (External Secrets Operator and Apigee hybrid) are installed
> in this guide through Helm. Direct `kubectl` steps create the PKI, secret
> stores, model-tier ingress, and Apigee prerequisites (namespace, node labels,
> default storage class, and CRDs). They also configure observability settings
> and the reconciler RBAC and `roleRefs` bindings that GitOps cannot deliver to
> itself. The agent-agnostic platform workloads (baseline `agent-workloads`
> policies, MCP Toolbox, and the OpenTelemetry Collector) are delivered in Step
> 7 through `FleetPackage/hybridcloud-agents-platform`. The ADK agents,
> agent-tier Envoy proxies, and per-agent policies are delivered in the SUG
> through `FleetPackage/hybridcloud-agents`.

<!-- prettier-ignore -->
> [!WARNING]
> Reference implementation disclaimer. This guide and its Apache 2.0 sample
> manifests are provided for architectural evaluation and reference purposes
> only, without official product support or service-level agreement (SLA)
> warranty. Validate all sizing, security, and operational controls against your
> production requirements before deployment.

## Objectives

- Build the agent and gateway-and-tool clusters (Step 0) and register them with
  the pre-deployed model cluster in one fleet.
- Install External Secrets Operator, configure the tiered internal PKI and
  model-tier HTTPS ingress, and install Apigee hybrid 1.17.3 keyless through
  fleet Workload Identity Federation (fleet WIF) on the clusters.
- Prepare Google Cloud platform prerequisites (Apigee TLS keystores, MCP
  database secret, and cluster observability). Set up the Cloud Build release
  pipeline and Config Delivery prerequisites, and deploy the agent-agnostic
  platform `FleetPackage` (`hybridcloud-agents-platform`).
- Verify platform readiness, reconciler isolation, and keyless authentication,
  then tear down the platform resources.

## Before you begin

### Cluster prerequisites

- Three Distributed Cloud software only bare-metal clusters in Topology C, one
  per tier. Size the hosts per the SRA hardware constraints.
  - Agent cluster and gateway-and-tool cluster: created in Step 0 on
    1.36.200-gke.118, with Dataplane V2 (default) and bundled MetalLB load
    balancing, and one free VIP on each for the agent mTLS ingress and the
    Apigee ingress.
  - Model cluster: pre-deployed, running a vLLM server deployed per
    [Open model serving on Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/solutions/open-model-serving-sw-only),
    with `--enable-auto-tool-choice --tool-call-parser=gemma4` added to the vLLM
    arguments. Without these flags, ADK tool calls fail with HTTP 500. For a
    test model cluster, [`tests/model-tier/`](../tests/model-tier/README.md) in
    the companion repository provides an optional `kubectl` sample.
- PostgreSQL with `pgvector` reachable from the gateway-and-tool cluster on
  TCP 5432. It requires a server certificate chained to the solution root CA
  with the `YOUR_PGVECTOR_HOST` value in its SANs, and a database-side
  allow-list for the gateway-and-tool node IPs. For testing,
  [`tests/data-tier/`](../tests/data-tier/README.md) in the companion repository
  deploys a seeded sample on a separate Kubernetes test cluster. Validation used
  a separate Distributed Cloud software only test cluster outside the three
  solution clusters.
- Customer hosts, storage, NTP, and VIPs: SSD-backed storage of at least 2,000
  IOPS (no NFS) and synchronized clocks on the Apigee data nodes.
- Internal DNS for the domain hard-coded in the Fleet package manifests and
  Apigee proxy policies in the companion repository:
  `api.hybrid-agents.internal` (Apigee ingress, KSA token audience),
  `agents-ingress.hybrid-agents.internal`, `vllm.models.hybrid-agents.internal`,
  and `registry.hybrid-agents.internal` (agent images). For another domain, edit
  [`fleet-package/src/base/`](../fleet-package/src/base) and the
  `VerifyJWT-*.xml` policies under [`apigee/proxies/`](../apigee/proxies) in
  your GitOps repository, then run `render.sh`.

### Client workstation prerequisites

- Google Cloud CLI with the `alpha` and `beta` components, `kubectl` 1.36, Helm
  3.17 or later, `jq` 1.6 or later, `git`, `openssl`, and `curl`. The 1.36
  client matches the 1.36 solution clusters and stays within Kubernetes ±1 minor
  version skew of a pre-deployed 1.35 model cluster.
- A private GitOps repository on a Git provider that Cloud Build
  [2nd-gen repository connections](https://docs.cloud.google.com/build/docs/repositories#2nd-gen-repos)
  support, such as GitHub or GitLab; you create it in Step 5 from the
  [companion repository](https://github.com/GoogleCloudPlatform/gdc-solutions/tree/main/software-only/bare-metal/hybridcloud-agents).
  For GitHub, the [`gh` CLI](https://cli.github.com/manual/) signed in as the
  repository owner.

### Google Cloud project, APIs, and roles

- An Apigee organization with the hybrid runtime entitlement. For testing, you
  can use a free 60-day
  [evaluation organization](https://docs.cloud.google.com/apigee/docs/api-platform/get-started/compare-paid-eval)
  (subject to non-production terms, no Data Residency, no SLA, and automatic
  deletion after 60 days; see
  [Create an organization](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/precog-provision)).
  For production or long-lived deployments, request the paid Subscription
  entitlement before you create the organization; otherwise Apigee creates an
  evaluation organization that cannot be converted in place.
- An operator identity with the following administrator roles:
  - Fleet and Connect Gateway: `roles/gkehub.admin` and
    `roles/gkehub.gatewayAdmin`
    ([Set up Connect Gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway/setup)).
  - Apigee hybrid: `roles/apigee.admin`, `roles/iam.serviceAccountAdmin`, and
    `roles/resourcemanager.projectIamAdmin`
    ([Configure permissions](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/precog-permissions)).
  - Config Delivery: `roles/configdelivery.admin`
    ([fleet package permissions](https://docs.cloud.google.com/distributed-cloud/connected/latest/docs/fleet-packages-guide)).
  - Cloud Build: `roles/cloudbuild.builds.editor`
    ([Cloud Build IAM roles](https://docs.cloud.google.com/build/docs/iam-roles-permissions)).
  - Model Armor and Agent Registry: `roles/modelarmor.admin`
    ([Model Armor roles](https://docs.cloud.google.com/model-armor/access-control/roles-permissions))
    and `roles/agentregistry.admin`
    ([Agent Registry roles](https://docs.cloud.google.com/agent-registry/roles-permissions)).
- The service identities in the following table. Agents hold no Google Cloud
  roles: Apigee calls Google Cloud APIs under its runtime service account.

<!-- mdformat off -->

| Identity                                                                            | Roles and scope                                                                                                                                                                                                                                                                                                                   | Created in                            |
| :---------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------ |
| Apigee runtime service account (`APIGEE_SA`)                                        | Apigee non-prod profile roles, plus `roles/serviceusage.serviceUsageViewer`, `roles/aiplatform.user`, `roles/modelarmor.user`, `roles/mcp.toolUser`, `roles/bigquery.jobUser` (project); `roles/iam.serviceAccountTokenCreator` on itself; `roles/iam.workloadIdentityUser` for the `apigee` namespace                            | Step 2                                |
| ESO fleet WIF principal (`ns/external-secrets/sa/eso-controller-sa`)                | `roles/secretmanager.secretAccessor` on each synced secret only                                                                                                                                                                                                                                                                   | Steps 1, 4 (per-agent secrets in SUG) |
| Release pipeline service account (`REGISTRAR_SA`)                                   | `roles/agentregistry.editor`, `roles/apigee.apiAdminV2`, `roles/apigee.developerAdmin`, `roles/apigee.environmentAdmin`, `roles/logging.logWriter` (project); `roles/iam.serviceAccountUser` on `APIGEE_SA`; `roles/secretmanager.secretVersionAdder` and `roles/secretmanager.secretVersionManager` on each per-agent key secret | Step 5 (per-agent secrets in SUG)     |
| Fleet package publisher (`PUBLISHER_SA`)                                            | `roles/configdelivery.resourceBundlePublisher`, `roles/artifactregistry.writer`, `roles/logging.logWriter`                                                                                                                                                                                                                        | Step 6                                |
| Agent image build service account (`BUILD_SA`)                                      | `roles/artifactregistry.writer` on the `AR_REPOSITORY` repository only (project default build service account unless you pass `--service-account` to `gcloud builds submit`)                                                                                                                                                      | Step 5                                |
| Config Delivery service agent                                                       | `Role/configdelivery-rootsync-manager` (`create`, `delete`, `get`, `patch` on `rootsyncs`) in `config-management-system`                                                                                                                                                                                                          | Step 6                                |
| OpenTelemetry Collector fleet WIF principal (`ns/otel-system/sa/otel-collector-sa`) | `roles/cloudtrace.agent`, `roles/monitoring.metricWriter`, `roles/logging.logWriter`, `roles/telemetry.writer`                                                                                                                                                                                                                    | Step 4                                |

<!-- mdformat on -->

### Central reference configuration

- [Workstation] Create the solution directory and its `.env` file.

  ```bash
  mkdir -p "${HOME}/gdcso-solutions/hybridcloud-agents"
  cat << 'EOF' > "${HOME}/gdcso-solutions/hybridcloud-agents/.env" && echo "Successfully created." || echo "Failed to create!"
  SOLUTION_HOME="${HOME}/gdcso-solutions/hybridcloud-agents"
  PROJECT_ID="YOUR_PROJECT_ID"
  PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
  REGION="us-central1"
  OPERATOR_EMAIL="YOUR_OPERATOR_EMAIL"
  AGENTS_CLUSTER="YOUR_AGENTS_CLUSTER_NAME"
  GATEWAY_CLUSTER="YOUR_GATEWAY_CLUSTER_NAME"
  MODEL_CLUSTER="YOUR_MODEL_CLUSTER_NAME"
  CTX_AGENTS="connectgateway_${PROJECT_ID}_global_${AGENTS_CLUSTER}"
  CTX_GATEWAY="connectgateway_${PROJECT_ID}_global_${GATEWAY_CLUSTER}"
  CTX_MODEL="connectgateway_${PROJECT_ID}_global_${MODEL_CLUSTER}"
  GATEWAY_FQDN="api.hybrid-agents.internal"
  AGENTS_INGRESS_FQDN="agents-ingress.hybrid-agents.internal"
  VLLM_FQDN="vllm.models.hybrid-agents.internal"
  APIGEE_INGRESS_VIP="YOUR_APIGEE_INGRESS_VIP"
  AGENTS_INGRESS_VIP="YOUR_AGENTS_INGRESS_VIP"
  MODEL_INGRESS_VIP="YOUR_MODEL_INGRESS_VIP"
  VLLM_NAMESPACE="YOUR_VLLM_NAMESPACE"
  VLLM_SERVICE="YOUR_VLLM_SERVICE"
  APIGEE_ORG="${PROJECT_ID}"
  APIGEE_ENV="hybrid-agents-env"
  APIGEE_ENVGROUP="hybrid-agents-envgroup"
  APIGEE_SA="YOUR_APIGEE_RUNTIME_SA_EMAIL"
  REGISTRAR_SA="YOUR_REGISTRAR_SA_NAME@${PROJECT_ID}.iam.gserviceaccount.com"
  PUBLISHER_SA="YOUR_PUBLISHER_SA_NAME@${PROJECT_ID}.iam.gserviceaccount.com"
  BUILD_SA="YOUR_BUILD_SA_EMAIL"
  GIT_CONNECTION="YOUR_CONNECTION"
  GIT_REPOSITORY="YOUR_REPOSITORY"
  GITOPS_OWNER="YOUR_GITOPS_OWNER"
  GITOPS_REPO="YOUR_GITOPS_REPO"
  REPO_DIR="${HOME}/gdcso-solutions/${GITOPS_REPO}"
  PKG_DIR="${REPO_DIR}/software-only/bare-metal/hybridcloud-agents"
  RELEASE_TAG="v1.0.0"
  AR_REPOSITORY="hybrid-cloud-agents"
  MCP_BUCKET="YOUR_MCP_BUCKET"
  MCP_DB_SECRET="hybrid-agents-pgvector-creds"
  MCP_DB_CREDS_FILE="YOUR_MCP_DB_CREDS_FILE"
  WORK="${SOLUTION_HOME}/.work"
  FLEET_POOL="${PROJECT_ID}.svc.id.goog"
  WIF_PREFIX="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject"
  ESO_PRINCIPAL="${WIF_PREFIX}/ns/external-secrets/sa/eso-controller-sa"
  OTEL_PRINCIPAL="${WIF_PREFIX}/ns/otel-system/sa/otel-collector-sa"
  EOF
  ```

  Replace the following:

  - `PROJECT_ID`, `PROJECT_NUMBER`: the fleet host and Apigee organization
    project.
  - `REGION`: stays `us-central1` because the Config Delivery (`FleetPackage`)
    API is available only in `us-central1`. The Cloud Build 2nd-gen repository
    connection and Artifact Registry bundle repository must be in the same
    region
    ([Fleet packages overview](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages),
    [Deploy fleet packages](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/how-to/fleet-packages)).
    Your bare-metal clusters can run in any location.
  - `OPERATOR_EMAIL`: the operator identity that receives Connect Gateway RBAC.
  - `AGENTS_CLUSTER`, `GATEWAY_CLUSTER`, `MODEL_CLUSTER`: the fleet membership
    names.
  - `MODEL_INGRESS_VIP`: the `ingressVIP` of the pre-deployed model cluster
    (`spec.loadBalancer.vips.ingressVIP` in its `bmctl` cluster configuration
    file). MetalLB VIPs live inside each cluster rather than in Fleet metadata,
    so `gcloud` does not return them; read this VIP directly from the model
    cluster with
    `kubectl --context="${CTX_MODEL}" get svc istio-ingress -n gke-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    after fetching Connect Gateway credentials in Step 0.
  - `APIGEE_INGRESS_VIP`, `AGENTS_INGRESS_VIP`: free addresses from
    `spec.loadBalancer.addressPools` in each cluster's `bmctl` configuration
    (excluding `controlPlaneVIP` and `ingressVIP`). Choose both upfront because
    Steps 1, 2, and 7 embed them in certificate SANs, Apigee `overrides.yaml`,
    and Fleet package manifests. Read them back after deployment with
    `kubectl --context="${CTX_GATEWAY}" get svc apigee-ingressgateway-hybrid-agents-ig -n apigee -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    (Step 2) and
    `kubectl --context="${CTX_AGENTS}" get svc agent-ingress-envoy -n agent-workloads -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    (SUG).
  - `VLLM_NAMESPACE`, `VLLM_SERVICE`: the namespace and `ClusterIP` Service
    (port 8000) of the pre-deployed vLLM server.
  - `APIGEE_SA`: the Apigee runtime service account email (non-prod profile).
  - `REGISTRAR_SA`, `PUBLISHER_SA`, `BUILD_SA`: the release pipeline, Fleet
    package publisher, and Cloud Build (`gcloud builds submit`) service
    accounts.
  - `GITOPS_OWNER`, `GITOPS_REPO`: the owner (user, organization, or group) and
    name of your private GitOps repository; `REPO_DIR` is its local clone.
  - `GIT_CONNECTION`, `GIT_REPOSITORY`, `RELEASE_TAG`, `AR_REPOSITORY`: the
    Cloud Build connection, its linked repository resource, the release tag, and
    the Artifact Registry Docker repository. Start the release tag at `v1.0.0`
    for the initial platform release in Step 7 and increment for later releases.
  - `MCP_BUCKET`: the Cloud Storage bucket exposed through the Cloud Storage MCP
    proxy.
  - `MCP_DB_CREDS_FILE`: a local JSON file with your database's `PG_DATABASE`,
    `PG_USER`, and `PG_PASSWORD`; `MCP_DB_SECRET` is the name the Fleet package
    expects.

- [Workstation] Load the configuration in every new shell.

```bash
set -a; source "${HOME}/gdcso-solutions/hybridcloud-agents/.env"; set +a
```

- [Workstation] Enable the Google Cloud APIs.

```bash
gcloud services enable \
  gkehub.googleapis.com connectgateway.googleapis.com anthosconfigmanagement.googleapis.com \
  configdelivery.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  apigee.googleapis.com apigeeconnect.googleapis.com apihub.googleapis.com \
  cloudresourcemanager.googleapis.com pubsub.googleapis.com aiplatform.googleapis.com \
  agentregistry.googleapis.com modelarmor.googleapis.com bigquery.googleapis.com \
  storage.googleapis.com secretmanager.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com cloudtrace.googleapis.com telemetry.googleapis.com \
  --project="${PROJECT_ID}"
```

<!-- prettier-ignore -->
> [!NOTE]
> Apigee organization creation enables `apihub.googleapis.com` automatically;
> enabling it explicitly keeps the setup deterministic.

## Step 0: Build the clusters and register the fleet

- [Workstation] Create the agent and gateway-and-tool clusters with `bmctl` per
  [Create standalone clusters](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/creating-clusters/standalone-cluster-creation),
  in the fleet project. Apply these solution choices in each cluster
  configuration:
  - Keep Dataplane V2 enabled; the solution `NetworkPolicy` objects rely on it.
  - Use bundled load balancing: `controlPlaneVIP` outside
    `loadBalancer.addressPools`, `ingressVIP` inside the pool, and leave the
    ingress VIPs above free.
  - Wait more than 60 seconds between `bmctl configure projects`, `bmctl check`,
    and `bmctl create` runs for the two clusters. Back-to-back runs exceed the
    Resource Manager read quota (`RATE_LIMIT_EXCEEDED`).
- [Workstation] Grant Connect Gateway access on each cluster (run with the
  cluster's admin kubeconfig) per
  [Set up Connect Gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway/setup).

```bash
for CLUSTER in "${AGENTS_CLUSTER}" "${GATEWAY_CLUSTER}"; do
  gcloud container fleet memberships generate-gateway-rbac \
    --membership="${CLUSTER}" --role=clusterrole/cluster-admin \
    --users="${OPERATOR_EMAIL}" --project="${PROJECT_ID}" \
    --kubeconfig="${HOME}/bmctl-workspace/${CLUSTER}/${CLUSTER}-kubeconfig" \
    --context="${CLUSTER}-admin@${CLUSTER}" --apply
done
```

- [Workstation] Fetch Connect Gateway credentials for the two created clusters
  and the pre-deployed model cluster, and label the memberships with their tier
  and platform selector. The `hybrid-agents-platform=enabled` label targets both
  clusters that receive `FleetPackage/hybridcloud-agents-platform` in Step 7.

```bash
for CLUSTER in "${AGENTS_CLUSTER}" "${GATEWAY_CLUSTER}" "${MODEL_CLUSTER}"; do
  gcloud container fleet memberships get-credentials "${CLUSTER}" \
    --location=global --project="${PROJECT_ID}"
done
gcloud container fleet memberships update "${AGENTS_CLUSTER}" --location=global \
  --update-labels=cluster-role=agents,hybrid-agents-platform=enabled --project="${PROJECT_ID}"
gcloud container fleet memberships update "${GATEWAY_CLUSTER}" --location=global \
  --update-labels=cluster-role=gateway-tools,hybrid-agents-platform=enabled --project="${PROJECT_ID}"
gcloud container fleet memberships update "${MODEL_CLUSTER}" --location=global \
  --update-labels=cluster-role=models --project="${PROJECT_ID}"
```

**Verify:** each context returns a `Ready` node, and the memberships carry the
labels.

```bash
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}" "${CTX_MODEL}"; do
  kubectl --context="${CTX}" get nodes
done
gcloud container fleet memberships list --project="${PROJECT_ID}" \
  --format="table(name.basename(),labels.cluster-role,labels.hybrid-agents-platform)"
```

The output is similar to the following:

```text
NAME                  STATUS   ROLES           AGE   VERSION
agents-node-1         Ready    control-plane   8m    v1.36.4-gke.100
NAME                  STATUS   ROLES           AGE   VERSION
gateway-node-1        Ready    control-plane   7m    v1.36.4-gke.100
NAME                  STATUS   ROLES           AGE   VERSION
model-node-1          Ready    control-plane   143d  v1.35.2-gke.300
NAME            CLUSTER_ROLE   HYBRID_AGENTS_PLATFORM
agents-cluster  agents         enabled
gateway-cluster gateway-tools  enabled
model-cluster   models
```

[Cloud Console Verification] In the Google Cloud console, open **Kubernetes
Engine > Clusters**
(`https://console.cloud.google.com/kubernetes/list?project=${PROJECT_ID}`).
Confirm that all three clusters appear registered in the project fleet with
healthy status and carry their `cluster-role` and `hybrid-agents-platform`
membership labels.

## Step 1: Configure secrets and the tiered internal PKI

The gateway-and-tool cluster holds the root CA key; the agent cluster gets an
intermediate CA through Secret Manager and External Secrets Operator (ESO); the
model cluster gets a static TLS `Secret`.

### Verify the system-managed cert-manager

- [Workstation] Confirm the cert-manager image version on both clusters. Do not
  install upstream cert-manager; it conflicts with the system-managed one
  ([Install cert-manager](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/install-cert-manager)).

```bash
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  kubectl --context="${CTX}" get deploy -n cert-manager \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
done
```

Confirm that every image tag is `v1.21.2-gke.0` or later. Ignore the
`app.kubernetes.io/version` label, which still reads `v1.19.1`.

[Cloud Console Verification] In the Google Cloud console, inspect the
`cert-manager` Deployments and container image tags under **Kubernetes Engine >
Workloads**
(`https://console.cloud.google.com/kubernetes/workload?project=${PROJECT_ID}`),
filtered by namespace `cert-manager`.

<!-- prettier-ignore -->
> [!WARNING]
> cert-manager 1.18 and later default `privateKey.rotationPolicy` to `Always`.
> Every CA `Certificate` in this guide sets `rotationPolicy: Never`, and Step 2
> checks the Apigee `apigee-ca` certificate.

### Install External Secrets Operator

- [Workstation] Install ESO 2.14.0 on the agent and gateway-and-tool clusters
  over Connect Gateway (first stage of the solution Helm pipeline).

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --version 2.14.0 --namespace external-secrets --create-namespace \
    --kube-context="${CTX}" --set installCRDs=true \
    --set serviceAccount.name=eso-controller-sa --atomic --timeout 5m
done
```

- [Workstation] Create one keyless `ClusterSecretStore` per cluster. ESO
  exchanges its projected token through fleet WIF; no Google service account or
  key is involved
  ([Sync Secret Manager secrets to Kubernetes](https://docs.cloud.google.com/secret-manager/docs/sync-k8-secrets)).

```bash
for CLUSTER in "${AGENTS_CLUSTER}" "${GATEWAY_CLUSTER}"; do
cat << EOF > "${SOLUTION_HOME}/css-${CLUSTER}.yaml" && echo "Successfully created." || echo "Failed to create!"
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: gcp-secret-manager
spec:
  provider:
    gcpsm:
      projectID: ${PROJECT_ID}
      auth:
        workloadIdentityFederation:
          audience: "identitynamespace:${FLEET_POOL}:https://gkehub.googleapis.com/projects/${PROJECT_ID}/locations/global/memberships/${CLUSTER}"
          serviceAccountRef:
            name: eso-controller-sa
            namespace: external-secrets
            audiences:
              - ${FLEET_POOL}
EOF
  kubectl --context="connectgateway_${PROJECT_ID}_global_${CLUSTER}" apply -f "${SOLUTION_HOME}/css-${CLUSTER}.yaml"
done
```

<!-- prettier-ignore -->
> [!TIP]
> All clusters share one fleet WIF pool, so equal namespace and service account
> names map to one principal; name each cluster's ESO service account distinctly
> for per-cluster isolation.

**Verify:**
`kubectl --context="${CTX_GATEWAY}" get clustersecretstore gcp-secret-manager`
reports `STATUS` `Valid` and `READY` `True` on both clusters.

[Cloud Console Verification] In the Google Cloud console, open **Kubernetes
Engine > Workloads**
(`https://console.cloud.google.com/kubernetes/workload?project=${PROJECT_ID}`)
and filter by namespace `external-secrets`. Confirm that the ESO controller
Deployments are healthy on both clusters. The `ClusterSecretStore` resource is a
third-party CRD that might not appear in **Object Browser**, so check its
`Valid` status with `kubectl`.

### Create the shared root CA and the tier certificates

- [Workstation] Create the root CA, its `ClusterIssuer`, the agent-tier
  intermediate CA, and the model-tier ingress certificate on the
  gateway-and-tool cluster.

```bash
cat << EOF > "${SOLUTION_HOME}/gateway-pki.yaml" && echo "Successfully created." || echo "Failed to create!"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hybrid-agents-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: hybrid-agents-internal-root-ca
  duration: 87600h
  renewBefore: 8760h
  secretName: hybrid-agents-root-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Never
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: hybrid-agents-ca
spec:
  ca:
    secretName: hybrid-agents-root-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hybrid-agents-c1-intermediate-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: hybrid-agents-c1-intermediate-ca
  duration: 26280h
  renewBefore: 4380h
  secretName: hybrid-agents-c1-intermediate-ca-secret
  usages: ["cert sign", "crl sign", "digital signature"]
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Never
  issuerRef:
    name: hybrid-agents-ca
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: model-tier-ingress
  namespace: cert-manager
spec:
  secretName: model-tier-ingress-tls
  duration: 8760h
  renewBefore: 720h
  commonName: ${VLLM_FQDN}
  dnsNames: ["${VLLM_FQDN}"]
  ipAddresses: ["${MODEL_INGRESS_VIP}"]
  usages: ["server auth", "digital signature", "key encipherment"]
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Never
  issuerRef:
    name: hybrid-agents-ca
    kind: ClusterIssuer
EOF
kubectl --context="${CTX_GATEWAY}" apply -f "${SOLUTION_HOME}/gateway-pki.yaml"
kubectl --context="${CTX_GATEWAY}" wait --for=condition=Ready -n cert-manager --timeout=120s \
  certificate/hybrid-agents-root-ca certificate/hybrid-agents-c1-intermediate-ca certificate/model-tier-ingress
```

- [Workstation] Publish only the intermediate key pair and the root certificate
  to Secret Manager
  ([add a secret version](https://docs.cloud.google.com/secret-manager/docs/add-secret-version)),
  readable by the ESO principal alone. The root CA key never leaves the
  gateway-and-tool cluster.

```bash
mkdir -p "${WORK}" && chmod 700 "${WORK}"
kubectl --context="${CTX_GATEWAY}" -n cert-manager get secret hybrid-agents-c1-intermediate-ca-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${WORK}/int.crt"
kubectl --context="${CTX_GATEWAY}" -n cert-manager get secret hybrid-agents-c1-intermediate-ca-secret \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "${WORK}/int.key"
kubectl --context="${CTX_GATEWAY}" -n cert-manager get secret hybrid-agents-root-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "${SOLUTION_HOME}/hybrid-agents-root-ca.crt"
cat "${WORK}/int.crt" "${SOLUTION_HOME}/hybrid-agents-root-ca.crt" > "${WORK}/chain.crt"
jq -n --rawfile chain "${WORK}/chain.crt" --rawfile key "${WORK}/int.key" \
  --rawfile root "${SOLUTION_HOME}/hybrid-agents-root-ca.crt" \
  '{tls_crt_chain: $chain, tls_key: $key, root_ca_crt: $root}' > "${WORK}/payload.json"
gcloud secrets create hybrid-agents-c1-intermediate-ca --replication-policy=automatic --project="${PROJECT_ID}"
gcloud secrets versions add hybrid-agents-c1-intermediate-ca --data-file="${WORK}/payload.json" --project="${PROJECT_ID}"
gcloud secrets add-iam-policy-binding hybrid-agents-c1-intermediate-ca \
  --member="${ESO_PRINCIPAL}" --role=roles/secretmanager.secretAccessor --project="${PROJECT_ID}"
shred -u "${WORK}/int.key" "${WORK}/payload.json"
```

- [Workstation] Create the `agent-workloads` namespace (Pod Security Standard
  `restricted`), the intermediate `ClusterIssuer`, and the Envoy certificates on
  the agent cluster. The platform Fleet package adopts the namespace in Step 7.

```bash
cat << EOF > "${SOLUTION_HOME}/agents-pki.yaml" && echo "Successfully created." || echo "Failed to create!"
apiVersion: v1
kind: Namespace
metadata:
  name: agent-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hybrid-agents-c1-intermediate-ca
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: gcp-secret-manager}
  target:
    name: hybrid-agents-c1-intermediate-ca-secret
    creationPolicy: Owner
    template:
      type: kubernetes.io/tls
      data:
        tls.crt: "{{ .tls_crt_chain }}"
        tls.key: "{{ .tls_key }}"
        ca.crt: "{{ .root_ca_crt }}"
  data:
    - secretKey: tls_crt_chain
      remoteRef: {key: hybrid-agents-c1-intermediate-ca, property: tls_crt_chain}
    - secretKey: tls_key
      remoteRef: {key: hybrid-agents-c1-intermediate-ca, property: tls_key}
    - secretKey: root_ca_crt
      remoteRef: {key: hybrid-agents-c1-intermediate-ca, property: root_ca_crt}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hybrid-agents-root-ca-bundle
  namespace: agent-workloads
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: gcp-secret-manager}
  target:
    name: hybrid-agents-root-ca-bundle
  data:
    - secretKey: ca.crt
      remoteRef: {key: hybrid-agents-c1-intermediate-ca, property: root_ca_crt}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: hybrid-agents-c1-ca
spec:
  ca:
    secretName: hybrid-agents-c1-intermediate-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agent-envoy-ingress-tls
  namespace: agent-workloads
spec:
  secretName: agent-envoy-ingress-tls
  duration: 2160h
  renewBefore: 360h
  commonName: ${AGENTS_INGRESS_FQDN}
  dnsNames: ["${AGENTS_INGRESS_FQDN}", "agent-ingress-envoy.agent-workloads.svc.cluster.local"]
  ipAddresses: ["${AGENTS_INGRESS_VIP}"]
  usages: ["server auth", "digital signature", "key encipherment"]
  privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}
  issuerRef: {name: hybrid-agents-c1-ca, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agent-envoy-egress-client-tls
  namespace: agent-workloads
spec:
  secretName: agent-envoy-egress-client-tls
  duration: 2160h
  renewBefore: 360h
  commonName: agent-egress-envoy.agent-workloads.hybrid-agents.internal
  dnsNames: ["agent-egress-envoy.agent-workloads.hybrid-agents.internal"]
  usages: ["client auth", "digital signature", "key encipherment"]
  privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}
  issuerRef: {name: hybrid-agents-c1-ca, kind: ClusterIssuer}
EOF
kubectl --context="${CTX_AGENTS}" apply -f "${SOLUTION_HOME}/agents-pki.yaml"
kubectl --context="${CTX_AGENTS}" wait --for=condition=Ready --timeout=120s \
  -n agent-workloads certificate/agent-envoy-ingress-tls certificate/agent-envoy-egress-client-tls
```

**Verify:** the leaf `tls.crt` holds two PEM certificates (leaf and
intermediate) and the trust bundle holds one (root only).

```bash
kubectl --context="${CTX_AGENTS}" -n agent-workloads get secret agent-envoy-ingress-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | grep -c 'BEGIN CERTIFICATE'
kubectl --context="${CTX_AGENTS}" -n agent-workloads get secret hybrid-agents-root-ca-bundle \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | grep -c 'BEGIN CERTIFICATE'
```

Confirm that the commands return `2` and `1`.

[Cloud Console Verification] In the Google Cloud console, confirm that
`hybrid-agents-c1-intermediate-ca` has an enabled version and grants
`roles/secretmanager.secretAccessor` only to `ESO_PRINCIPAL` on the **Security >
Secret Manager** page
(`https://console.cloud.google.com/security/secret-manager?project=${PROJECT_ID}`).
Confirm that `agent-envoy-ingress-tls` and `hybrid-agents-root-ca-bundle` appear
under **Kubernetes Engine > Secrets & ConfigMaps**
(`https://console.cloud.google.com/kubernetes/config?project=${PROJECT_ID}`) in
namespace `agent-workloads`.

### Expose the model tier over HTTPS

- [Workstation] Copy the model-tier certificate into `gke-system` on the model
  cluster and front the unchanged vLLM `ClusterIP` Service with the
  [bundled ingress](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/create-service-ingress).
  The `Secret` must live in `gke-system`, where the bundled ingress runs; vLLM
  is not restarted.

```bash
kubectl --context="${CTX_GATEWAY}" -n cert-manager get secret model-tier-ingress-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${WORK}/vllm.crt"
kubectl --context="${CTX_GATEWAY}" -n cert-manager get secret model-tier-ingress-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "${WORK}/vllm.key"
kubectl create secret tls vllm-ingress-tls -n gke-system \
  --cert="${WORK}/vllm.crt" --key="${WORK}/vllm.key" --dry-run=client -o yaml \
  | kubectl --context="${CTX_MODEL}" apply -f -
shred -u "${WORK}/vllm.key"
cat << EOF > "${SOLUTION_HOME}/vllm-https-ingress.yaml" && echo "Successfully created." || echo "Failed to create!"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-https-ingress
  namespace: ${VLLM_NAMESPACE}
spec:
  tls:
    - secretName: vllm-ingress-tls
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${VLLM_SERVICE}
                port:
                  number: 8000
EOF
kubectl --context="${CTX_MODEL}" apply -f "${SOLUTION_HOME}/vllm-https-ingress.yaml"
```

**Verify:**
`curl -sS --cacert "${SOLUTION_HOME}/hybrid-agents-root-ca.crt" "https://${VLLM_FQDN}/v1/models"`
returns the model list with strict TLS verification. Probe the URL rather than
the `Ingress` status: the bundled ingress leaves `.status.loadBalancer` empty.

[Cloud Console Verification] In the Google Cloud console, confirm that
`vllm-https-ingress` exists under **Kubernetes Engine > Services & Ingress**
(`https://console.cloud.google.com/kubernetes/discovery?project=${PROJECT_ID}`).
Confirm that `vllm-ingress-tls` exists in namespace `gke-system` under
**Kubernetes Engine > Secrets & ConfigMaps**
(`https://console.cloud.google.com/kubernetes/config?project=${PROJECT_ID}`).

## Step 2: Install Apigee hybrid 1.17.3 through the Connect Gateway Helm pipeline

### Prepare the Apigee organization and the runtime service account

- [Workstation] Create the hybrid organization (`analyticsRegion`
  `us-central1`), environment `hybrid-agents-env` (`type: BASE`,
  `deploymentProxyType: PROXY`), and environment group `hybrid-agents-envgroup`
  with hostname `api.hybrid-agents.internal`, and attach the environment, per
  [Create an organization](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/precog-provision)
  and
  [Add an environment](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/precog-add-environment).
- [Workstation] Create the non-prod runtime service account per
  [Create service accounts](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/create-service-account),
  authorize it for synchronization per
  [Configure permissions](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/precog-permissions),
  and add the solution roles.

```bash
for ROLE in roles/serviceusage.serviceUsageViewer roles/aiplatform.user roles/modelarmor.user \
  roles/mcp.toolUser roles/bigquery.jobUser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${APIGEE_SA}" \
    --role="${ROLE}" --condition=None
done
gcloud iam service-accounts add-iam-policy-binding "${APIGEE_SA}" \
  --member="serviceAccount:${APIGEE_SA}" --role=roles/iam.serviceAccountTokenCreator --project="${PROJECT_ID}"
```

### Enable keyless Apigee authentication through fleet WIF

The solution uses the fleet WIF pool for
[Apigee Workload Identity Federation](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/enable-workload-identity-federation):
no uploaded cluster JSON Web Key Set (JWKS), and it works where
`constraints/iam.workloadIdentityPoolProviders` blocks new OIDC providers.

- [Workstation] Allow every Apigee service account in the `apigee` namespace to
  impersonate the runtime service account, and store the keyless credential
  configuration as `Secret/apigee-non-prod-wif-secret`.

```bash
gcloud iam service-accounts add-iam-policy-binding "${APIGEE_SA}" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${FLEET_POOL}/namespace/apigee" \
  --project="${PROJECT_ID}"
mkdir -p "${SOLUTION_HOME}/apigee"
jq -n --arg aud "identitynamespace:${FLEET_POOL}:https://gkehub.googleapis.com/projects/${PROJECT_ID}/locations/global/memberships/${GATEWAY_CLUSTER}" \
  --arg imp "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${APIGEE_SA}:generateAccessToken" \
  '{universe_domain: "googleapis.com", type: "external_account", audience: $aud,
    subject_token_type: "urn:ietf:params:oauth:token-type:jwt", token_url: "https://sts.googleapis.com/v1/token",
    credential_source: {file: "/var/run/service-account/token", format: {type: "text"}},
    service_account_impersonation_url: $imp}' > "${SOLUTION_HOME}/apigee/wif-cred-config.json"
kubectl --context="${CTX_GATEWAY}" create namespace apigee
kubectl --context="${CTX_GATEWAY}" -n apigee create secret generic apigee-non-prod-wif-secret \
  --from-file=client_secret.json="${SOLUTION_HOME}/apigee/wif-cred-config.json"
```

<!-- prettier-ignore -->
> [!WARNING]
> The two audiences differ. `client_secret.json` carries
> `identitynamespace:...`, while `gcp.federatedWorkloadIdentity.audience` in the
> overrides is `PROJECT_ID.svc.id.goog`. Using the `identitynamespace:` string
> in the overrides returns HTTP 400 from STS.

### Prepare the gateway nodes, storage, and certificates

- [Workstation] Label the gateway nodes for both Apigee pools, make
  `local-shared` the default `StorageClass` (validation footprint), and issue
  the Apigee ingress and southbound client certificates.

```bash
for NODE in $(kubectl --context="${CTX_GATEWAY}" get nodes -o name); do
  kubectl --context="${CTX_GATEWAY}" label "${NODE}" --overwrite \
    apigee.cloud.google.com/apigee-data=true apigee.cloud.google.com/apigee-runtime=true
done
kubectl --context="${CTX_GATEWAY}" patch storageclass local-shared \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
cat << EOF > "${SOLUTION_HOME}/apigee/apigee-certs.yaml" && echo "Successfully created." || echo "Failed to create!"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apigee-ingress-tls
  namespace: apigee
spec:
  secretName: apigee-ingress-tls
  duration: 2160h
  renewBefore: 360h
  commonName: ${GATEWAY_FQDN}
  dnsNames: ["${GATEWAY_FQDN}"]
  ipAddresses: ["${APIGEE_INGRESS_VIP}"]
  usages: ["server auth", "digital signature", "key encipherment"]
  privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}
  issuerRef: {name: hybrid-agents-ca, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apigee-envoy-client-tls
  namespace: apigee
spec:
  secretName: apigee-envoy-client-tls
  duration: 2160h
  renewBefore: 360h
  commonName: apigee-runtime.apigee.hybrid-agents.internal
  dnsNames: ["apigee-runtime.apigee.hybrid-agents.internal"]
  usages: ["client auth", "digital signature", "key encipherment"]
  privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}
  issuerRef: {name: hybrid-agents-ca, kind: ClusterIssuer}
EOF
kubectl --context="${CTX_GATEWAY}" apply -f "${SOLUTION_HOME}/apigee/apigee-certs.yaml"
```

<!-- prettier-ignore -->
> [!NOTE]
> The agent mTLS ingress accepts only the client SAN
> `apigee-runtime.apigee.hybrid-agents.internal`, which the Fleet package
> hard-codes.

<!-- prettier-ignore -->
> [!TIP]
> For production, use three `apigee-data` and three `apigee-runtime` nodes,
> `cassandra.replicaCount: 3`, and dedicated SSD or NVMe devices ([Cassandra for
> production](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/cassandra-production)).
> Keep NTP (UDP 123) synchronized, p99 Cassandra latency under 100 ms, and TCP
> 7001 open between Cassandra nodes. The Cassandra `StorageClass` is fixed after
> installation.

### Write the solution overrides

- [Workstation] Write `overrides.yaml` with the solution values
  ([configuration property reference](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/config-prop-ref)).

```bash
cat << EOF > "${SOLUTION_HOME}/apigee/overrides.yaml" && echo "Successfully created." || echo "Failed to create!"
instanceID: "${GATEWAY_CLUSTER}-${REGION}"
namespace: "apigee"
org: "${APIGEE_ORG}"
k8sCluster:
  name: "${GATEWAY_CLUSTER}"
  region: "${REGION}"
gcp:
  projectID: "${PROJECT_ID}"
  region: "${REGION}"
  workloadIdentity:
    enabled: false
  federatedWorkloadIdentity:
    enabled: true
    type: "kubernetes"
    audience: "${FLEET_POOL}"
    credentialSourceFile: "/var/run/service-account/token"
    tokenExpiration: 3600
nodeSelector:
  requiredForScheduling: true
  apigeeData: {key: "apigee.cloud.google.com/apigee-data", value: "true"}
  apigeeRuntime: {key: "apigee.cloud.google.com/apigee-runtime", value: "true"}
enhanceProxyLimits: true
enableMcpServer: true
cassandra:
  hostNetwork: false
  replicaCount: 1
  storage:
    storageclass: "local-shared"
    storageSize: "100Gi"
ingressGateways:
  - name: "hybrid-agents-ig"
    replicaCountMin: 1
    replicaCountMax: 2
    svcType: "LoadBalancer"
    svcLoadBalancerIP: "${APIGEE_INGRESS_VIP}"
virtualhosts:
  - name: "${APIGEE_ENVGROUP}"
    selector: {app: "apigee-ingressgateway", ingress_name: "hybrid-agents-ig"}
    minTLSProtocolVersion: "1.2"
    requestTimeout: 300
    sslSecret: "apigee-ingress-tls"
envs:
  - name: "${APIGEE_ENV}"
    serviceAccountSecretRefs:
      synchronizer: "apigee-non-prod-wif-secret"
      runtime: "apigee-non-prod-wif-secret"
guardrails: {serviceAccountRef: "apigee-non-prod-wif-secret"}
mart: {serviceAccountRef: "apigee-non-prod-wif-secret"}
connectAgent: {serviceAccountRef: "apigee-non-prod-wif-secret"}
metrics: {serviceAccountRef: "apigee-non-prod-wif-secret"}
watcher: {serviceAccountRef: "apigee-non-prod-wif-secret"}
mcpServer: {serviceAccountRef: "apigee-non-prod-wif-secret"}
logger:
  enabled: false
EOF
```

The solution-specific choices in this file are the following:

- `enhanceProxyLimits: true`: requires a paid 2024 subscription plan
  ([enhanced proxy limits](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/enhanced-proxy-limits));
  omit it or set it to `false` on a 60-day evaluation organization.
- `logger.enabled: false`: `apigee-logger` does not support WIF
  ([known issue 341099433](https://docs.cloud.google.com/apigee/docs/release/known-issues));
  the cluster log forwarder still ships Apigee logs.
- `enableMcpServer: true` with an explicit `mcpServer.serviceAccountRef`:
  without it, `apigee-org` fails to render.
- `cassandra.storage.storageclass` is lowercase; `storageClass` is silently
  ignored.
- `minTLSProtocolVersion: "1.2"`: `"1.3"` breaks built-in `/mcp` `tools/call`
  (Troubleshooting); agent egress still pins TLS 1.3.
- `requestTimeout: 300` and the companion repository proxy bundles'
  `io.timeout.millis` (120000 on model targets) leave room for long streamed
  generations; size every proxy and ingress idle timeout on the path for your
  longest generation
  ([Server-sent events](https://docs.cloud.google.com/apigee/docs/api-platform/develop/server-sent-events)).

### Install the charts

- [Workstation] Pull the eight 1.17.3 charts per
  [Install the hybrid runtime](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/install-download-charts),
  apply the CRDs, and install the charts in order with `--atomic` over Connect
  Gateway. The charts' guardrail hooks run on every install
  ([guardrails](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/guardrails)).

```bash
CHARTS="${SOLUTION_HOME}/apigee/charts"
OVR="${SOLUTION_HOME}/apigee/overrides.yaml"
mkdir -p "${CHARTS}"
for C in apigee-operator apigee-datastore apigee-telemetry apigee-redis apigee-ingress-manager \
  apigee-org apigee-env apigee-virtualhost; do
  helm pull "oci://us-docker.pkg.dev/apigee-release/apigee-hybrid-helm-charts/${C}" \
    --version 1.17.3 --untar --untardir "${CHARTS}"
done
kubectl --context="${CTX_GATEWAY}" apply --server-side --force-conflicts -k "${CHARTS}/apigee-operator/etc/crds/default/"
H=(helm --kube-context="${CTX_GATEWAY}" upgrade --install --namespace apigee --atomic --timeout 15m -f "${OVR}")
"${H[@]}" operator "${CHARTS}/apigee-operator"
kubectl --context="${CTX_GATEWAY}" get certificate apigee-ca -n cert-manager \
  -o jsonpath='{.spec.privateKey.rotationPolicy}{"\n"}'
"${H[@]}" datastore "${CHARTS}/apigee-datastore"
kubectl --context="${CTX_GATEWAY}" wait --for=jsonpath='{.status.state}'=running apigeedatastore/default -n apigee --timeout=10m
"${H[@]}" telemetry "${CHARTS}/apigee-telemetry"
"${H[@]}" redis "${CHARTS}/apigee-redis"
"${H[@]}" ingress-manager "${CHARTS}/apigee-ingress-manager"
"${H[@]}" "${APIGEE_ORG}" "${CHARTS}/apigee-org"
kubectl --context="${CTX_GATEWAY}" wait --for=jsonpath='{.status.state}'=running apigeeorganization --all -n apigee --timeout=15m
"${H[@]}" "${APIGEE_ENV}" "${CHARTS}/apigee-env" --set env="${APIGEE_ENV}"
kubectl --context="${CTX_GATEWAY}" wait --for=jsonpath='{.status.state}'=running apigeeenvironment --all -n apigee --timeout=15m
"${H[@]}" "${APIGEE_ENVGROUP}" "${CHARTS}/apigee-virtualhost" --set envgroup="${APIGEE_ENVGROUP}"
```

<!-- prettier-ignore -->
> [!IMPORTANT]
> The `apigee-ca` check after `operator` must print `Never` ([known issue
> 465834046](https://docs.cloud.google.com/apigee/docs/release/known-issues#465834046)).
> If it does not, patch `spec.privateKey.rotationPolicy` to `Never` before you
> continue. Always pass `--set envgroup=` when you upgrade `apigee-virtualhost`.

**Verify:** all Apigee custom resources report `running`, including the
`ApigeeRoute` that the watcher creates for the environment group
(`ApigeeRouteConfig` has no status).

```bash
kubectl --context="${CTX_GATEWAY}" get apigeedatastore,apigeetelemetry,apigeeredis,apigeeorganization,apigeeenvironment -n apigee
kubectl --context="${CTX_GATEWAY}" get apigeeroute -n apigee -l envGroupId="${APIGEE_ENVGROUP}" \
  -o jsonpath='{.items[0].status.state}{"\n"}'
```

The output is similar to the following:

```text
NAME                                    STATE     AGE
apigeedatastore.apigee.cloud.google.com/default         running   12m
apigeetelemetry.apigee.cloud.google.com/apigee-telemetry running   10m
apigeeredis.apigee.cloud.google.com/default             running   9m
apigeeorganization.apigee.cloud.google.com/example-org   running   5m
apigeeenvironment.apigee.cloud.google.com/example-org-hybrid-agents-env running 2m
running
```

[Cloud Console Verification] In the Google Cloud console, open **Kubernetes
Engine > Workloads**
(`https://console.cloud.google.com/kubernetes/workload?project=${PROJECT_ID}`,
filtered by namespace `apigee`) to confirm the Apigee hybrid pods are healthy.
Open **Apigee > Management > Environments** to confirm `hybrid-agents-env` is
attached to `hybrid-agents-envgroup`. Apigee custom resource `running` states
stay a `kubectl` check.

## Step 3: Create the Apigee TLS keystores and references

The
[SUG](user-guide.md#step-1-prerequisites-model-armor-orchestrator-secret-trigger-and-agent-images)
configures the Apigee AI Gateway and sample MCP prerequisites. This covers the
Model Armor template, Cloud Storage and BigQuery IAM bindings, proxies, API
products, model routing, LLM token quotas, and Model Armor wiring. It also sets
up key value maps, `TargetServer` objects, and developer apps. These definitions
come from [`apigee/`](../apigee) in the companion repository. Create the
environment TLS keystores and references first so that
`apigee/environments/env-config.json` can reference them by name.

- [Workstation] Export the root CA and the Apigee client certificate.

```bash
cp "${SOLUTION_HOME}/hybrid-agents-root-ca.crt" "${SOLUTION_HOME}/apigee/root-ca.crt"
kubectl --context="${CTX_GATEWAY}" -n apigee get secret apigee-envoy-client-tls -o json \
  | jq -r '.data["tls.crt"]' | base64 -d > "${WORK}/client.crt"
kubectl --context="${CTX_GATEWAY}" -n apigee get secret apigee-envoy-client-tls -o json \
  | jq -r '.data["tls.key"]' | base64 -d > "${WORK}/client.key"
read -r -s -p "Ephemeral PKCS#12 passphrase: " P12_PASS; echo; export P12_PASS
openssl pkcs12 -export -in "${WORK}/client.crt" -inkey "${WORK}/client.key" \
  -out "${WORK}/envoy-client.p12" -passout env:P12_PASS
shred -u "${WORK}/client.key"
```

- [Workstation] In `hybrid-agents-env`, create the keystores and references in
  the following table per
  [Options for configuring TLS](https://docs.cloud.google.com/apigee/docs/api-platform/system-administration/options-configuring-tls)
  and
  [Working with references](https://docs.cloud.google.com/apigee/docs/api-platform/system-administration/working-references).
  Then run `rm -rf "${WORK}"` and `unset P12_PASS`.

<!-- mdformat off -->

| Keystore                       | Alias and content                       | Reference                          | Used by                                                                        |
| :----------------------------- | :-------------------------------------- | :--------------------------------- | :----------------------------------------------------------------------------- |
| `hybrid-agents-truststore`     | `hybrid-agents-root-ca` (`root-ca.crt`) | `hybrid-agents-truststore-ref`     | All southbound `TargetServer` objects (agent ingress, MCP Toolbox, local vLLM) |
| `apigee-envoy-client-keystore` | `envoy-client` (`envoy-client.p12`)     | `apigee-envoy-client-keystore-ref` | `gdcso-agent-ingress` mTLS client authentication                               |

<!-- mdformat on -->

[Cloud Console Verification] In the Google Cloud console, go to **Apigee >
Management > Environments** and select `hybrid-agents-env`. Confirm both
keystores (with aliases `hybrid-agents-root-ca` and `envoy-client`) and both
entries on the **References** tab (`hybrid-agents-truststore-ref` and
`apigee-envoy-client-keystore-ref`).

To create the `hybrid-agents-cloud-burst-armor` Model Armor template, grant
`APIGEE_SA` read access to `gs://${MCP_BUCKET}` and BigQuery datasets, and
deploy the Apigee AI Gateway proxies, products, and policies, see the
[SUG](user-guide.md#step-1-prerequisites-model-armor-orchestrator-secret-trigger-and-agent-images).

## Step 4: Prepare the MCP Toolbox and observability prerequisites

Step 7 deploys MCP Toolbox and the OpenTelemetry Collector on the clusters
through `FleetPackage/hybridcloud-agents-platform`, and the
[SUG](user-guide.md#step-1-configure-the-ai-gateway-and-onboard-the-first-agent-v110)
later adds `PodMonitoring` objects through `FleetPackage/hybridcloud-agents`.
Create their platform dependencies first, because Config Sync cannot finish a
rollout whose objects reference missing pieces:

- The MCP Toolbox `ExternalSecret` stays unsynced, and the pods do not start,
  until its Secret Manager secret exists.
- The agent bundle's `PodMonitoring` objects fail to apply until the Managed
  Service for Prometheus CRDs are installed.
- The collector cannot export until its fleet WIF principal holds the telemetry
  roles.

- [Workstation] Store the MCP Toolbox database credentials in Secret Manager,
  readable by the ESO principal only
  ([manage access to secrets](https://docs.cloud.google.com/secret-manager/docs/manage-access-to-secrets)).

```bash
gcloud secrets create "${MCP_DB_SECRET}" --replication-policy=automatic --project="${PROJECT_ID}"
gcloud secrets versions add "${MCP_DB_SECRET}" --data-file="${MCP_DB_CREDS_FILE}" --project="${PROJECT_ID}"
gcloud secrets add-iam-policy-binding "${MCP_DB_SECRET}" --member="${ESO_PRINCIPAL}" \
  --role=roles/secretmanager.secretAccessor --project="${PROJECT_ID}"
shred -u "${MCP_DB_CREDS_FILE}"
```

- [Workstation] Enable
  [application logging and Managed Service for Prometheus](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)
  on the agent and gateway-and-tool clusters; on 1.36,
  `Cluster.spec.clusterOperations.enableApplication` has no effect.

```bash
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  kubectl --context="${CTX}" patch stackdriver stackdriver -n kube-system --type=merge \
    -p '{"spec":{"enableGMPForApplications":true,"enableCloudLoggingForApplications":true}}'
done
```

- [Workstation] Grant the OpenTelemetry Collector fleet WIF principal its
  telemetry roles.

```bash
for ROLE in roles/cloudtrace.agent roles/monitoring.metricWriter roles/logging.logWriter roles/telemetry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${OTEL_PRINCIPAL}" --role="${ROLE}" --condition=None
done
```

**Verify:**
`kubectl --context="${CTX_AGENTS}" get crd podmonitorings.monitoring.googleapis.com`
returns the CRD on both clusters.

[Cloud Console Verification] In the Google Cloud console, open **Security >
Secret Manager**
(`https://console.cloud.google.com/security/secret-manager?project=${PROJECT_ID}`)
to confirm `${MCP_DB_SECRET}` has an enabled version and grants
`roles/secretmanager.secretAccessor` only to `ESO_PRINCIPAL`. Confirm the
`PodMonitoring` CRD with `kubectl`.

<!-- prettier-ignore -->
> [!NOTE]
> For database connectivity, confirm that your external PostgreSQL + `pgvector`
> server accepts TCP 5432 from the gateway-and-tool node IPs (pod egress is
> SNATed). Also confirm that it presents a server certificate chained to
> `ClusterIssuer/hybrid-agents-ca` with `YOUR_PGVECTOR_HOST` in its SANs.
> Alternatively, deploy the optional
> [`tests/data-tier/`](../tests/data-tier/README.md) sample in the companion
> repository on a separate test cluster. Step 7 deploys the
> `gateway-tools-platform` variant (`mcp-toolbox` and `otel-collector`) and
> verifies both workloads.

## Step 5: Set up the Cloud Build release pipeline

Each application release tag pushed in the
[SUG](user-guide.md#publish-a-release) runs
[`registry/cloudbuild-register.yaml`](../registry/cloudbuild-register.yaml),
which makes Git the source of truth for Apigee and Agent Registry. Its four
steps run in order:

- `Step #0` `validate-registry-manifests` (`validate-manifests.sh`): checks the
  manifests and the tag before any change. It rejects duplicate card URLs or
  agent identities and tags that are not `vX.Y.Z`.
- `Step #1` `sync-apigee-identity`: one developer app per `agent.yaml`, its API
  products and quotas, a consumer key written to the agent's secret, and the
  `agent-jwt-subjects` KVM entry.
- `Step #2` `sync-apigee-proxies`: imports and deploys only the proxy bundles
  whose content changed, and reconciles `TargetServer` objects and the property
  set.
- `Step #3` `sync-agent-registry`: creates, updates, or prunes the A2A cards and
  MCP servers that the pipeline manages.

If `Step #0` fails, nothing changed: read its error, fix the manifest in Git,
and push a new tag. If a later step fails, the run is not atomic, but every step
is idempotent, so fixing the cause and pushing a new tag converges. Each sync
step checks its inputs first: if a Cloud Build substitution is empty or still
contains a `YOUR_*` placeholder, the step stops before calling any Apigee or
Agent Registry API.

- [Workstation] Create a private GitOps repository from the companion
  repository, so that it has your own commit history and release tags (GitHub in
  this example). The repository keeps the companion repository's folder layout,
  so the `FleetPackage` `path` below and the SUG trigger `--build-config` work
  unchanged.

```bash
gh repo create "${GITOPS_OWNER}/${GITOPS_REPO}" --private
git clone --branch main https://github.com/GoogleCloudPlatform/gdc-solutions.git "${REPO_DIR}"
git -C "${REPO_DIR}" remote set-url origin "https://github.com/${GITOPS_OWNER}/${GITOPS_REPO}.git"
git -C "${REPO_DIR}" push origin HEAD:main
```

<!-- prettier-ignore -->
> [!WARNING]
> Keep the GitOps repository private. After you customize it, the bundle
> contains your project ID, cluster names, and internal addresses. These values
> aren't credentials, but you shouldn't publish them.

- [Workstation] Link the repository to Cloud Build as a
  [2nd-gen repository](https://docs.cloud.google.com/build/docs/automating-builds/github/connect-repo-github)
  in `GIT_CONNECTION`; its resource name is `GIT_REPOSITORY`. For GitLab, use
  the
  [GitLab connection](https://docs.cloud.google.com/build/docs/automating-builds/gitlab/connect-repo-gitlab)
  instead.
- [Workstation] Create the pipeline service account and grant its
  least-privilege roles.

```bash
gcloud iam service-accounts create "${REGISTRAR_SA%%@*}" --display-name="Hybrid agents release pipeline" \
  --project="${PROJECT_ID}"
for ROLE in roles/agentregistry.editor roles/apigee.apiAdminV2 roles/apigee.developerAdmin \
  roles/apigee.environmentAdmin roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${REGISTRAR_SA}" \
    --role="${ROLE}" --condition=None
done
gcloud iam service-accounts add-iam-policy-binding "${APIGEE_SA}" \
  --member="serviceAccount:${REGISTRAR_SA}" --role=roles/iam.serviceAccountUser --project="${PROJECT_ID}"
```

- [Workstation] Create the Artifact Registry Docker repository for agent images
  and grant the
  [Cloud Build service account](https://docs.cloud.google.com/build/docs/cloud-build-service-account)
  (`BUILD_SA`) writer access on that repository only. This uses the project
  default build service account unless you pass `--service-account` to
  `gcloud builds submit`.

```bash
gcloud artifacts repositories describe "${AR_REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "${AR_REPOSITORY}" --repository-format=docker --location="${REGION}" --project="${PROJECT_ID}"
gcloud artifacts repositories add-iam-policy-binding "${AR_REPOSITORY}" --location="${REGION}" \
  --member="serviceAccount:${BUILD_SA}" --role=roles/artifactregistry.writer --project="${PROJECT_ID}"
```

**Verify:** `REGISTRAR_SA` and `${AR_REPOSITORY}` exist, and the 2nd-gen
repository connection is linked.

```bash
gcloud iam service-accounts describe "${REGISTRAR_SA}" --project="${PROJECT_ID}" --format="value(email)"
gcloud artifacts repositories describe "${AR_REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)"
```

[Cloud Console Verification] In the Google Cloud console, open **Cloud Build >
Repositories (2nd gen)** (region `us-central1`) to confirm `${GIT_REPOSITORY}`
is linked under `${GIT_CONNECTION}`. Open **Artifact Registry > Repositories**
(region `us-central1`) to confirm `${AR_REPOSITORY}` exists with
`roles/artifactregistry.writer` granted to `BUILD_SA`. Confirm `REGISTRAR_SA`
under **IAM & Admin > Service Accounts**.

The `hybridcloud-agents-registry-sync` Cloud Build trigger is created in the
[SUG](user-guide.md#step-1-prerequisites-model-armor-orchestrator-secret-trigger-and-agent-images)
once the per-agent key secrets exist, together with building and mirroring the
sample agent images and deploying `FleetPackage/hybridcloud-agents`. Step 7
renders the Fleet package bundles and pushes the first release tag (`v1.0.0`) to
roll out `hybridcloud-agents-platform`.

## Companion repository layout and configuration

The companion repository under `software-only/bare-metal/hybridcloud-agents/`
contains all manifests, proxy bundles, agent sources, documentation, and
optional test suites referenced in this guide and the
[Solution User Guide (SUG)](user-guide.md).

### Repository layout

```text
hybridcloud-agents/
├── README.md
├── docs/
│   ├── images/
│   │   ├── agent-lifecycle-sequence.png
│   │   ├── agent-runtime-sequence.png
│   │   ├── hybridcloud-agents-architecture.png
│   │   └── mcp-registration-sequence.png
│   ├── reference-implementation.md
│   └── user-guide.md
├── agents/
│   ├── README.md
│   ├── adk-ops-orchestrator/
│   │   ├── Dockerfile
│   │   ├── app.py
│   │   └── requirements.txt
│   ├── adk-sovereign-agent/
│   │   ├── Dockerfile
│   │   ├── app.py
│   │   └── requirements.txt
│   └── cloudbuild-images.yaml
├── apigee/
│   ├── environments/
│   │   └── env-config.json
│   ├── products/
│   │   └── api-products.json
│   └── proxies/
│       ├── a2a-dispatch-v1/
│       ├── agent-dispatch-v1/
│       ├── gateway-catalog-v1/
│       ├── gemini-genai-v1/
│       ├── llm-router-v1/
│       ├── mcp-bigquery-v1/
│       ├── mcp-discovery-v1/
│       ├── mcp-storage-v1/
│       ├── mcp-toolbox-v1/
│       └── ops-agent-dispatch-v1/
├── fleet-package/
│   ├── configdelivery-rbac.yaml
│   ├── environments/
│   │   ├── agents/
│   │   │   └── manifests.yaml
│   │   ├── agents-platform/
│   │   │   └── manifests.yaml
│   │   └── gateway-tools-platform/
│   │       └── manifests.yaml
│   ├── fleetpackage-platform.yaml
│   ├── fleetpackage.yaml
│   ├── render.sh
│   └── src/
│       ├── base/
│       │   ├── agent-egress-envoy.yaml
│       │   ├── envoy-mtls-ingress-config.yaml
│       │   ├── kustomization.yaml
│       │   ├── network-policies.yaml
│       │   └── pod-monitoring.yaml
│       ├── components/
│       │   ├── agents/
│       │   │   ├── adk-ops-orchestrator/
│       │   │   │   ├── adk-ops-orchestrator.yaml
│       │   │   │   ├── external-secret.yaml
│       │   │   │   ├── kustomization.yaml
│       │   │   │   └── network-policy.yaml
│       │   │   └── adk-sovereign-agent/
│       │   │       ├── adk-sovereign-agent.yaml
│       │   │       ├── external-secret.yaml
│       │   │       ├── kustomization.yaml
│       │   │       └── network-policy.yaml
│       │   └── otel-collector/
│       │       ├── kustomization.yaml
│       │       └── otel-collector.yaml
│       └── overlays/
│           ├── agents/
│           │   └── kustomization.yaml
│           ├── agents-platform/
│           │   ├── agent-workloads-platform.yaml
│           │   └── kustomization.yaml
│           └── gateway-tools-platform/
│               ├── kustomization.yaml
│               └── mcp-toolbox.yaml
├── registry/
│   ├── agents/
│   │   └── .gitkeep
│   ├── available/
│   │   ├── agents/
│   │   │   ├── adk-ops-orchestrator/
│   │   │   │   └── agent.yaml
│   │   │   └── adk-sovereign-agent/
│   │   │       └── agent.yaml
│   │   └── mcp-servers/
│   │       ├── mcp-bigquery.yaml
│   │       ├── mcp-storage.yaml
│   │       └── mcp-toolbox.yaml
│   ├── cards/
│   │   ├── adk-ops-orchestrator.json
│   │   └── adk-sovereign-agent.json
│   ├── cloudbuild-register.yaml
│   ├── mcp-servers/
│   │   └── .gitkeep
│   ├── sync-agent-registry.sh
│   ├── sync-apigee-identity.sh
│   ├── sync-apigee-proxies.sh
│   └── validate-manifests.sh
└── tests/
    ├── a2a/
    │   ├── environments/
    │   │   └── agents/
    │   │       └── manifests.yaml
    │   ├── fleetpackage.yaml
    │   ├── render.sh
    │   └── src/
    │       ├── base/
    │       │   ├── a2a-bypass-probes.yaml
    │       │   ├── a2a-rogue-caller.yaml
    │       │   └── kustomization.yaml
    │       └── overlays/
    │           └── agents/
    │               └── kustomization.yaml
    ├── data-tier/
    │   ├── 00-namespace-and-pki.yaml
    │   ├── 01-postgres-pgvector.yaml
    │   ├── 02-network-policies.yaml
    │   └── README.md
    ├── model-tier/
    │   ├── README.md
    │   ├── gpu-pod-monitoring.yaml
    │   ├── vllm-deployment.yaml
    │   ├── vllm-https-ingress.yaml
    │   ├── vllm-pod-monitoring.yaml
    │   ├── vllm-pvc.yaml
    │   └── vllm-service.yaml
    └── verify/
        ├── README.md
        ├── agent_call.py
        ├── check_control_plane.py
        └── verify.sh
```

- [`agents/`](../agents/README.md) contains sanitized Python source code
  (`app.py`), `Dockerfile` definitions, pinned `requirements.txt` manifests
  (`google-adk==1.39.1`), and `cloudbuild-images.yaml` for building the
  `adk-sovereign-agent` and `adk-ops-orchestrator` container images.
- `apigee/` contains portable, config-as-code Apigee hybrid 1.17 proxy bundles
  (`proxies/`), base API product specifications (`products/api-products.json`),
  and environment configuration templates (`environments/env-config.json` for
  `TargetServers`, environment property sets, and KVM maps). All proxy bundles
  resolve backend hosts through `TargetServers`, environment settings through
  `propertyset.hybrid_agents_env.*`, and expected Kubernetes service account JWT
  subjects plus OIDC JWKS dynamically from the `agent-jwt-subjects` KVM.
- `fleet-package/` contains the two Google Cloud Config Delivery
  (`FleetPackage`) specifications, least-privilege `RootSync` RBAC manifest, DRY
  Kustomize sources (`src/base/`, shared `src/components/otel-collector/`, and
  `src/overlays/`), render script (`render.sh`), and rendered plain-KRM variant
  bundles (`environments/agents-platform/manifests.yaml`,
  `environments/gateway-tools-platform/manifests.yaml`, and
  `environments/agents/manifests.yaml`). **Deploy in strict order:**
  1. **PLATFORM first (`fleetpackage-platform.yaml`,
     `FleetPackage/hybridcloud-agents-platform`):** selects both the Agents and
     Gateway-and-Tools clusters via the shared membership label
     `hybrid-agents-platform=enabled` and expands
     `${membership.labels['cluster-role']}-platform` to deploy `agents-platform`
     (`Namespace/agent-workloads`, baseline `default-deny-all` and
     `allow-dns-egress` `NetworkPolicy` objects, and `otel-system` OpenTelemetry
     Collector) to `cluster-role=agents` and `gateway-tools-platform`
     (`mcp-tools` MCP Toolbox sample and `otel-system` OpenTelemetry Collector)
     to `cluster-role=gateway-tools`.
  2. **AGENTS second (`fleetpackage.yaml`, `FleetPackage/hybridcloud-agents`):**
     selects `cluster-role=agents` and deploys the `agents` variant rendered by
     `fleet-package/render.sh` from the active set in `registry/agents/`. It
     deploys the shared Envoy mTLS ingress and multi-listener egress proxies
     (idle baseline with zero agent listeners/routes when `registry/agents/` is
     empty) plus per-agent Kustomize components
     (`src/components/agents/<agent>/`: ADK agent `Deployment`, `Service`,
     `ServiceAccount`, `PodDisruptionBudget`, `ConfigMap`, `ExternalSecret`, and
     per-agent `NetworkPolicy` rules) and `PodMonitoring` into the
     `agent-workloads` namespace owned by the PLATFORM package, with zero
     overlapping objects between the two `RootSync`s.
- `registry/` manages the active set of agents (`agents/<agent>/agent.yaml`) and
  MCP servers (`mcp-servers/<server>.yaml`). The repository ships with an empty
  active set and stages sample manifests inactive under
  `available/agents/<agent>/` and `available/mcp-servers/<server>.yaml`.
  Onboarding moves a manifest with `git mv registry/available/... registry/...`,
  re-renders with `fleet-package/render.sh agents`, and tags a release; forward
  rollback moves manifests back to `registry/available/` and tags a new release.
  `cards/*.json` holds canonical A2A Agent Card definitions,
  `validate-manifests.sh` runs as `Step #0` before any API mutation, and
  `cloudbuild-register.yaml` orchestrates the three idempotent reconciliation
  scripts (`sync-apigee-proxies.sh`, `sync-apigee-identity.sh`, and
  `sync-agent-registry.sh`).
- `tests/a2a/` contains an optional, self-pruning `FleetPackage`
  (`hybridcloud-agents-a2a-tests` with `deletionPropagationPolicy: FOREGROUND`)
  that runs negative-security verification `Job` workloads for rogue caller
  rejection and east-west bypass prevention, then removes all test fixtures when
  deleted.
- [`tests/data-tier/`](../tests/data-tier/README.md) and
  [`tests/model-tier/`](../tests/model-tier/README.md) contain optional,
  self-contained Kubernetes manifests (applied directly with `kubectl`, not
  managed by Config Delivery) for standing up a sample PostgreSQL 16 +
  `pgvector` backing database (`tests/data-tier/`) and a sample `vLLM`
  (`google/gemma-4-31B-it`) model tier with bundled HTTPS `Ingress` on a GPU
  test cluster (`tests/model-tier/`) for end-to-end evaluation.
- [`tests/verify/`](../tests/verify/README.md) provides an optional
  repeat-validation helper; it does not replace the
  [Solution User Guide (SUG)](user-guide.md) steps.

### Configuration placeholders

Replace these placeholders in `fleet-package/`, `tests/a2a/`, or Cloud Build
trigger substitutions before you deploy:

<!-- mdformat off -->

| Placeholder                     | Description                                                                                      |
| :------------------------------ | :----------------------------------------------------------------------------------------------- |
| `YOUR_PROJECT_ID`               | Google Cloud fleet host and Apigee organization project ID                                       |
| `YOUR_PROJECT_NUMBER`           | Numeric Google Cloud fleet host project number (for the Config Delivery service agent)           |
| `YOUR_CONNECTION`               | Cloud Build 2nd-gen Git repository connection name in `us-central1`                              |
| `YOUR_REPOSITORY`               | Linked repository resource name inside `YOUR_CONNECTION`                                         |
| `YOUR_PUBLISHER_SA_NAME`        | Service account name used by Config Delivery / Cloud Build to package releases                   |
| `YOUR_GATEWAY_FQDN`             | Internal FQDN of the Apigee hybrid ingress gateway substituted into Agent Registry cards         |
| `YOUR_AGENTS_INGRESS_VIP`       | MetalLB `LoadBalancer` IP (`spec.loadBalancerIP`) pinned on `Service/agent-ingress-envoy`        |
| `YOUR_GATEWAY_INGRESS_VIP`      | Apigee hybrid ingress gateway VIP permitted on TCP `443` egress from `agent-egress-envoy`        |
| `YOUR_AGENTS_INGRESS_HOST`      | IP or hostname of the Agents cluster Envoy mTLS ingress gateway (`gdcso-agent-ingress`)          |
| `YOUR_VLLM_INGRESS_HOST`        | IP or hostname of the Model cluster sovereign vLLM ingress gateway (`gdcso-local-vllm`)          |
| `YOUR_PGVECTOR_HOST`            | IP or hostname of your external PostgreSQL + `pgvector` endpoint (`sovereign-pgvector` source)   |
| `YOUR_DATA_SYSTEMS_CIDR`        | CIDR block (for example `<IP>/32`) of your external PostgreSQL + `pgvector` endpoint for `:5432` |
| `YOUR_AGENTS_CLUSTER_NAME`      | Fleet membership name of the Agents cluster (`agents.cluster.name` in property set)              |
| `YOUR_GATEWAY_CLUSTER_NAME`     | Fleet membership name of the Gateway cluster (`gateway.cluster.name` in property set)            |
| `YOUR_MODEL_CLUSTER_NAME`       | Fleet membership name of the Model cluster (`model.cluster.name` in property set)                |
| `_AGENTS_CLUSTER_OIDC_JWKS_B64` | Base64-encoded OIDC JWKS (`kubectl get --raw /openid/v1/jwks`) of the Agents cluster             |

<!-- mdformat on -->

Always substitute your environment-specific values in a private repository copy
(never a public fork) or a rendered release bundle, and verify that no
unrendered `YOUR_*` placeholders remain in `fleet-package/environments/` before
creating a release tag.

### Remove the sample PostgreSQL source (optional)

If you do not want to connect `Deployment/mcp-toolbox` to an external
PostgreSQL + `pgvector` instance (or the optional
[`tests/data-tier/`](../tests/data-tier/README.md) sample), remove the sample
source before deploying `FleetPackage/hybridcloud-agents-platform`:

1. Remove the `sovereign-pgvector` source and its tools from
   `ConfigMap/mcp-toolbox-config` in
   `fleet-package/src/overlays/gateway-tools-platform/mcp-toolbox.yaml`.
2. Remove `ExternalSecret/pgvector-db-creds` and the `PG_DATABASE`, `PG_USER`,
   and `PG_PASSWORD` `secretKeyRef` environment variables from
   `Deployment/mcp-toolbox`.
3. Remove the `:5432` egress rule from `NetworkPolicy/allow-mcp-toolbox`.
4. Re-run `fleet-package/render.sh`.

## Step 6: Set up Config Delivery

Config Delivery builds a release from each Git tag and rolls it out to the
memberships that a `FleetPackage` selects
([Deploy fleet packages](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/how-to/fleet-packages)).
The solution splits deployment into two `FleetPackage` resources over
`environments/`:

- `hybridcloud-agents-platform`
  ([`fleetpackage-platform.yaml`](../fleet-package/fleetpackage-platform.yaml)),
  deployed in Step 7: selects `hybrid-agents-platform=enabled` with
  `variantNameTemplate: "${membership.labels['cluster-role']}-platform"`,
  deploying `agents-platform` and `gateway-tools-platform`.
- `hybridcloud-agents`
  ([`fleetpackage.yaml`](../fleet-package/fleetpackage.yaml)), deployed in the
  [SUG](user-guide.md#activate-adk-ops-orchestrator-and-deploy-v110): selects
  `cluster-role=agents`, deploying `agents` (ADK agents, Envoy proxies,
  per-agent policies, `PodMonitoring`, and agent `ExternalSecret`s). It declares
  no `Namespace` and requires `hybridcloud-agents-platform` first.

This step installs Config Sync, creates the least-privilege reconciler RBAC, and
creates the publisher identity so Step 7 can roll out
`hybridcloud-agents-platform`.

### Prepare the clusters

- [Workstation] Install Config Sync
  (`gcloud beta container fleet config-management apply`) on the agent and
  gateway-and-tool memberships per
  [Deploy fleet packages](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/how-to/fleet-packages);
  Config Delivery delivers each release through a `RootSync` on the cluster.
  Then grant the Config Delivery service agent only the four `RootSync` verbs it
  needs (`create`, `delete`, `get`, `patch`) on each cluster, instead of
  `cluster-admin`.

```bash
for CLUSTER in "${AGENTS_CLUSTER}" "${GATEWAY_CLUSTER}"; do
  sed "s/YOUR_PROJECT_NUMBER/${PROJECT_NUMBER}/" "${PKG_DIR}/fleet-package/configdelivery-rbac.yaml" \
    | kubectl --context="connectgateway_${PROJECT_ID}_global_${CLUSTER}" apply -f -
done
```

- [Workstation] Create the least-privilege reconciler roles on each cluster
  before its `FleetPackage`. By default, the Config Sync reconciler that applies
  a `RootSync` runs as `cluster-admin`, so anyone who can push to the Git source
  could change any object on the cluster. These roles limit it to what the
  bundle contains:
  - Write access only in the tier's namespaces: `agent-workloads` and
    `otel-system` on the agent cluster, `mcp-tools` and `otel-system` on the
    gateway-and-tool cluster.
  - Cluster-scoped read access to every packaged kind, because the reconciler's
    status watcher lists them cluster-wide; without it, syncs fail with
    `KNV2009`.
  - No access to `Secret` objects anywhere; External Secrets Operator and
    cert-manager create those.

```bash
RBAC_KINDS='["configmaps", "serviceaccounts", "services", "deployments", "jobs", "externalsecrets", "podmonitorings", "networkpolicies", "poddisruptionbudgets", "certificates"]'
RBAC_GROUPS='["", "apps", "batch", "external-secrets.io", "monitoring.googleapis.com", "networking.k8s.io", "policy", "cert-manager.io"]'
write_rbac() {
  local cluster="$1" ns1="$2" ns2="$3" f="${SOLUTION_HOME}/reconciler-rbac-${1}.yaml"
  cat << EOF > "${f}"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hybridcloud-agents-reconciler
rules:
  - apiGroups: ["kpt.dev"]
    resources: ["resourcegroups"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["kpt.dev"]
    resources: ["resourcegroups/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch", "create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    resourceNames: ["${ns1}", "${ns2}"]
    verbs: ["update", "patch", "delete"]
  - apiGroups: ${RBAC_GROUPS}
    resources: ${RBAC_KINDS}
    verbs: ["get", "list", "watch"]
EOF
  for ns in "${ns1}" "${ns2}"; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml \
      | kubectl --context="connectgateway_${PROJECT_ID}_global_${cluster}" apply -f -
    cat << EOF >> "${f}"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hybridcloud-agents-reconciler
  namespace: ${ns}
rules:
  - apiGroups: ${RBAC_GROUPS}
    resources: ${RBAC_KINDS}
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
  done
  kubectl --context="connectgateway_${PROJECT_ID}_global_${cluster}" apply -f "${f}"
}
write_rbac "${AGENTS_CLUSTER}" agent-workloads otel-system
write_rbac "${GATEWAY_CLUSTER}" mcp-tools otel-system
```

The function also pre-creates the namespaces so that the `Role` objects apply;
`hybridcloud-agents-platform` adopts them on its first rollout in Step 7.

### Create the publisher identity

- [Workstation] Create the publisher service account and grant its roles.

```bash
gcloud iam service-accounts create "${PUBLISHER_SA%%@*}" --display-name="Fleet package publisher" --project="${PROJECT_ID}"
for ROLE in roles/configdelivery.resourceBundlePublisher roles/artifactregistry.writer roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${PUBLISHER_SA}" \
    --role="${ROLE}" --condition=None
done
```

**Verify:** the publisher service account exists and the reconciler roles exist
on both clusters.

```bash
gcloud iam service-accounts describe "${PUBLISHER_SA}" --project="${PROJECT_ID}" --format="value(email)"
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  kubectl --context="${CTX}" get clusterrole hybridcloud-agents-reconciler
done
```

Confirm that the publisher email prints and both clusters return
`hybridcloud-agents-reconciler`.

[Cloud Console Verification] In the Google Cloud console, confirm `PUBLISHER_SA`
under **IAM & Admin > Service Accounts**. Confirm Config Sync is installed on
both clusters under **Kubernetes Engine > Features > Config** (verify
`ClusterRole/hybridcloud-agents-reconciler` with `kubectl`).

Proceed to [Step 7](#step-7-deploy-the-platform-fleet-package) to render the
bundles, push the first release tag (`v1.0.0`), create
`hybridcloud-agents-platform`, and bind the reconciler roles.

## Step 7: Deploy the platform Fleet package

`FleetPackage/hybridcloud-agents-platform` rolls out the agent-agnostic platform
layer across both clusters so that the platform is running and observable before
any agent is built or deployed:

- `agents-platform` (`src/overlays/agents-platform/`, rendered to
  `environments/agents-platform`, 12 resources) on `AGENTS_CLUSTER`:
  `Namespace/agent-workloads` (Pod Security Standard `restricted`) with
  `default-deny-all` and `allow-dns-egress` `NetworkPolicy` objects, plus
  `otel-system`.
- `gateway-tools-platform` (`src/overlays/gateway-tools-platform/`, rendered to
  `environments/gateway-tools-platform`, 20 resources) on `GATEWAY_CLUSTER`:
  `mcp-tools` namespace with `Certificate/mcp-toolbox-tls` (from
  `hybrid-agents-ca`), `ExternalSecret/pgvector-db-creds` (`PG_DATABASE`,
  `PG_USER`, `PG_PASSWORD`), and MCP Toolbox 1.15.0 (two replicas,
  `PodDisruptionBudget`, `ClusterIP` Service on 8443). It also deploys
  default-deny `NetworkPolicy` objects (allowing ingress only from `apigee` on
  8443 and egress to `YOUR_DATA_SYSTEMS_CIDR` on TCP 5432 and `otel-system`),
  plus `otel-system`.

Both platform overlays include the shared component
`src/components/otel-collector/`, which deploys the
[Google-Built OpenTelemetry Collector](https://docs.cloud.google.com/stackdriver/docs/instrumentation/google-built-otel)
(`otelcol-google:0.147.0@sha256:8599e3a4101a67fff5c98ae6aea68c722d73366475a05624755a568c0e5d9278`)
to `otel-system` on both clusters (patched with `GATEWAY_CLUSTER` in
`gateway-tools-platform`):

- Keyless export through a projected token (`audience` `PROJECT_ID.svc.id.goog`)
  and fleet WIF `external_account` configuration; OTLP on 4317 and 4318 behind
  default-deny `NetworkPolicy` objects.
- A `resource` processor that sets or updates `cloud.region`; without it, Cloud
  Monitoring rejects `k8s_cluster` metrics with an empty location.
- A `transform` processor that deletes `gen_ai.prompt`, `gen_ai.completion`,
  `gen_ai.input.messages`, and `gen_ai.output.messages` when
  `data_classification == "sovereign"`, as defense in depth.

<!-- prettier-ignore -->
> [!NOTE]
> The package deploys no in-cluster database: in
> `src/overlays/gateway-tools-platform/mcp-toolbox.yaml`, `sovereign-pgvector`
> (`sslmode=verify-full`, TLS 1.3) and `Deployment/mcp-toolbox` (`PG_HOST` env,
> rolling pods on host changes via Config Sync) use `YOUR_PGVECTOR_HOST`, or
> remove the sample source per the [package
> README](#remove-the-sample-postgresql-source-optional).

### Render the bundles and push the first release tag

- [Workstation] In your private GitOps repository, replace every `YOUR_*`
  placeholder under `fleet-package/src/` (see
  [Configuration placeholders](#configuration-placeholders)). Run
  `fleet-package/render.sh` (which renders `agents-platform`,
  `gateway-tools-platform`, and `agents` into `fleet-package/environments/`),
  and commit the rendered bundles to `main` before tagging. Config Delivery
  applies `environments/*/manifests.yaml` verbatim, so an unrendered placeholder
  reaches the cluster literally (breaking collector export with
  `Invalid audience` or blocking egress). The placeholders live in these files:
  - `src/components/otel-collector/otel-collector.yaml`: `YOUR_PROJECT_ID` and
    `YOUR_AGENTS_CLUSTER_NAME`.
  - `src/overlays/gateway-tools-platform/kustomization.yaml`: `YOUR_PROJECT_ID`
    and `YOUR_GATEWAY_CLUSTER_NAME`.
  - `src/overlays/gateway-tools-platform/mcp-toolbox.yaml`: `YOUR_PGVECTOR_HOST`
    (`ConfigMap` host and `PG_HOST` environment variable) and
    `YOUR_DATA_SYSTEMS_CIDR` (TCP 5432 egress `ipBlock.cidr`).
  - `src/base/envoy-mtls-ingress-config.yaml`: `YOUR_AGENTS_INGRESS_VIP`, set to
    `AGENTS_INGRESS_VIP` (feeds the `agents` variant deployed in the SUG).
  - `src/base/network-policies.yaml`: `YOUR_GATEWAY_INGRESS_VIP`, set to
    `APIGEE_INGRESS_VIP` (adds TCP 443 egress to the Apigee ingress VIP in
    `allow-agent-egress-proxy`; feeds the `agents` variant deployed in the SUG).
  - Leave `apigee/` and `registry/` as shipped: the Cloud Build pipeline fills
    their placeholders from the trigger substitutions.
- [Workstation] Confirm that the rendered bundles contain no remaining
  placeholder. The command must print nothing.

```bash
grep -rn 'YOUR_' "${PKG_DIR}/fleet-package/environments/" && echo "Unrendered placeholders found; fix them before you tag."
```

- [Workstation] Commit and push the rendered bundles to `main`, then push the
  first release tag (`v1.0.0`). Use `vX.Y.Z` with no pre-release suffix: Config
  Delivery rejects other tags.

```bash
git -C "${REPO_DIR}" add software-only/bare-metal/hybridcloud-agents/fleet-package/
git -C "${REPO_DIR}" commit -m "Render platform and baseline bundles for ${RELEASE_TAG}"
git -C "${REPO_DIR}" push origin main
git -C "${REPO_DIR}" tag -a "${RELEASE_TAG}" -m "Hybrid Cloud AI Agents ${RELEASE_TAG}"
git -C "${REPO_DIR}" push origin "${RELEASE_TAG}"
```

<!-- prettier-ignore -->
> [!NOTE]
> No release pipeline runs yet: the
> [SUG](user-guide.md#step-1-prerequisites-model-armor-orchestrator-secret-trigger-and-agent-images)
> creates the Cloud Build trigger after the per-agent key secrets exist.

### Create the platform FleetPackage and bind reconciler roles

- [Workstation] Render `fleetpackage-platform.yaml` for your project and release
  tag, create `FleetPackage/hybridcloud-agents-platform`, and restrict each
  `RootSync` reconciler with `spec.override.roleRefs`.

The specification sets `deletionPropagationPolicy: FOREGROUND` (deleting the
`FleetPackage` prunes what it deployed), rolling `maxConcurrent: 1`,
`configdelivery-skip-bmctl-clusters: "true"`, selector
`hybrid-agents-platform=enabled`, and
`variantNameTemplate: "${membership.labels['cluster-role']}-platform"`. Config
Delivery grants the reconcilers registry read access automatically. Run
`bind_platform_roles` immediately after creation because each reconciler keeps
`cluster-admin` until its `roleRefs` patch applies; the `FleetPackage` rolls one
cluster at a time (`maxConcurrent: 1`), so binding both clusters in parallel
avoids waiting about 5 minutes when Config Delivery picks the gateway cluster
first.

```bash
sed -e "s/YOUR_PROJECT_ID/${PROJECT_ID}/g" -e "s/YOUR_CONNECTION/${GIT_CONNECTION}/" \
  -e "s/YOUR_REPOSITORY/${GIT_REPOSITORY}/" -e "s/YOUR_PUBLISHER_SA_NAME/${PUBLISHER_SA%%@*}/" \
  -e "s/^\(    tag:\).*/\1 ${RELEASE_TAG}/" \
  "${PKG_DIR}/fleet-package/fleetpackage-platform.yaml" > "${SOLUTION_HOME}/fleetpackage-platform.yaml"
gcloud container fleet packages create hybridcloud-agents-platform \
  --source="${SOLUTION_HOME}/fleetpackage-platform.yaml" --location="${REGION}" --project="${PROJECT_ID}"

bind_platform_roles() {
  local cluster="$1" ns1="$2" ns2="$3"
  kubectl --context="connectgateway_${PROJECT_ID}_global_${cluster}" wait --for=create \
    rootsync/hybridcloud-agents-platform -n config-management-system --timeout=15m
  cat << EOF | kubectl --context="connectgateway_${PROJECT_ID}_global_${cluster}" apply \
    --server-side --field-manager=platform-admin -f -
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: hybridcloud-agents-platform
  namespace: config-management-system
spec:
  override:
    roleRefs:
      - {kind: ClusterRole, name: hybridcloud-agents-reconciler}
      - {kind: Role, name: hybridcloud-agents-reconciler, namespace: ${ns1}}
      - {kind: Role, name: hybridcloud-agents-reconciler, namespace: ${ns2}}
EOF
}
bind_platform_roles "${AGENTS_CLUSTER}" agent-workloads otel-system &
bind_platform_roles "${GATEWAY_CLUSTER}" mcp-tools otel-system &
wait
```

### Verify the platform rollout

- [Workstation] Confirm that the `hybridcloud-agents-platform` rollout
  completes, `otel-collector` runs on both clusters, and the baseline
  `NetworkPolicy` objects exist in `agent-workloads`. Also confirm that MCP
  Toolbox, its TLS certificate, and its `ExternalSecret` are healthy on
  `GATEWAY_CLUSTER`.

```bash
gcloud container fleet packages rollouts list --fleet-package=hybridcloud-agents-platform \
  --location="${REGION}" --project="${PROJECT_ID}" --limit=1
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  kubectl --context="${CTX}" get rootsync hybridcloud-agents-platform -n config-management-system
  kubectl --context="${CTX}" get deploy otel-collector -n otel-system
done
kubectl --context="${CTX_AGENTS}" get netpol default-deny-all allow-dns-egress -n agent-workloads
kubectl --context="${CTX_GATEWAY}" get deploy mcp-toolbox -n mcp-tools
kubectl --context="${CTX_GATEWAY}" get certificate mcp-toolbox-tls -n mcp-tools
kubectl --context="${CTX_GATEWAY}" get externalsecret pgvector-db-creds -n mcp-tools
```

The platform rollout takes about 11 minutes across both clusters (one cluster at
a time). Expect `COMPLETED` for the rollout, `SYNCED` on both `RootSync`
objects, `otel-collector` at `1/1` ready on both clusters, and
`default-deny-all` and `allow-dns-egress` in `agent-workloads`. Expect
`mcp-toolbox` at `2/2` ready, `Certificate/mcp-toolbox-tls` `Ready=True`, and
`ExternalSecret/pgvector-db-creds` reporting `SecretSynced` on
`GATEWAY_CLUSTER`. A rollout that stays `IN_PROGRESS` usually indicates a
missing Step 4 dependency or a reconciler role gap; inspect
`kubectl get rootsync -n config-management-system`.

- [Workstation] Confirm that the restricted platform reconcilers cannot read
  `Secret` objects on either cluster (use `SubjectAccessReview` rather than
  `kubectl auth can-i --as`, because Connect Gateway already impersonates your
  identity).

```bash
sar() {
  kubectl --context="$1" create -o jsonpath='{.status.allowed}{"\n"}' -f - << EOF
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:config-management-system:root-reconciler-$2
  resourceAttributes: {namespace: $3, verb: get, resource: secrets}
EOF
}
sar "${CTX_AGENTS}" hybridcloud-agents-platform agent-workloads
sar "${CTX_GATEWAY}" hybridcloud-agents-platform mcp-tools
```

Expect `false` from both checks, confirming that the reconciler has no
`cluster-admin` binding.

[Cloud Console Verification] In the Google Cloud console, confirm the deployed
platform workloads:

- **Kubernetes Engine > Features > Config** (**Packages** tab):
  `hybridcloud-agents-platform` reports `Synced` on both `AGENTS_CLUSTER` and
  `GATEWAY_CLUSTER` (review rollout builds under **Cloud Build > History** at
  `https://console.cloud.google.com/cloud-build/builds?project=${PROJECT_ID}`).
- **Kubernetes Engine > Workloads**
  (`https://console.cloud.google.com/kubernetes/workload?project=${PROJECT_ID}`):
  `otel-collector` (`1/1`) is healthy in namespace `otel-system` on both
  clusters, and `mcp-toolbox` (`2/2`) is healthy in namespace `mcp-tools` on
  `GATEWAY_CLUSTER`.
- **Logging > Logs Explorer**
  (`https://console.cloud.google.com/logs/query?project=${PROJECT_ID}`): filter
  by `resource.type="k8s_container"` and
  `resource.labels.namespace_name="otel-system"` to confirm both collectors
  started without `Invalid audience` or fleet WIF authentication errors. Live
  agent spans and Envoy metrics appear in Cloud Trace Explorer and Cloud
  Monitoring Metrics Explorer after the SUG deploys `hybridcloud-agents`.

## Verification

Verify that the complete base platform is running, observable, and keyless
before moving to the SUG.

- [Workstation] Confirm cluster readiness, ESO `ClusterSecretStore` health,
  observability CRDs, reconciler RBAC, `hybridcloud-agents-platform` sync status
  and workloads, model-tier HTTPS ingress, Apigee hybrid runtime state, and
  Google Cloud Platform resources.

```bash
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  kubectl --context="${CTX}" get clustersecretstore gcp-secret-manager
  kubectl --context="${CTX}" get crd podmonitorings.monitoring.googleapis.com
  kubectl --context="${CTX}" get clusterrole hybridcloud-agents-reconciler
  kubectl --context="${CTX}" get rootsync hybridcloud-agents-platform -n config-management-system
  kubectl --context="${CTX}" get deploy otel-collector -n otel-system
done
kubectl --context="${CTX_AGENTS}" get netpol default-deny-all allow-dns-egress -n agent-workloads
kubectl --context="${CTX_GATEWAY}" get deploy mcp-toolbox -n mcp-tools
curl -sS --cacert "${SOLUTION_HOME}/hybrid-agents-root-ca.crt" "https://${VLLM_FQDN}/v1/models" | jq -r '.data[].id'
kubectl --context="${CTX_GATEWAY}" get apigeedatastore,apigeetelemetry,apigeeredis,apigeeorganization,apigeeenvironment -n apigee
gcloud container fleet packages rollouts list --fleet-package=hybridcloud-agents-platform --location="${REGION}" --project="${PROJECT_ID}" --limit=1
gcloud artifacts repositories describe "${AR_REPOSITORY}" --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)"
gcloud iam service-accounts describe "${REGISTRAR_SA}" --project="${PROJECT_ID}" --format="value(email)"
gcloud iam service-accounts describe "${PUBLISHER_SA}" --project="${PROJECT_ID}" --format="value(email)"
```

Confirm that both `ClusterSecretStore` objects are `Valid` and `True`, and that
the `podmonitorings.monitoring.googleapis.com` CRD and
`hybridcloud-agents-reconciler` `ClusterRole` exist on both clusters. Confirm
that `hybridcloud-agents-platform` reports `COMPLETED` and `SYNCED` with
`otel-collector` (`1/1` on both clusters), baseline `agent-workloads` policies,
and `mcp-toolbox` (`2/2` on `GATEWAY_CLUSTER`). Confirm that the model-tier
HTTPS probe returns your served model ID with strict TLS verification, all five
Apigee custom resources report `running`, and `${AR_REPOSITORY}`,
`REGISTRAR_SA`, and `PUBLISHER_SA` exist.

[Cloud Console Verification] In the Google Cloud console, cross-check the
deployed platform resources:

- **Kubernetes Engine > Clusters**
  (`https://console.cloud.google.com/kubernetes/list?project=${PROJECT_ID}`) and
  **Workloads**
  (`https://console.cloud.google.com/kubernetes/workload?project=${PROJECT_ID}`):
  all three clusters are registered and healthy, and the `cert-manager`,
  `external-secrets`, `apigee`, `otel-system` (`otel-collector`), and
  `mcp-tools` (`mcp-toolbox`) Deployments are healthy.
- **Security > Secret Manager**
  (`https://console.cloud.google.com/security/secret-manager?project=${PROJECT_ID}`):
  `hybrid-agents-c1-intermediate-ca` and `${MCP_DB_SECRET}` each have an enabled
  version scoped to `ESO_PRINCIPAL`.
- **Apigee > Management > Environments**: `hybrid-agents-env` is attached to
  `hybrid-agents-envgroup` and lists both TLS keystores and references.
- **Cloud Build > Repositories (2nd gen)** and **Artifact Registry >
  Repositories**: `${GIT_REPOSITORY}` is linked under `${GIT_CONNECTION}` and
  `${AR_REPOSITORY}` exists in `us-central1`.
- **Kubernetes Engine > Features > Config** (**Packages** tab): Config Sync is
  installed and `hybridcloud-agents-platform` reports `Synced` on both
  `AGENTS_CLUSTER` and `GATEWAY_CLUSTER`.
- **Logging > Logs Explorer**
  (`https://console.cloud.google.com/logs/query?project=${PROJECT_ID}`):
  `otel-system` collector logs show clean startup without fleet WIF errors.

- [Workstation] Confirm that the project has no user-managed service account
  keys.

```bash
for SA in $(gcloud iam service-accounts list --project="${PROJECT_ID}" --format='value(email)'); do
  gcloud iam service-accounts keys list --iam-account="${SA}" --managed-by=user --project="${PROJECT_ID}"
done
```

Expect empty listings.

[Cloud Console Verification] In the Google Cloud console, open **IAM & Admin >
Service Accounts** and select each solution service account (`APIGEE_SA`,
`REGISTRAR_SA`, `PUBLISHER_SA`, `BUILD_SA`). Confirm on the **Keys** tab that no
user-managed keys exist.

The base platform is now running and observable with no agents deployed. Next,
configure the Apigee AI Gateway and MCP prerequisites, build the sample agent
images, deploy `FleetPackage/hybridcloud-agents`, and run end-to-end
verification. Verification covers agent registration, live agent traces and
Envoy metrics, sovereign and cloud-eligible flows, Model Armor, failover, A2A,
MCP tool filtering, streaming, quotas, and `tests/a2a/`. To complete these
steps, continue in the
[SUG](user-guide.md#step-1-configure-the-ai-gateway-and-onboard-the-first-agent-v110).

## Operations

With `FleetPackage/hybridcloud-agents-platform` running from Step 7, the next
steps are configuring the Apigee AI Gateway, building the sample agent images,
and deploying `FleetPackage/hybridcloud-agents`. That package ships the ADK
agents, agent-tier Envoy proxies, and per-agent policies. Those steps,
end-to-end verification, and Day-2 operations (consumer-key rotation through
`apigeeApp.keyVersion`, JWKS refresh, upgrades, scaling, and use-case
walkthroughs) are covered in the [SUG](user-guide.md#operations).

## Troubleshooting

The following table covers platform installation, `hybridcloud-agents-platform`
rollout, and MCP Toolbox startup issues; Apigee AI Gateway policy, agent, and
Day-2 operational issues are in
[SUG Troubleshooting](user-guide.md#troubleshooting).

<!-- mdformat off -->

| Symptom                                                                                                                          | Cause                                                                                                                                                                          | Resolution                                                             |
| :------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------- |
| Built-in `/mcp` `tools/call` fails with `TLSV1_ALERT_PROTOCOL_VERSION`                                                           | `apigee-mcp-server` loopback offers TLS 1.2 to a TLS 1.3-only virtual host                                                                                                     | Set `minTLSProtocolVersion: "1.2"` (Step 2)                            |
| Rollout stays `IN_PROGRESS`; `RootSync` status shows `KNV2009 ... failed to list` a kind                                         | The reconciler roles lack that packaged kind                                                                                                                                   | Add the kind to `RBAC_KINDS` and re-run `write_rbac` (Step 6)          |
| Cassandra or runtime pods stay `Pending` on a converged node                                                                     | Default node selectors share one label key                                                                                                                                     | Use the two `apigee.cloud.google.com/*` labels (Step 2)                |
| `mcp-toolbox` pods in `CreateContainerConfigError` (`secret "pgvector-db-creds" not found` or `couldn't find key`)               | `hybrid-agents-pgvector-creds` is missing or lacks `PG_DATABASE`, `PG_USER`, or `PG_PASSWORD`, leaving `ExternalSecret/pgvector-db-creds` unsynced                             | See [MCP Toolbox does not start](#mcp-toolbox-does-not-start), case 1. |
| `mcp-toolbox` pods in `CrashLoopBackOff`, log `unable to initialize source "sovereign-pgvector": unable to connect successfully` | Startup ping fails: unrendered `YOUR_PGVECTOR_HOST`, wrong `YOUR_DATA_SYSTEMS_CIDR`, database allow-list missing gateway node IPs, or server certificate SANs missing the host | See [MCP Toolbox does not start](#mcp-toolbox-does-not-start), case 2. |

<!-- mdformat on -->

### MCP Toolbox does not start

- [Workstation] Read the pod state to see which case applies.

```bash
kubectl --context="${CTX_GATEWAY}" -n mcp-tools get pods -l app.kubernetes.io/name=mcp-toolbox
```

1. **`CreateContainerConfigError`:** `Secret/pgvector-db-creds` is missing, or
   `MCP_DB_SECRET` (`hybrid-agents-pgvector-creds`) lacks `PG_DATABASE`,
   `PG_USER`, or `PG_PASSWORD`, leaving `ExternalSecret/pgvector-db-creds` in
   `SecretSyncedError`. Inspect the `ExternalSecret` and Secret Manager:

```bash
kubectl --context="${CTX_GATEWAY}" -n mcp-tools get externalsecret pgvector-db-creds \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")]}{"\n"}'
gcloud secrets versions list "${MCP_DB_SECRET}" --project="${PROJECT_ID}" --filter="state=ENABLED"
```

If the secret is missing or lacks a key, upload a JSON version with
`PG_DATABASE`, `PG_USER`, and `PG_PASSWORD` as in
[Step 4](#step-4-prepare-the-mcp-toolbox-and-observability-prerequisites). Then
annotate `externalsecret/pgvector-db-creds` with
`force-sync="$(date +%s)" --overwrite` so External Secrets Operator (`1h`
refresh interval) syncs immediately.

2. **`CrashLoopBackOff`:** MCP Toolbox starts, synchronously pings the pool
   (`pool.Ping(ctx)`), and exits with
   `unable to initialize source "sovereign-pgvector": unable to connect successfully`.
   Check for four causes: unrendered `YOUR_PGVECTOR_HOST` in
   `ConfigMap/mcp-toolbox-config` and `Deployment/mcp-toolbox` (`PG_HOST`), or
   wrong `YOUR_DATA_SYSTEMS_CIDR` in `NetworkPolicy/allow-mcp-toolbox`. Also
   check for a database access list (`pg_hba.conf`) missing the gateway-and-tool
   node IPs (pod egress is SNATed), or a server certificate whose SANs lack the
   host (`sslmode=verify-full`).

```bash
kubectl --context="${CTX_GATEWAY}" -n mcp-tools logs deploy/mcp-toolbox --previous --tail=20
kubectl --context="${CTX_GATEWAY}" -n mcp-tools get configmap mcp-toolbox-config \
  -o jsonpath='{.data.tools\.yaml}' | grep -E '^\s*(host|port|sslmode):'
PG_HOST="$(kubectl --context="${CTX_GATEWAY}" -n mcp-tools get deploy mcp-toolbox \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PG_HOST")].value}')"
echo "PG_HOST=${PG_HOST}"
kubectl --context="${CTX_GATEWAY}" -n mcp-tools get networkpolicy allow-mcp-toolbox \
  -o jsonpath='{.spec.egress[0].to[0].ipBlock.cidr}{"\n"}'
kubectl --context="${CTX_GATEWAY}" -n mcp-tools run pg-verify --rm -i --restart=Never \
  --image=pgvector/pgvector:pg16@sha256:0dd3149a06e4579a0d70d8fef9945636cd514005e7237deb27f9b67886f8dc4f \
  --labels="app.kubernetes.io/component=mcp-toolbox,app.kubernetes.io/name=mcp-toolbox" \
  --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"pg-verify","image":"pgvector/pgvector:pg16@sha256:0dd3149a06e4579a0d70d8fef9945636cd514005e7237deb27f9b67886f8dc4f","readinessProbe":{"exec":{"command":["false"]}},"env":[{"name":"PG_HOST","value":"'"${PG_HOST}"'"}],"envFrom":[{"secretRef":{"name":"pgvector-db-creds"}}],"command":["sh","-c","PGPASSWORD=\"$PG_PASSWORD\" psql \"host=$PG_HOST port=5432 dbname=$PG_DATABASE user=$PG_USER sslmode=verify-full sslrootcert=/etc/toolbox/tls/ca.crt\" -c \"SELECT 1;\""],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"tls","mountPath":"/etc/toolbox/tls","readOnly":true}]}],"volumes":[{"name":"tls","secret":{"secretName":"mcp-toolbox-tls"}}]}}'
```

Fix the host, CIDR, allow-list, or certificate SANs; if you edited
`src/overlays/gateway-tools-platform/mcp-toolbox.yaml`, re-run
`fleet-package/render.sh`, commit, push a new `vX.Y.Z` tag, and update
`hybridcloud-agents-platform`.

## Clean up

If you deployed the agents package in the SUG, first delete
`FleetPackage/hybridcloud-agents`, the `hybridcloud-agents-registry-sync` Cloud
Build trigger, the Model Armor template, and the per-agent key secrets per
[SUG Clean up](user-guide.md#clean-up). To remove an individual agent without
tearing down the platform, see [Remove an agent](user-guide.md#remove-an-agent).

<!-- prettier-ignore -->
> [!WARNING]
> Deleting `FleetPackage/hybridcloud-agents-platform`
> (`deletionPropagationPolicy: FOREGROUND`) deletes the `agent-workloads`,
> `otel-system`, and `mcp-tools` namespaces—including the Day-0 PKI objects
> created in Step 1 inside `agent-workloads`. Always delete the agents package
> (`hybridcloud-agents`, in the SUG) first and the platform package
> (`hybridcloud-agents-platform`) last.

- [Workstation] Delete `FleetPackage/hybridcloud-agents-platform` before
  removing the reconciler RBAC or publisher service account so foreground
  deletion can prune all delivered namespaces cleanly. Always pass `--force`: a
  bare delete fails with `FAILED_PRECONDITION` (`has nested resources`) once
  rollouts exist, while `--force` keeps `FOREGROUND` deletion propagation.

```bash
gcloud container fleet packages delete hybridcloud-agents-platform --force \
  --location="${REGION}" --project="${PROJECT_ID}"
```

- [Workstation] Delete the pipeline identities and the platform secrets (the
  `hybridcloud-agents-registry-sync` Cloud Build trigger is deleted in
  [SUG Clean up](user-guide.md#clean-up)).

```bash
for SECRET_ID in hybrid-agents-c1-intermediate-ca "${MCP_DB_SECRET}"; do
  gcloud secrets delete "${SECRET_ID}" --project="${PROJECT_ID}" --quiet
done
gcloud iam service-accounts delete "${REGISTRAR_SA}" --project="${PROJECT_ID}" --quiet
gcloud iam service-accounts delete "${PUBLISHER_SA}" --project="${PROJECT_ID}" --quiet
```

- [Workstation] Delete the agent cluster PKI objects and the reconciler roles.

```bash
kubectl --context="${CTX_AGENTS}" delete -f "${SOLUTION_HOME}/reconciler-rbac-${AGENTS_CLUSTER}.yaml" --ignore-not-found
kubectl --context="${CTX_GATEWAY}" delete -f "${SOLUTION_HOME}/reconciler-rbac-${GATEWAY_CLUSTER}.yaml" --ignore-not-found
kubectl --context="${CTX_AGENTS}" delete -f "${SOLUTION_HOME}/agents-pki.yaml" --ignore-not-found
kubectl --context="${CTX_AGENTS}" delete namespace agent-workloads --ignore-not-found
```

Config Sync stays installed on the agent and gateway-and-tool clusters; remove
it per the
[Config Sync documentation](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs)
if you no longer need it.

- [Workstation] Uninstall Apigee hybrid in reverse chart order per
  [Uninstall hybrid runtime](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/uninstall),
  then delete the organization if it is no longer needed.

```bash
for R in "${APIGEE_ENVGROUP}" "${APIGEE_ENV}" "${APIGEE_ORG}" ingress-manager redis telemetry datastore operator; do
  helm --kube-context="${CTX_GATEWAY}" uninstall "${R}" -n apigee
done
kubectl --context="${CTX_GATEWAY}" delete namespace apigee --ignore-not-found
```

- [Workstation] Uninstall ESO and remove the PKI, the model-tier ingress, and
  the local temporary directory.

```bash
for CTX in "${CTX_AGENTS}" "${CTX_GATEWAY}"; do
  helm --kube-context="${CTX}" uninstall external-secrets -n external-secrets
  kubectl --context="${CTX}" delete namespace external-secrets --ignore-not-found
done
kubectl --context="${CTX_GATEWAY}" delete -f "${SOLUTION_HOME}/gateway-pki.yaml" --ignore-not-found
kubectl --context="${CTX_MODEL}" delete -f "${SOLUTION_HOME}/vllm-https-ingress.yaml" --ignore-not-found
kubectl --context="${CTX_MODEL}" delete secret vllm-ingress-tls -n gke-system --ignore-not-found
rm -rf "${WORK}"
```

- [Workstation] If you deployed the optional `tests/data-tier/` sample, remove
  it with the clean-up steps in its README (test cluster and gateway-and-tool
  cluster).
- [Workstation] Optionally delete the Artifact Registry repository
  `${AR_REPOSITORY}`. You can also reset the agent and gateway-and-tool clusters
  and unregister them per
  [Reset a cluster](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/reset-nodes),
  and remove the solution IAM bindings from `APIGEE_SA` and `BUILD_SA`.

## What's next

- [SRA: Hybrid Cloud AI Agents on Distributed Cloud software only](../README.md):
  architecture, components, and design decisions.
- [SUG: Hybrid Cloud AI Agents on Distributed Cloud software only](user-guide.md#overview):
  configure the Apigee AI Gateway, deploy and verify agents and MCP servers, and
  run Day-2 operations.
- [Open model serving on Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/solutions/open-model-serving-sw-only):
  the model-tier prerequisite.
- [Apigee hybrid 1.17](https://docs.cloud.google.com/apigee/docs/hybrid/v1.17/what-is-hybrid)
  and
  [Config Delivery fleet packages](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages).
