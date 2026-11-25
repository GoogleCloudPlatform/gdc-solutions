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

# Federated Learning for Edge AI on Distributed Cloud software only reference implementation

## Overview

This Solution Reference Implementation (SRI) provides reproducible Day-0 and
Day-1 platform deployment steps for federated Low-Rank Adaptation (Fed-LoRA). It
connects retail store clusters running Distributed Cloud software only to a
central Google Kubernetes Engine (GKE) aggregator. The platform is
Flower-application, model-modality, and edge-GPU agnostic, validated with
`google/gemma-4-E2B-it`. For topology, components, GPU memory sizing, and
trade-offs, see **Architecture and design** in the
[Solution Reference Architecture (SRA)](../README.md#architecture-and-design).

The guide follows a two-phase platform boundary:

- **Phase A (Baseline prerequisites):** Verify pre-deployed store clusters, the
  GKE aggregator, NVIDIA GPU Operator time-slicing (`replicas: 2`), and Fleet
  Workload Identity. Also verify Google Cloud Managed Service for Prometheus
  (GMP), store-to-aggregator `:9092` reachability, Cloud Build repository links,
  Artifact Registry, Cloud Storage, and Hugging Face access.
- **Phase B (Fed-LoRA platform layer):** Hydrate environment placeholders, build
  runtime container images with Cloud Build, and roll out `FleetPackage`
  workloads. Deploy the Cloud Monitoring dashboard and verify app-agnostic
  Flower connectivity, base-model serving, dataset staging, and telemetry.

Building Flower App Bundles (`.fab`), running warm-start or federated training
rounds, and managing Day-2 operations live in the
[Solution User Guide (SUG)](user-guide.md).

<!-- prettier-ignore -->
> [!WARNING]
> This reference implementation validates functional federated platform plumbing
> and base serving. Production deployments require mTLS on Flower gRPC channels,
> Secure Aggregation (`SecAgg+`), Kubernetes `NetworkPolicy` rules, and
> persistent `SuperLink` state storage; see
> [Considerations](../README.md#considerations) in the SRA.

<!-- prettier-ignore -->
> [!NOTE]
> Deploying `google/gemma-4-E2B-it` requires accepting the [Gemma Terms of
> Use](https://ai.google.dev/gemma/terms) on Hugging Face before bootstrapping
> store cluster secrets.

<!-- prettier-ignore -->
> [!WARNING]
> Reference implementation disclaimer. This guide and its Apache 2.0 sample
> manifests are provided for architectural evaluation and reference purposes
> only, without official product support or service-level agreement (SLA)
> warranty. Validate all sizing, security, and operational controls against your
> production requirements before deployment.

## Objectives

Complete Phase A verification and Phase B rollout to achieve the following Day-1
platform outcomes:

- Verify baseline cluster registrations, GPU time-slicing capacity
  (`nvidia.com/gpu: 2`), Workload Identity pools, observability custom
  resources, network routing, and cloud registries.
- Populate a private GitHub GitOps repository from the solution package, replace
  `YOUR_*` placeholders, and render deterministic per-store and central
  manifests.
- Build and push pre-baked `flwr-trainer` and `flwr-superlink` container images
  to Artifact Registry with Cloud Build.
- Reconcile central and store workloads (`flwr-superlink`, `vllm-gemma4`,
  `flwr-supernode`, `flwr-trainer`, `PodMonitoring`) through Config Delivery
  `FleetPackage` resources and deploy the Cloud Monitoring dashboard.
- Pass the app-agnostic platform exit gate across Flower Control API and online
  `SuperNode` registration, vLLM base-model serving, store PVC data sovereignty,
  OpenMetrics health, and Cloud Monitoring.

## Before you begin

Phase A treats clusters and foundational platform add-ons as pre-deployed
prerequisites. Run the verification checks in each subsection below before
starting Phase B; if any component is absent, create it using the linked
official documentation. Deploying this reference implementation incurs billable
charges for GKE, Cloud Build, Artifact Registry, Cloud Storage, and Cloud
Monitoring; estimate costs with the
[Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator).

### Set up workstation tools and reference configuration

Install the following CLI tools on an operator workstation that can reach Google
Cloud APIs and Connect Gateway:

- `gcloud` (Google Cloud SDK `490.0.0` or later) and `kubectl` (`1.35` or later,
  bundling Kustomize `v5+`).
- `python3` (`3.10`–`3.12`) with Flower installed in a virtual environment
  (`pip install "flwr[rest]==1.36.0"`).
- `git`, `curl`, and `jq` for repository initialization, endpoint probes, and
  JSON inspection.

Create a local working directory and write `${SOLUTION_HOME}/.env` aligned with
`config/.env.example` and the `YOUR_*` placeholders defined in the configuration
table below.

<!-- mdformat off -->

| Placeholder               | Variable                        | Description                                                                                           | Example value                |
| :------------------------ | :------------------------------ | :---------------------------------------------------------------------------------------------------- | :--------------------------- |
| `YOUR_PROJECT_ID`         | `PROJECT_ID`                    | Google Cloud fleet host project ID                                                                    | `retail-edge-fl-prod`        |
| `YOUR_PROJECT_NUMBER`     | `PROJECT_NUMBER`                | Numeric Google Cloud fleet host project number (for Config Delivery RBAC)                             | `123456789012`               |
| `YOUR_GCP_ZONE`           | `ZONE`                          | Compute zone of the central GKE aggregator node pool                                                  | `us-central1-b`              |
| `YOUR_VPC_NAME`           | `VPC_NAME`                      | Custom VPC network hosting store and aggregator subnets                                               | `edge-fl-vpc`                |
| `YOUR_SUBNET_NAME`        | `SUBNET_NAME`                   | Subnet hosting store nodes and the aggregator Internal LoadBalancer                                   | `edge-fl-subnet`             |
| `YOUR_STORE_CIDR`         | `SUBNET_CIDR`                   | Source IPv4 CIDR of edge store clusters allowed by the SuperLink Internal LoadBalancer (`:9092`)      | `10.100.0.0/24`              |
| `YOUR_STORE_1_CLUSTER`    | `STORE1_CLUSTER_NAME`           | Global Fleet membership name of Distributed Cloud software only edge cluster 1                        | `edge-store-1`               |
| `YOUR_STORE_2_CLUSTER`    | `STORE2_CLUSTER_NAME`           | Global Fleet membership name of Distributed Cloud software only edge cluster 2                        | `edge-store-2`               |
| `YOUR_AGGREGATOR_CLUSTER` | `GKE_CLUSTER_NAME`              | Name and regional Fleet membership of the central GKE aggregator cluster                              | `central-fl-aggregator`      |
| `YOUR_SUPERLINK_ILB_IP`   | `FLWR_SERVER_INTERNAL_LB_IP`    | Static RFC 1918 IP reserved on `SUBNET_NAME` for `flwr-superlink-service`                             | `10.100.0.50`                |
| `YOUR_STORE_1_VLLM_LB_IP` | `STORE1_VLLM_LB_IP`             | Static RFC 1918 MetalLB VIP reserved on store 1 for `vllm-service` (`:8000`)                          | `10.100.0.131`               |
| `YOUR_STORE_2_VLLM_LB_IP` | `STORE2_VLLM_LB_IP`             | Static RFC 1918 MetalLB VIP reserved on store 2 for `vllm-service` (`:8000`)                          | `10.100.0.163`               |
| `YOUR_GCS_BUCKET`         | `GCS_BUCKET` / `GCS_BUCKET_URI` | Regional Cloud Storage bucket storing the round-0 template and federated LoRA adapters                | `retail-edge-fl-checkpoints` |
| `YOUR_AR_REPO`            | `AR_REPO`                       | Regional Artifact Registry Docker repository in `us-central1` for `flwr-trainer` and `flwr-superlink` | `fl-containers`              |
| `YOUR_CONNECTION`         | `CB_CONNECTION`                 | 2nd-generation Cloud Build GitHub repository connection name in `us-central1`                         | `fed-lora-github-conn`       |
| `YOUR_REPOSITORY`         | `CB_REPOSITORY`                 | Linked repository resource name inside `YOUR_CONNECTION`                                              | `fed-lora-gitops-link`       |
| `YOUR_PUBLISHER_SA_NAME`  | `PUBLISHER_SA_NAME`             | Service account name used by Config Delivery / Cloud Build to package bundles                         | `fl-pkg-publisher`           |
| `YOUR_WORKLOAD_SA_NAME`   | `WORKLOAD_SA_NAME`              | Workload service account name granted scoped Cloud Storage adapter prefix access                      | `fl-storage-sa`              |
| `YOUR_HF_TOKEN`           | `HF_TOKEN`                      | Read-scoped Hugging Face access token with Gemma license accepted                                     | `hf_REDACTED_TOKEN`          |
| `YOUR_GITHUB_ORG`         | `GITHUB_ORG`                    | GitHub organization or user owning your private GitOps repository copy                                | `example-retail-org`         |

<!-- mdformat on -->

```bash
export SOLUTION_HOME="${HOME}/fed-lora-work"
mkdir -p "${SOLUTION_HOME}"

cat <<'EOF' > "${SOLUTION_HOME}/.env"
# --- GCP Project & Regional Control Plane ---
PROJECT_ID="YOUR_PROJECT_ID"
REGION="us-central1"
ZONE="YOUR_GCP_ZONE"

# --- Custom VPC & Subnet Configuration ---
VPC_NAME="YOUR_VPC_NAME"
SUBNET_NAME="YOUR_SUBNET_NAME"
SUBNET_CIDR="YOUR_STORE_CIDR"
ADMIN_WS_SUBNET="YOUR_ADMIN_SUBNET_NAME"
ADMIN_WS_CIDR="10.101.0.0/24"

# --- Distributed Cloud software only Release & Admin Workstation ---
BMCTL_VERSION="1.36.0-gke.532"
ADMIN_VM_NAME="YOUR_ADMIN_VM_NAME"
ADMIN_VM_IP="10.101.0.2"

# --- Store 1 & Store 2 Edge Clusters ---
STORE1_CLUSTER_NAME="YOUR_STORE_1_CLUSTER"
STORE1_VM_NAME="YOUR_STORE_1_NODE"
STORE1_VM_IP="10.100.0.11"
STORE1_ALIAS_RANGES="10.100.0.128/28"
STORE1_CP_VIP="10.100.0.129"
STORE1_INGRESS_VIP="10.100.0.130"
STORE1_LB_POOL="10.100.0.131-10.100.0.142"
STORE1_VLLM_LB_IP="10.100.0.131"

STORE2_CLUSTER_NAME="YOUR_STORE_2_CLUSTER"
STORE2_VM_NAME="YOUR_STORE_2_NODE"
STORE2_VM_IP="10.100.0.12"
STORE2_ALIAS_RANGES="10.100.0.160/28"
STORE2_CP_VIP="10.100.0.161"
STORE2_INGRESS_VIP="10.100.0.162"
STORE2_LB_POOL="10.100.0.163-10.100.0.174"
STORE2_VLLM_LB_IP="10.100.0.163"

# --- Central GKE Aggregator Cluster ---
GKE_CLUSTER_NAME="YOUR_AGGREGATOR_CLUSTER"
FLWR_SERVER_INTERNAL_LB_IP="YOUR_SUPERLINK_ILB_IP"

# --- Cloud Storage & Artifact Registry ---
GCS_BUCKET="YOUR_GCS_BUCKET"
GCS_BUCKET_URI="gs://YOUR_GCS_BUCKET"
AR_REPO="YOUR_AR_REPO"
IMAGE_TAG="v1.0.0"

# --- GitOps Config Delivery & Workload Identity ---
GITHUB_ORG="YOUR_GITHUB_ORG"
GITHUB_REPO="fed-lora-gitops"
CB_CONNECTION="YOUR_CONNECTION"
CB_REPOSITORY="YOUR_REPOSITORY"
PUBLISHER_SA_NAME="YOUR_PUBLISHER_SA_NAME"
WORKLOAD_SA_NAME="YOUR_WORKLOAD_SA_NAME"
PACKAGE_RELEASE="v1.0.0"
EDGE_NAMESPACE="fed-lora-poc"
CENTRAL_NAMESPACE="fed-lora-aggregator"
BASE_MODEL_ID="google/gemma-4-E2B-it"
SEED_REPO_URL="https://github.com/GoogleCloudPlatform/gdc-solutions.git"
SEED_REF="main"
SEED_SUBDIR="software-only/bare-metal/fed-lora"

# --- Authentication & Secrets ---
HF_TOKEN="YOUR_HF_TOKEN"
AR_PULL_TOKEN=""
AR_READER_KEY_FILE=""
EOF
chmod 600 "${SOLUTION_HOME}/.env"

set -a
source "${SOLUTION_HOME}/.env"
set +a
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
export PROJECT_NUMBER
```

<!-- prettier-ignore -->
> [!IMPORTANT]
> Keep `REGION="us-central1"` for Config Delivery `FleetPackage` control-plane
> resources and its linked 2nd-generation Cloud Build connection, which is
> currently the supported Config Delivery control-plane region.

### Verify store and aggregator clusters

Ensure your environment provides the following pre-deployed clusters:

- **Store clusters:** Two or more single-node
  [Distributed Cloud software only for bare metal](https://cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/clusters/create-clusters-overview)
  clusters (`1.36.0` or later), each with one NVIDIA GPU sized per
  [Hardware constraints](../README.md#hardware-constraints). Each store cluster
  must be
  [registered to the project Fleet](https://cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/clusters/register-clusters)
  in `locations/global`.
- **Aggregator cluster:** One VPC-native
  [GKE Standard cluster](https://cloud.google.com/kubernetes-engine/docs/how-to/creating-a-regional-cluster)
  (`1.35` or later)
  [registered to the same Fleet](https://cloud.google.com/kubernetes-engine/docs/fleets/register-clusters)
  in `locations/${REGION}`.
- **Subnet and quota hygiene:** Enable Private Google Access on store and GKE
  subnets and allow IP-in-IP (`ipip`, protocol 4) across multi-node Cilium
  clusters. When emulating bare metal on Compute Engine, check Blackwell or G4
  quota via `gcloud alpha quotas info list --service=compute.googleapis.com`.

<!-- prettier-ignore -->
> [!NOTE]
> Distributed Cloud software only registers fleet memberships in
> `locations/global`, whereas GKE registers memberships in
> `locations/${REGION}`; passing the wrong `--location` flag returns
> `NOT_FOUND`.

Verify fleet memberships and acquire kubeconfig contexts (`store-1-ctx`,
`store-2-ctx`, `central-ctx`):

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for membership in "${STORE1_CLUSTER_NAME}" "${STORE2_CLUSTER_NAME}"; do
  gcloud container fleet memberships describe "${membership}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --format="value(name,state.code)"
done

gcloud container fleet memberships describe "${GKE_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --format="value(name,state.code)"

gcloud container fleet memberships get-credentials "${STORE1_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" --location=global
kubectl config rename-context "connectgateway_${PROJECT_ID}_global_${STORE1_CLUSTER_NAME}" store-1-ctx

gcloud container fleet memberships get-credentials "${STORE2_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" --location=global
kubectl config rename-context "connectgateway_${PROJECT_ID}_global_${STORE2_CLUSTER_NAME}" store-2-ctx

gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" --zone="${ZONE}"
kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${GKE_CLUSTER_NAME}" central-ctx
```

Confirm each `memberships describe` call returns `READY` and
`kubectl --context=store-1-ctx get nodes` lists `Ready` nodes.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Clusters](https://console.cloud.google.com/kubernetes/list/overview)
  page, both store clusters and the central GKE aggregator appear with `OK`
  status.
- On the
  [Kubernetes Engine > Fleets](https://console.cloud.google.com/kubernetes/fleet)
  page, all three clusters appear as registered members in the project Fleet.

### Verify GPU Operator and time-slicing

Each store cluster requires
[NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html)
`v26.7.0` (driver `595.91.07` on Linux 6.8+ Blackwell hosts) installed with
`-n gpu-operator --create-namespace` and `RuntimeClass` `nvidia`. Verify no
orphaned GPU Operator deployment runs in `default` or another namespace. On
single-GPU stores, apply `prerequisites/gpu-time-slicing/`
(`ConfigMap/time-slicing-config` with `replicas: 2`, `migStrategy: none`, and
`ClusterPolicy/cluster-policy`). Time-slicing lets `vllm-gemma4` and
`flwr-trainer` share one card while vLLM Level-1 sleep arbitrates VRAM. Skip
`prerequisites/gpu-time-slicing/` on multi-GPU nodes where inference and
training use dedicated physical GPUs.

<!-- prettier-ignore -->
> [!CAUTION]
> `ConfigMap/time-slicing-config` and `ClusterPolicy/cluster-policy` are
> excluded from `fed-lora-edge-package` so `FleetPackage` rollouts or deletions
> never prune cluster GPU policies. Before upgrading a cluster where an earlier
> `FleetPackage` owned those objects, annotate both live resources with
> `client.lifecycle.config.k8s.io/deletion=detach` so Config Sync detaches
> rather than deletes them:

```bash
for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" annotate configmap time-slicing-config -n gpu-operator \
    client.lifecycle.config.k8s.io/deletion=detach --overwrite
  kubectl --context="${ctx}" annotate clusterpolicy cluster-policy \
    client.lifecycle.config.k8s.io/deletion=detach --overwrite
done
```

On single-GPU store clusters, apply `prerequisites/gpu-time-slicing/` from the
solution package. Confirm `gpu-operator` runs solely in `gpu-operator` (none in
`default`), `RuntimeClass` `nvidia` exists, `ClusterPolicy/cluster-policy`
reaches `ready`, and `allocatable["nvidia.com/gpu"]` equals `"2"`:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

PREREQ_TMP="$(mktemp -d)"
git clone --depth 1 --filter=blob:none --sparse \
  --branch "${SEED_REF}" "${SEED_REPO_URL}" "${PREREQ_TMP}"
git -C "${PREREQ_TMP}" sparse-checkout set "${SEED_SUBDIR}/prerequisites/gpu-time-slicing"

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" get deploy -A -l app.kubernetes.io/component=gpu-operator
  gpu_op_ns="$(kubectl --context="${ctx}" get deploy -A \
    -l app.kubernetes.io/component=gpu-operator \
    -o jsonpath='{.items[*].metadata.namespace}')"
  echo "${ctx}: gpu-operator namespaces=${gpu_op_ns}"
  test "${gpu_op_ns}" = "gpu-operator"
  ! kubectl --context="${ctx}" -n default get deploy gpu-operator >/dev/null 2>&1
  kubectl --context="${ctx}" get runtimeclass nvidia -o name
  kubectl --context="${ctx}" apply -k \
    "${PREREQ_TMP}/${SEED_SUBDIR}/prerequisites/gpu-time-slicing"
  for attempt in {1..18}; do
    cp_state="$(kubectl --context="${ctx}" get clusterpolicies.nvidia.com cluster-policy \
      -o jsonpath='{.status.state}')"
    gpu_slices="$(kubectl --context="${ctx}" get nodes \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"
    if [[ "${cp_state}" == "ready" && "${gpu_slices}" == "2" ]]; then
      echo "${ctx}: cluster-policy=${cp_state}, allocatable nvidia.com/gpu=${gpu_slices}"
      break
    fi
    test "${attempt}" -lt 18
    sleep 10
  done
done
rm -rf "${PREREQ_TMP}"
```

Confirm the command exits `0`, lists `gpu-operator` solely in namespace
`gpu-operator` (none in `default`), and prints
`cluster-policy=ready, allocatable nvidia.com/gpu=2` for both store contexts.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Workloads](https://console.cloud.google.com/kubernetes/workload)
  page, filter by namespace `gpu-operator` and verify `gpu-operator` workloads
  are `OK` on both store clusters.

### Verify Fleet Workload Identity, GMP observability, and network routing

Verify the three platform integration prerequisites across your pre-deployed
clusters:

- **Workload Identity:** Enable
  [Fleet Workload Identity](https://cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity)
  (`${PROJECT_ID}.svc.id.goog`) on store clusters and
  [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
  on the aggregator so pods authenticate without static service account keys.
- **GMP and Cloud Logging:** Enable
  [application metrics and logs](https://cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/operate/logging-monitoring)
  (`enableGMPForApplications: true`, `enableCloudLoggingForApplications: true`)
  on store clusters. Enable
  [Google Cloud Managed Service for Prometheus](https://cloud.google.com/monitoring/kubernetes-engine/prometheus)
  on GKE so `PodMonitoring` targets (ports 8000, 9100, and 9400) are scraped.
- **Store-to-aggregator `:9092` reachability:** Permit outbound TCP `:9092` from
  `${SUBNET_CIDR}` to `${FLWR_SERVER_INTERNAL_LB_IP}` on the
  [Internal passthrough Network Load Balancer](https://cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balancing)
  subnet; stores require zero inbound Flower firewall rules.
- **Endpoint source restrictions:** Restrict `flwr-superlink-service` via
  `loadBalancerSourceRanges: ["${SUBNET_CIDR}"]` so firewall policy enforcers
  never purge `0.0.0.0/0` rules, and restrict store `vllm-service` (`:8000`) to
  trusted subnets because `--enable-sleep-mode` requires
  `VLLM_SERVER_DEV_MODE=1`.

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

gcloud container fleet memberships describe "${STORE1_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" --location=global \
  --format="value(authority.workloadIdentityPool)"

for ctx in store-1-ctx store-2-ctx central-ctx; do
  kubectl --context="${ctx}" get crd podmonitorings.monitoring.googleapis.com -o name
done

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n kube-system get stackdriver stackdriver \
    -o jsonpath='{.spec.enableGMPForApplications}{" "}{.spec.enableCloudLoggingForApplications}{"\n"}'
done
```

Confirm the workload identity pool equals `${PROJECT_ID}.svc.id.goog`,
`podmonitorings.monitoring.googleapis.com` exists on all three clusters, and
both stores print `true true`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Clusters](https://console.cloud.google.com/kubernetes/list/overview)
  page, open each cluster's **Details** tab to verify Workload Identity and
  Managed Service for Prometheus are enabled.

### Verify Cloud Build repository connection, registries, and Gemma access

Ensure the cloud-side services and credentials exist before deploying Phase B:

- **Private GitHub repository and Cloud Build connection:** Create a **private**
  GitHub repository (`${GITHUB_ORG}/${GITHUB_REPO}`, never a public fork) with
  workstation `git` push access configured. Link it in `us-central1` through a
  [2nd-generation Cloud Build GitHub connection](https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github)
  (`${CB_CONNECTION}` / `${CB_REPOSITORY}`) for
  [Config Delivery](https://cloud.google.com/kubernetes-engine/fleet-management/docs/config-delivery/set-up).
  Authorize the repository in the Cloud Build GitHub App (no token in `.env`);
  linking it via `gcloud builds repositories create` completes in seconds (lab
  example: `5.39 s`).
- **Artifact Registry and Cloud Storage:** Create one regional Docker
  [Artifact Registry repository](https://cloud.google.com/artifact-registry/docs/repositories/create-repos)
  (`${AR_REPO}`) in `${REGION}` and one regional
  [Cloud Storage bucket](https://cloud.google.com/storage/docs/creating-buckets)
  (`gs://${GCS_BUCKET}`) with uniform bucket-level access; raw store training
  data never enters `gs://${GCS_BUCKET}`.
- **Hugging Face Gemma token:** Accept the gated model license on
  [`google/gemma-4-E2B-it`](https://huggingface.co/google/gemma-4-E2B-it) and
  set `HF_TOKEN` in `${SOLUTION_HOME}/.env` for `Secret/hf-token-secret`.

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for api in gkehub.googleapis.com configdelivery.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com \
  storage.googleapis.com sts.googleapis.com iamcredentials.googleapis.com \
  monitoring.googleapis.com logging.googleapis.com; do
  gcloud services list --enabled --project="${PROJECT_ID}" \
    --filter="config.name=${api}" --format="value(config.name)"
done

gcloud builds connections describe "${CB_CONNECTION}" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="value(installationState.stage)"

gcloud builds repositories describe "${CB_REPOSITORY}" \
  --connection="${CB_CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}" \
  --format="value(name,remoteUri)"

gcloud artifacts repositories describe "${AR_REPO}" \
  --location="${REGION}" --project="${PROJECT_ID}" --format="value(format)"

gcloud storage buckets describe "gs://${GCS_BUCKET}" \
  --project="${PROJECT_ID}" --format="value(uniform_bucket_level_access)"
```

Confirm all nine APIs are listed and `installationState.stage` is `COMPLETE`.
Verify `name` equals
`projects/${PROJECT_ID}/locations/${REGION}/connections/${CB_CONNECTION}/repositories/${CB_REPOSITORY}`,
`remoteUri` matches `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git`,
`${AR_REPO}` format is `DOCKER`, and `uniform_bucket_level_access` is `True`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Cloud Build > Repositories (2nd gen)](https://console.cloud.google.com/cloud-build/repositories/2nd-gen)
  page in `us-central1`, `${CB_CONNECTION}` is active and links
  `${CB_REPOSITORY}` to `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git`.
- On the
  [Artifact Registry > Repositories](https://console.cloud.google.com/artifacts)
  page, `${AR_REPO}` appears in `${REGION}` with format `Docker`.
- On the
  [Cloud Storage > Buckets](https://console.cloud.google.com/storage/browser)
  page, `${GCS_BUCKET}` appears in `${REGION}` with uniform bucket-level access
  enabled.

### Identity and Access Management roles

Ensure the following Google Cloud IAM bindings and Kubernetes RBAC roles are in
place across the project and clusters:

<!-- mdformat off -->

| Principal                                                                                                                                                                      | Scope                                                | Role or Kubernetes RBAC                                                                                                                                                                                               | Purpose                                                                                                                 |
| :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------- |
| Operator identity                                                                                                                                                              | Project `${PROJECT_ID}`                              | `roles/gkehub.admin`, `roles/configdelivery.admin`, `roles/cloudbuild.builds.editor`, `roles/artifactregistry.admin`, `roles/storage.admin`, `roles/iam.serviceAccountAdmin`, `roles/monitoring.dashboardEditor`      | Manage fleet labels, `FleetPackage` resources, Cloud Build jobs, registries, Workload Identity bindings, and dashboards |
| `${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com`                                                                                                                   | Project `${PROJECT_ID}`                              | `roles/configdelivery.resourceBundlePublisher`, `roles/logging.logWriter`, `roles/artifactregistry.writer`                                                                                                            | Publish OCI resource bundles from tagged GitHub releases via Config Delivery                                            |
| `service-${PROJECT_NUMBER}@gcp-sa-configdelivery.iam.gserviceaccount.com`                                                                                                      | Namespace `config-management-system` (all clusters)  | Kubernetes `Role` + `RoleBinding` `configdelivery-rootsync-manager` (`get`, `list`, `watch`, `create`, `update`, `patch`, `delete` on `rootsyncs.configsync.gke.io`)                                                  | Allow Config Delivery to create, reconcile, and delete `RootSync` objects on target clusters                            |
| `principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${EDGE_NAMESPACE}/sa/ar-pull-refresher` | Artifact Registry `${AR_REPO}`                       | `roles/artifactregistry.reader`                                                                                                                                                                                       | Direct Fleet Workload Identity STS token exchange for `CronJob/ar-pull-refresher` with zero Cloud Storage access        |
| `${WORKLOAD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com`                                                                                                                    | Bucket `gs://${GCS_BUCKET}` + Workload Identity pool | `roles/storage.objectAdmin` on `gs://${GCS_BUCKET}`; `roles/iam.workloadIdentityUser` granted to `${PROJECT_ID}.svc.id.goog[${EDGE_NAMESPACE}/default]` and `${PROJECT_ID}.svc.id.goog[${CENTRAL_NAMESPACE}/default]` | Read and write global LoRA checkpoints, candidate adapters, and consensus verdicts without static keys                  |

<!-- mdformat on -->

---

## Companion repository layout and configuration

The `software-only/bare-metal/fed-lora/` package contains the Flower
application, Kustomize manifests, container definitions, Config Delivery
`FleetPackage` specifications, and scripts referenced by this guide and the
[Solution User Guide (SUG)](user-guide.md).

### Repository layout

```text
fed-lora/
├── README.md
├── docs/
│   ├── images/
│   │   └── fed-lora-architecture.png
│   ├── reference-implementation.md
│   └── user-guide.md
├── apps/
│   └── fed-lora/
│       ├── canary_eval.py
│       ├── canary_suite.json
│       ├── clientapp.py
│       ├── fed_lora/
│       │   ├── __init__.py
│       │   └── observability.py
│       ├── observability.py
│       ├── pyproject.toml
│       ├── run_config_federated.toml
│       ├── run_config_local_sft.toml
│       ├── serverapp.py
│       └── test_flower_hardening.py
├── base/
│   ├── credentials/
│   │   ├── ar-pull-refresher.yaml
│   │   └── kustomization.yaml
│   ├── flwr-client/
│   │   ├── flwr-supernode-deployment.yaml
│   │   ├── flwr-trainer-deployment.yaml
│   │   ├── kustomization.yaml
│   │   └── observability.py
│   ├── flwr-server/
│   │   ├── central-pod-monitoring.yaml
│   │   ├── gke-flwr-superlink-deployment.yaml
│   │   ├── gke-flwr-superlink-ilb-service.yaml
│   │   ├── kustomization.yaml
│   │   └── observability.py
│   ├── monitoring/
│   │   ├── central-pod-monitoring.yaml
│   │   ├── dcgm-pod-monitoring.yaml
│   │   ├── edge-pod-monitoring.yaml
│   │   ├── edge-stackdriver-config.yaml
│   │   └── kustomization.yaml
│   └── vllm-serving/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── shared-model-pvc.yaml
│       └── vllm-gemma4-deployment.yaml
├── config/
│   ├── .env.example
│   ├── fed_lora_env.sh
│   └── monitoring/
│       └── fed-lora-demo-dashboard.json
├── docker/
│   ├── Dockerfile.superlink
│   ├── Dockerfile.trainer
│   └── cloudbuild-images.yaml
├── fleet-package/
│   ├── configdelivery-rbac.yaml
│   ├── environments/
│   │   ├── central-aggregator/
│   │   │   └── manifests.yaml
│   │   ├── store-1/
│   │   │   └── manifests.yaml
│   │   └── store-2/
│   │       └── manifests.yaml
│   ├── fleetpackage-central.yaml
│   ├── fleetpackage-edge.yaml
│   └── render.sh
├── overlays/
│   ├── central-aggregator/
│   │   └── kustomization.yaml
│   ├── store-1/
│   │   ├── data/
│   │   │   └── train.jsonl
│   │   └── kustomization.yaml
│   └── store-2/
│       ├── data/
│       │   └── train.jsonl
│       └── kustomization.yaml
├── prerequisites/
│   └── gpu-time-slicing/
│       ├── README.md
│       ├── gpu-clusterpolicy-timeslicing.yaml
│       ├── gpu-time-slicing-configmap.yaml
│       └── kustomization.yaml
└── scripts/
    ├── apply_cluster_secrets.sh
    ├── build_and_stage_fab.sh
    ├── demo_runner.sh
    ├── deploy_demo_dashboard.sh
    ├── eval_local_gemma_judge.py
    ├── render_fleet_manifests.sh
    ├── reset_demo_to_stage1.sh
    ├── run_full_5stage_demo.sh
    ├── run_multiround_fl_demo.sh
    ├── run_stage2_local_sft.sh
    ├── run_stage4_fedavg.sh
    ├── run_stage6_fab_showcase.sh
    ├── stage_gcs_data.sh
    ├── verify_demo_setup.sh
    ├── verify_stage1_baseline.sh
    ├── verify_stage3_hallucination_control.sh
    ├── verify_stage3_siloed_qa.sh
    ├── verify_stage5_federated_qa.sh
    └── verify_stage5_hallucination_control.sh
```

- `apps/fed-lora/` contains the Flower application package (`pyproject.toml`,
  `serverapp.py`, `clientapp.py`, `canary_eval.py`, `canary_suite.json`,
  `run_config_local_sft.toml`, `run_config_federated.toml`, and offline unit
  tests in `test_flower_hardening.py`).
- `base/` and `overlays/` contain canonical Kustomize bases and per-cluster
  overlays for `central-aggregator`, `store-1`, and `store-2`. They include
  sample datasets (`overlays/store-{1,2}/data/train.jsonl`), Workload Identity
  credential rotation (`base/credentials/`), and Managed Service for Prometheus
  monitoring (`base/monitoring/`).
- `config/` contains the placeholder environment template
  (`config/.env.example`), shared shell loader (`config/fed_lora_env.sh`), and
  the four-quadrant Cloud Monitoring dashboard definition
  (`config/monitoring/fed-lora-demo-dashboard.json`).
- `docker/` contains `Dockerfile.trainer`, `Dockerfile.superlink`, and
  `cloudbuild-images.yaml` to build pre-baked images into your regional Artifact
  Registry repository.
- `fleet-package/` contains the two Config Delivery specifications
  (`fleetpackage-central.yaml` and `fleetpackage-edge.yaml`), namespace-scoped
  `RootSync` RBAC (`configdelivery-rbac.yaml`), the deterministic renderer
  (`render.sh`), and rendered variant bundles under `environments/`.
- [`prerequisites/gpu-time-slicing/`](../prerequisites/gpu-time-slicing/README.md)
  contains the one-time Phase A NVIDIA GPU time-slicing manifests
  (`replicas: 2`) kept outside `FleetPackage` overlays so GitOps rollouts never
  prune cluster-wide GPU policies.
- `scripts/` contains operational helpers (`render_fleet_manifests.sh`,
  `apply_cluster_secrets.sh`, `stage_gcs_data.sh`, `build_and_stage_fab.sh`,
  `deploy_demo_dashboard.sh`, `verify_demo_setup.sh`) and optional staged
  demonstration runners (`demo_runner.sh`, `run_full_5stage_demo.sh`,
  `run_stage2_local_sft.sh`, `run_stage4_fedavg.sh`,
  `run_multiround_fl_demo.sh`, `reset_demo_to_stage1.sh`).

### Configuration placeholders and Flower run-config

Before running `fleet-package/render.sh`, substitute the fifteen repository
placeholders in your private GitOps repository copy. See the full mapping table
in
[Set up workstation tools and reference configuration](#set-up-workstation-tools-and-reference-configuration):
`YOUR_PROJECT_ID`, `YOUR_PROJECT_NUMBER`, `YOUR_CONNECTION`, `YOUR_REPOSITORY`,
`YOUR_PUBLISHER_SA_NAME`, `YOUR_WORKLOAD_SA_NAME`, `YOUR_GCS_BUCKET`,
`YOUR_AR_REPO`, `YOUR_STORE_1_CLUSTER`, `YOUR_STORE_2_CLUSTER`,
`YOUR_AGGREGATOR_CLUSTER`, `YOUR_STORE_CIDR`, `YOUR_SUPERLINK_ILB_IP`,
`YOUR_STORE_1_VLLM_LB_IP`, and `YOUR_STORE_2_VLLM_LB_IP`.

`apps/fed-lora/pyproject.toml` defaults to
`gcs-bucket = "gs://YOUR_GCS_BUCKET"`. Override that value in your private copy
or pass `--run-config 'gcs-bucket="gs://YOUR_GCS_BUCKET"'` at runtime so
`serverapp.py` and `clientapp.py` resolve the canonical `round-0` PEFT template
and round checkpoint prefixes.

---

## Configure placeholders and render FleetPackage manifests

Phase B starts by seeding your private GitHub repository from the published
solution package, substituting environment placeholders, and hydrating Kustomize
overlays into rendered environment manifests.

<!-- prettier-ignore -->
> [!CAUTION]
> Never use a public GitHub fork for rendered manifests because hydrated files
> embed your project ID, fleet membership names, and internal RFC 1918 IP
> addresses.

### Seed the private GitOps repository and replace placeholders

Clone `software-only/bare-metal/fed-lora` from
`GoogleCloudPlatform/gdc-solutions` into your private GitOps repository copy
(preserving the `software-only/bare-metal/fed-lora/` layout). If your private
repository already has commit history, clone it instead of running `git init`.
Strip upstream Git history, then substitute all fifteen `YOUR_*` placeholders
and release tags across `base/`, `overlays/`, `fleet-package/`, `docker/`,
`config/monitoring/`, `config/fed_lora_env.sh`, `apps/`, and `scripts/`:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
export PROJECT_NUMBER

SEED_TMP="$(mktemp -d)"
git clone --depth 1 --filter=blob:none --sparse \
  --branch "${SEED_REF}" "${SEED_REPO_URL}" "${SEED_TMP}"
git -C "${SEED_TMP}" sparse-checkout set "${SEED_SUBDIR}"

REPO_DIR="${SOLUTION_HOME}/${GITHUB_REPO}"
PKG_DIR="${REPO_DIR}/${SEED_SUBDIR}"
rm -rf "${REPO_DIR}"
mkdir -p "${PKG_DIR}"
cp -R "${SEED_TMP}/${SEED_SUBDIR}/." "${PKG_DIR}/"
rm -rf "${SEED_TMP}"

cd "${REPO_DIR}"
git init -b main

cd "${PKG_DIR}"
while IFS= read -r file; do
  sed -i \
    -e "s|YOUR_PROJECT_ID|${PROJECT_ID}|g" \
    -e "s|YOUR_PROJECT_NUMBER|${PROJECT_NUMBER}|g" \
    -e "s|YOUR_CONNECTION|${CB_CONNECTION}|g" \
    -e "s|YOUR_REPOSITORY|${CB_REPOSITORY}|g" \
    -e "s|YOUR_PUBLISHER_SA_NAME|${PUBLISHER_SA_NAME}|g" \
    -e "s|YOUR_WORKLOAD_SA_NAME|${WORKLOAD_SA_NAME}|g" \
    -e "s|YOUR_GCS_BUCKET|${GCS_BUCKET}|g" \
    -e "s|YOUR_AR_REPO|${AR_REPO}|g" \
    -e "s|YOUR_STORE_1_CLUSTER|${STORE1_CLUSTER_NAME}|g" \
    -e "s|YOUR_STORE_2_CLUSTER|${STORE2_CLUSTER_NAME}|g" \
    -e "s|YOUR_AGGREGATOR_CLUSTER|${GKE_CLUSTER_NAME}|g" \
    -e "s|YOUR_STORE_CIDR|${SUBNET_CIDR}|g" \
    -e "s|YOUR_SUPERLINK_ILB_IP|${FLWR_SERVER_INTERNAL_LB_IP}|g" \
    -e "s|YOUR_STORE_1_VLLM_LB_IP|${STORE1_VLLM_LB_IP}|g" \
    -e "s|YOUR_STORE_2_VLLM_LB_IP|${STORE2_VLLM_LB_IP}|g" \
    -e "s|tag: v1.0.0|tag: ${PACKAGE_RELEASE}|g" \
    -e "s|:v2.1.6|:${IMAGE_TAG}|g" \
    -e "s|_IMAGE_TAG: v2.1.6|_IMAGE_TAG: ${IMAGE_TAG}|g" \
    "${file}"
done < <(find base overlays fleet-package docker config/monitoring config/fed_lora_env.sh apps scripts -type f \( -name "*.yaml" -o -name "*.json" -o -name "*.py" -o -name "*.toml" -o -name "*.sh" \))
```

Verify `flwr-superlink-service` in
`base/flwr-server/gke-flwr-superlink-ilb-service.yaml` restricts ingress via
`loadBalancerSourceRanges` (populated from `YOUR_STORE_CIDR`). The `sed` pass
above automatically substitutes `loadBalancerIP`, `SUPERLINK_ADDRESS`, and
per-store `vllm-service` `loadBalancerIP` placeholders across `base/` and
`overlays/`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: flwr-superlink-service
  namespace: fed-lora-aggregator
  annotations:
    networking.gke.io/load-balancer-type: Internal
    networking.gke.io/internal-load-balancer-allow-global-access: "true"
spec:
  type: LoadBalancer
  loadBalancerIP: YOUR_SUPERLINK_ILB_IP
  loadBalancerSourceRanges:
    - YOUR_STORE_CIDR
  selector:
    app: flwr-superlink
  ports:
    - name: fleet-api
      protocol: TCP
      port: 9092
      targetPort: 9092
    - name: exec-api
      protocol: TCP
      port: 9093
      targetPort: 9093
```

### Example platform runtime parameters

The Kubernetes manifests ship with the following example platform defaults
(lab-validated on a 96 GB GPU; tune for your hardware and model before
rendering):

<!-- mdformat off -->

| Area                             | Package file(s)                                                      | Example values (lab-validated defaults, tune for your hardware)                                                                                                         | Role                                                                                                            |
| :------------------------------- | :------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------- |
| **vLLM serving & sleep handoff** | `base/vllm-serving/vllm-gemma4-deployment.yaml`                      | `--gpu-memory-utilization 0.85`, `--max-lora-rank 16`, `--enable-lora`, `--enable-sleep-mode`, `32Gi`/`64Gi` memory request/limit, `16Gi` `/dev/shm`                    | Daytime KV-cache fraction, adapter rank ceiling, shared memory, and host RAM headroom for Level-1 sleep offload |
| **Store pods & shared volume**   | `base/flwr-client/*.yaml`, `base/vllm-serving/shared-model-pvc.yaml` | `flwr-supernode --isolation process`, `flwr-trainer` `12Gi`/`16Gi` memory request/limit and `8Gi` `/dev/shm`, `50Gi` `shared-model-pvc`, `replicas: 2` GPU time-slicing | Subprocess-isolated QLoRA worker memory, shared memory, and node-local model/dataset storage                    |

<!-- mdformat on -->

For Flower application, local warm-start, federated aggregation, and canary gate
settings, see
[Example Flower app and algorithm parameters](user-guide.md#example-flower-app-and-algorithm-parameters)
in the SUG.

### Render environment manifests and push a tagged release

Config Sync rejects unrendered `Kustomization` files in Config Delivery bundles
with error `KNV2010`. Run `scripts/render_fleet_manifests.sh` inside
`${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}` to compile store and aggregator
overlays into flat `fleet-package/environments/*/manifests.yaml` files. Verify
zero drift with `--check`, then commit and push tag `${PACKAGE_RELEASE}`:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a
cd "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}"

! grep -rnE "YOUR_[A-Z0-9_]+" base/ overlays/ fleet-package/ docker/ config/monitoring/ config/fed_lora_env.sh apps/ scripts/

./scripts/render_fleet_manifests.sh
./scripts/render_fleet_manifests.sh --check

cd "${SOLUTION_HOME}/${GITHUB_REPO}"
git config user.name "Fed-LoRA Operator"
git config user.email "operator@example.com"
git add -A
git commit -m "Render Fed-LoRA fleet manifests for ${PACKAGE_RELEASE}"

git remote add origin "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git"
git push -u origin main
git tag "${PACKAGE_RELEASE}"
git push origin "${PACKAGE_RELEASE}"
```

Confirm `./scripts/render_fleet_manifests.sh --check` exits `0` with zero
manifest drift and `git ls-remote --tags origin "${PACKAGE_RELEASE}"` lists the
pushed tag.

---

## Build container images with Cloud Build

Build and push the two pre-baked runtime images into
`${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}` using
`docker/cloudbuild-images.yaml` so store and central pods start
deterministically without runtime `pip install` calls:

- **`flwr-trainer:${IMAGE_TAG}` (`docker/Dockerfile.trainer`):** Extends Vertex
  AI Model Garden
  `us-docker.pkg.dev/vertex-ai/vertex-vision-model-garden-dockers/pytorch-vllm-serve:gemma4`
  with `flwr[rest]==1.36.0`, `peft`, `bitsandbytes`, `datasets`,
  `google-cloud-storage`, and `safetensors`, running as non-root
  `uid=1000:gid=2000`.
- **`flwr-superlink:${IMAGE_TAG}` (`docker/Dockerfile.superlink`):** Extends
  `flwr/superlink:1.36.0` with the OpenMetrics exporter (`:9100/metrics`) and
  `--disable-runtime-dependency-installation`.

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a
cd "${SOLUTION_HOME}/${GITHUB_REPO}"

gcloud builds submit "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --config="${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/docker/cloudbuild-images.yaml" \
  --substitutions="_AR_LOCATION=${REGION},_AR_REPOSITORY=${AR_REPO},_IMAGE_TAG=${IMAGE_TAG}"

gcloud artifacts docker images list \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}" \
  --project="${PROJECT_ID}" \
  --include-tags --format="table(package,tags)"
```

The Cloud Build image build takes about 10 minutes (lab-observed example:
`10m 10s`). Confirm `gcloud artifacts docker images list` prints both
`flwr-trainer` and `flwr-superlink` tagged with `${IMAGE_TAG}`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Cloud Build > History](https://console.cloud.google.com/cloud-build/builds)
  page in `${REGION}`, the `cloudbuild-images.yaml` build completes with status
  `Success`.
- On the
  [Artifact Registry > Repositories](https://console.cloud.google.com/artifacts)
  page, open `${AR_REPO}` and verify `flwr-trainer` and `flwr-superlink` both
  carry tag `${IMAGE_TAG}`.

---

## Deploy FleetPackages and verify workload rollout

### Bind IAM policies, grant Config Delivery RBAC, and bootstrap store secrets

Create the service accounts and Workload Identity bindings, then grant Config
Delivery RBAC for `RootSync` resources on all three clusters. Seed the
out-of-Git Kubernetes secrets (`hf-token-secret` and initial `ar-pull-secret`)
on both stores:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
export PROJECT_NUMBER

for sa in "${WORKLOAD_SA_NAME}" "${PUBLISHER_SA_NAME}"; do
  gcloud iam service-accounts describe "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="${PROJECT_ID}" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "${sa}" --project="${PROJECT_ID}"
done

for role in roles/configdelivery.resourceBundlePublisher roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="${role}" --condition=None >/dev/null
done

gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${WORKLOAD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" >/dev/null

for ns in "${EDGE_NAMESPACE}" "${CENTRAL_NAMESPACE}"; do
  gcloud iam service-accounts add-iam-policy-binding \
    "${WORKLOAD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="${PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${ns}/default]" >/dev/null
done

gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --role="roles/artifactregistry.reader" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${EDGE_NAMESPACE}/sa/ar-pull-refresher" >/dev/null

for ctx in central-ctx store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" create namespace config-management-system \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  kubectl --context="${ctx}" apply -f "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/fleet-package/configdelivery-rbac.yaml"
done

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" create namespace "${EDGE_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --from-literal=token="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  ACCESS_TOKEN="$(gcloud auth print-access-token)"
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" create secret docker-registry ar-pull-secret \
    --docker-server="${REGION}-docker.pkg.dev" \
    --docker-username=oauth2accesstoken \
    --docker-password="${ACCESS_TOKEN}" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
done
```

<!-- prettier-ignore -->
> [!NOTE]
> After the edge `FleetPackage` reconciles, `CronJob/ar-pull-refresher`
> refreshes `Secret/ar-pull-secret` in both `${EDGE_NAMESPACE}` and `gmp-system`
> every 30 minutes via Fleet Workload Identity STS token exchange
> (`docker.io/library/python:3.12-slim`).

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [IAM & Admin > Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts)
  page, both `${WORKLOAD_SA_NAME}` and `${PUBLISHER_SA_NAME}` appear in
  `${PROJECT_ID}`.

### Label fleet memberships and create the FleetPackages

Apply selector labels (`--location="${REGION}"` for GKE; `--location=global` for
stores) and create `fed-lora-central-package` followed by
`fed-lora-edge-package`. Inspect `fleet-package/fleetpackage-edge.yaml` to
verify `path: software-only/bare-metal/fed-lora/fleet-package/environments` and
`variantNameTemplate: ${membership.labels['store']}` route each store variant.
If you copied `software-only/bare-metal/fed-lora/` directly to the repository
root, shorten `path` to `fleet-package/environments`:

```yaml
deletionPropagationPolicy: FOREGROUND
resourceBundleSelector:
  cloudBuildRepository:
    name: projects/YOUR_PROJECT_ID/locations/us-central1/connections/YOUR_CONNECTION/repositories/YOUR_REPOSITORY
    path: software-only/bare-metal/fed-lora/fleet-package/environments
    serviceAccount: projects/YOUR_PROJECT_ID/serviceAccounts/YOUR_PUBLISHER_SA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com
    tag: v1.0.0
rolloutStrategy:
  rolling:
    maxConcurrent: 2
target:
  fleet:
    project: projects/YOUR_PROJECT_ID
    selector:
      matchLabels:
        app-tier: fed-lora-edge
variantSelector:
  variantNameTemplate: ${membership.labels['store']}
```

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

gcloud container fleet memberships update "${GKE_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --update-labels="app-tier=fed-lora-aggregator"

gcloud container fleet memberships update "${STORE1_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location=global \
  --update-labels="app-tier=fed-lora-edge,store=store-1"

gcloud container fleet memberships update "${STORE2_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location=global \
  --update-labels="app-tier=fed-lora-edge,store=store-2"

gcloud container fleet packages create fed-lora-central-package \
  --source="${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/fleet-package/fleetpackage-central.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

gcloud container fleet packages create fed-lora-edge-package \
  --source="${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/fleet-package/fleetpackage-edge.yaml" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

<!-- prettier-ignore -->
> [!NOTE]
> Config Delivery forbids switching `resourceBundleSelector` between
> `resourceBundle` and `cloudBuildRepository` on an existing `FleetPackage`. To
> migrate from an OCI-bundle `FleetPackage`, suspend it with
> `deletionPropagationPolicy: ORPHAN` and orphan-delete its `RootSync`
> (`configsync.gke.io/deletion-propagation-policy=Orphan`) first. Creating the
> `cloudBuildRepository` `FleetPackage` then adopts live workloads in place
> (lab-observed example: `0` `flwr-superlink` restarts).

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Fleets](https://console.cloud.google.com/kubernetes/fleet)
  page, the GKE aggregator shows label `app-tier=fed-lora-aggregator` and stores
  show `app-tier=fed-lora-edge` plus `store=store-1` or `store=store-2`.
- On the
  [Kubernetes Engine > Config](https://console.cloud.google.com/kubernetes/config_management)
  page, open **Packages** to verify `fed-lora-central-package` and
  `fed-lora-edge-package` initiate rollouts for `${PACKAGE_RELEASE}`.
- On the
  [Cloud Build > History](https://console.cloud.google.com/cloud-build/builds)
  page in `${REGION}`, confirm the auto-created Config Delivery bundle builds
  finish with status `Success`.

### Verify FleetPackage rollout and pod readiness

Poll `FleetPackage` rollouts and `RootSync` objects directly on each cluster.
Verify central `SuperLink` (ports 9092, 9093, and 9100), store workloads
(`vllm-gemma4` port 8000, `flwr-supernode` port 9094, `flwr-trainer` port 9100),
`shared-model-pvc`, and all four `PodMonitoring` resources (including DCGM port
9400). Because `Deployment/vllm-gemma4` defines no startup or readiness probe,
Kubernetes marks the pod `1/1 Ready` about 160 seconds before `:8000` serves
traffic. Poll `GET /v1/models` on `:8000` until HTTP `200` instead of trusting
`rollout status` alone.

<!-- prettier-ignore -->
> [!NOTE]
> Do not use `gcloud beta container fleet config-management status` to judge
> rollout health; it can falsely report `NOT_INSTALLED` or `NOT_CONFIGURED` on
> Config Delivery clusters even while `RootSync` objects report `SYNCED`.

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for pkg in fed-lora-central-package fed-lora-edge-package; do
  gcloud container fleet packages rollouts list \
    --fleet-package="${pkg}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
done

for ctx in central-ctx store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n config-management-system \
    get rootsyncs.configsync.gke.io \
    -o custom-columns="NAME:.metadata.name,LAST_SYNCED:.status.lastSyncedCommit,RENDER_ERRS:.status.rendering.errorSummary,SYNC_ERRS:.status.sync.errorSummary"
done

kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
  rollout status deployment/flwr-superlink --timeout=180s
kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
  get svc flwr-superlink-service -o wide
kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
  get podmonitoring flwr-superlink-monitoring

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" \
    get pvc shared-model-pvc
  for deploy in vllm-gemma4 flwr-supernode flwr-trainer; do
    kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" \
      rollout status "deployment/${deploy}" --timeout=600s
  done
  for attempt in {1..36}; do
    if kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
      curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/models" >/dev/null; then
      echo "${ctx}: vllm-service:8000 serving HTTP 200 (attempt ${attempt})"
      break
    fi
    test "${attempt}" -lt 36
    sleep 10
  done
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" \
    get podmonitoring vllm-gemma4-monitoring flwr-trainer-monitoring
  kubectl --context="${ctx}" -n gpu-operator \
    get podmonitoring nvidia-dcgm-exporter-monitoring
done
```

Confirm both `FleetPackage` rollouts reach `COMPLETED` and every `RootSync`
reports `LAST_SYNCED` with empty `RENDER_ERRS` and `SYNC_ERRS`. Verify
`flwr-superlink-service` binds `${FLWR_SERVER_INTERNAL_LB_IP}` on `9092/TCP` and
`9093/TCP`, `shared-model-pvc` is `Bound`, all deployments report `1/1`, and
`:8000/v1/models` returns HTTP `200` on every store.

In lab validation of a central `cloudBuildRepository` `FleetPackage` using
`path: software-only/bare-metal/fed-lora/fleet-package/environments`,
auto-triggered Cloud Build OCI hydration took `129 s` (`140 s` from creation).
Config Delivery rollout then completed in `30 s` and `RootSync` converged in
`21 s` (`0` `flwr-superlink` restarts on in-place adoption).

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Config](https://console.cloud.google.com/kubernetes/config_management)
  page, both `FleetPackage` entries show `Active` and every cluster's `RootSync`
  shows `Synced` with zero errors.
- On the
  [Kubernetes Engine > Workloads](https://console.cloud.google.com/kubernetes/workload)
  page, `flwr-superlink` in `${CENTRAL_NAMESPACE}` plus `vllm-gemma4`,
  `flwr-supernode`, and `flwr-trainer` in `${EDGE_NAMESPACE}` all show `OK`
  (`1/1`).

### Deploy the Cloud Monitoring dashboard

Deploy the four-quadrant Cloud Monitoring dashboard
(`config/monitoring/fed-lora-demo-dashboard.json`) into `${PROJECT_ID}` so GMP
metrics and structured container logs are ready for platform verification and
Day-2 rounds:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

"${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/scripts/deploy_demo_dashboard.sh" \
  --project="${PROJECT_ID}"
```

Confirm the script exits `0` and prints the custom dashboard resource ID and
console URL.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Monitoring > Dashboards](https://console.cloud.google.com/monitoring/dashboards)
  page, open the Fed-LoRA dashboard and verify all four metric quadrants and the
  structured log panel load.

---

## Verification

Run the three independent platform checks below to confirm the deployed
infrastructure is healthy before installing any Flower application. Building
`.fab` bundles, running local warm-start and Round-0 seeding, and executing
federated rounds live in the [Solution User Guide (SUG)](user-guide.md).

### Verify Flower Control API and SuperNode registration

Configure the workstation Flower connection profile (`~/.flwr/config.toml`) and
open a port-forward to `flwr-superlink-service:9093`. From any directory without
an app bundle, confirm `flwr-supernode` pods are `1/1 Ready` (`:9094`) and the
federation is active on `:9093`. Confirm every store `SuperNode` reports
`online` over `:9092` and the run table is empty:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" \
    get pods -l app=flwr-supernode --field-selector=status.phase=Running \
    -o custom-columns="POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"
done

kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
  port-forward svc/flwr-superlink-service 19093:9093 \
  >"${SOLUTION_HOME}/superlink-pf.log" 2>&1 &
echo $! > "${SOLUTION_HOME}/superlink-pf.pid"
sleep 3

mkdir -p "${HOME}/.flwr"
cat <<'EOF' > "${HOME}/.flwr/config.toml"
[superlink]
default = "gke-superlink"

[superlink.gke-superlink]
address = "127.0.0.1:19093"
insecure = true
EOF

cd "${SOLUTION_HOME}"
flwr federation list gke-superlink
flwr supernode list gke-superlink
flwr supernode list gke-superlink --format json
flwr ls gke-superlink
```

Confirm both `flwr-supernode` pods show `READY=true`, `flwr federation list`
returns an active federation over `127.0.0.1:19093`, `flwr supernode list` lists
every store `SuperNode` as `online`, and `flwr ls` returns an empty run table.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Kubernetes Engine > Workloads](https://console.cloud.google.com/kubernetes/workload)
  page, `flwr-superlink` and both `flwr-supernode` deployments show `OK`
  (`1/1`).
- In [Logging > Logs Explorer](https://console.cloud.google.com/logs/query), run
  `resource.type="k8s_container" AND resource.labels.namespace_name=("fed-lora-poc" OR "fed-lora-aggregator") AND resource.labels.container_name=("flwr-superlink" OR "flwr-supernode")`
  to verify clean startup logs without gRPC errors.

### Verify base-model serving and store data sovereignty

Confirm each store's `vllm-gemma4` server (`:8000`) lists only base model
`google/gemma-4-E2B-it` and answers a base chat completion. Verify each store's
PVC dataset (`/mnt/models/edge-data/store-N/train.jsonl`) matches
`overlays/store-N/data/train.jsonl` SHA-256 while `gs://${GCS_BUCKET}` contains
zero `.jsonl` files:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for idx in 1 2; do
  ctx="store-${idx}-ctx"
  repo_sha="$(sha256sum "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/overlays/store-${idx}/data/train.jsonl" | awk '{print $1}')"
  pvc_sha="$(kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    sha256sum "/mnt/models/edge-data/store-${idx}/train.jsonl" | awk '{print $1}')"
  echo "${ctx} train.jsonl sha256=${pvc_sha}"
  test "${pvc_sha}" = "${repo_sha}"

  models_json="$(kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/models")"
  echo "${ctx} models:"
  echo "${models_json}" | jq -r '.data[].id'

  reply="$(kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"google/gemma-4-E2B-it","max_tokens":32,"temperature":0.0,"messages":[{"role":"user","content":"Reply with OK."}]}' \
    | jq -re '.choices[0].message.content')"
  echo "${ctx} base completion: ${reply}"
done

! gcloud storage ls "gs://${GCS_BUCKET}/**/*.jsonl" --project="${PROJECT_ID}" 2>/dev/null
```

Confirm each store prints a matching SHA-256 hash, lists only
`google/gemma-4-E2B-it`, returns a non-empty base completion, and finds zero
`.jsonl` files in `gs://${GCS_BUCKET}`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Cloud Storage > Buckets](https://console.cloud.google.com/storage/browser)
  page, open `${GCS_BUCKET}` and verify zero `.jsonl` training files exist in
  the bucket.

### Verify observability endpoints, metrics, and dashboard

Verify `:9100/metrics` exposes `fed_lora_supernode_up` (`1`) and
`fed_lora_vllm_up` (`1`) on both stores, `flwr-superlink` exposes
`fed_lora_current_round` (`0`), and Cloud Monitoring registers the custom
dashboard:

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

for ctx in store-1-ctx store-2-ctx; do
  metrics_out="$(kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf http://127.0.0.1:9100/metrics)"
  echo "${ctx}:"
  echo "${metrics_out}" | grep -E "^fed_lora_(supernode_up|vllm_up)"
  echo "${metrics_out}" | grep -Eq "^fed_lora_supernode_up.* 1$"
  echo "${metrics_out}" | grep -Eq "^fed_lora_vllm_up.* 1$"
done

kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" exec deploy/flwr-superlink -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=5).read().decode())" \
  | grep -E "^fed_lora_current_round"

DASHBOARD_NAME="$(jq -r '.displayName' "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/config/monitoring/fed-lora-demo-dashboard.json")"
gcloud monitoring dashboards list \
  --project="${PROJECT_ID}" \
  --filter="displayName=\"${DASHBOARD_NAME}\"" \
  --format="value(name,displayName)"
```

Confirm both stores report `fed_lora_supernode_up` and `fed_lora_vllm_up` equal
to `1`, `flwr-superlink` exports `fed_lora_current_round`, and
`gcloud monitoring dashboards list` prints the deployed dashboard.

[Cloud Console Verification] In the Google Cloud console, confirm:

- On the
  [Monitoring > Dashboards](https://console.cloud.google.com/monitoring/dashboards)
  page, open the Fed-LoRA dashboard and verify baseline GPU memory and serving
  charts populate.
- In
  [Monitoring > Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer),
  run `fed_lora_supernode_up{namespace="fed-lora-poc"}`,
  `fed_lora_vllm_up{namespace="fed-lora-poc"}`,
  `DCGM_FI_DEV_FB_USED{namespace="gpu-operator"}`, and
  `vllm:kv_cache_usage_perc{namespace="fed-lora-poc"}` to verify active store
  series (`1` for both health gauges).
- In [Logging > Logs Explorer](https://console.cloud.google.com/logs/query), run
  `resource.type="k8s_container" AND resource.labels.namespace_name=("fed-lora-poc" OR "fed-lora-aggregator")`
  to confirm edge and aggregator container logs stream.

---

## Operations

For building Flower app bundles, running local warm-start and federated rounds,
and Day-2 operations, see the [Solution User Guide (SUG)](user-guide.md).

---

## Troubleshooting

<!-- mdformat off -->

| Symptom                                                                                 | Cause                                                                    | Resolution                                                                                                                                                                           |
| :-------------------------------------------------------------------------------------- | :----------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FleetPackage` rollout fails with `KNV2010` (`Kustomization` not hydrated)              | Raw `kustomization.yaml` was placed inside `fleet-package/environments/` | Keep overlays under `overlays/` only and hydrate flat `manifests.yaml` files via `./scripts/render_fleet_manifests.sh`                                                               |
| `FleetPackage` rollout stalls with `403 Forbidden` on `rootsyncs.configsync.gke.io`     | Config Delivery service agent lacks RBAC in `config-management-system`   | Apply `${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/fleet-package/configdelivery-rbac.yaml` on the affected cluster context                                                        |
| `gcloud container fleet memberships update` returns `NOT_FOUND` during initial labeling | Membership location flag (`--location`) mismatches cluster platform type | Use `--location=global` for Distributed Cloud software only store memberships and `--location="${REGION}"` for the GKE aggregator membership                                         |
| `FleetPackage` release creation fails with `PERMISSION_DENIED` publishing OCI bundle    | `${PUBLISHER_SA_NAME}` lacks Config Delivery publisher IAM role          | Grant `roles/configdelivery.resourceBundlePublisher`, `roles/artifactregistry.writer`, and `roles/logging.logWriter` to `${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com` |

<!-- mdformat on -->

For Day-2 training, observability, pull-secret rotation, GPU time-slicing,
sleep-mode, and LoadBalancer firewall troubleshooting, see
[Troubleshooting](user-guide.md#troubleshooting) in the SUG.

---

## Clean up

Remove Phase B resources in reverse deployment order so Config Delivery cleanly
prunes cluster workloads without orphaning `RootSync` objects or disrupting
pre-deployed Phase A infrastructure.

<!-- prettier-ignore -->
> [!CAUTION]
> Never delete shared Artifact Registry repositories used by other
> `FleetPackage` bundles, container workloads, or teams; delete only the
> `flwr-trainer` and `flwr-superlink` image packages or a dedicated
> single-purpose repository.

```bash
set -a; source "${SOLUTION_HOME}/.env"; set +a

if [[ -f "${SOLUTION_HOME}/superlink-pf.pid" ]]; then
  kill "$(cat "${SOLUTION_HOME}/superlink-pf.pid")" 2>/dev/null || true
  rm -f "${SOLUTION_HOME}/superlink-pf.pid"
fi

DASHBOARD_JSON="${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/config/monitoring/fed-lora-demo-dashboard.json"
if [[ -f "${DASHBOARD_JSON}" ]]; then
  DASHBOARD_NAME="$(jq -r '.displayName' "${DASHBOARD_JSON}")"
  DASHBOARD_ID="$(gcloud monitoring dashboards list --project="${PROJECT_ID}" \
    --filter="displayName=\"${DASHBOARD_NAME}\"" --format="value(name)" | head -n 1 || true)"
  if [[ -n "${DASHBOARD_ID}" ]]; then
    gcloud monitoring dashboards delete "${DASHBOARD_ID}" --project="${PROJECT_ID}" --quiet
  fi
fi

for membership in "${STORE1_CLUSTER_NAME}" "${STORE2_CLUSTER_NAME}"; do
  gcloud container fleet memberships update "${membership}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --remove-labels="app-tier,store"
done

gcloud container fleet memberships update "${GKE_CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --remove-labels="app-tier"

for pkg in fed-lora-edge-package fed-lora-central-package; do
  gcloud container fleet packages delete "${pkg}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --force \
    --quiet
done

for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" \
    delete secret hf-token-secret ar-pull-secret --ignore-not-found
done

for ctx in store-1-ctx store-2-ctx central-ctx; do
  kubectl --context="${ctx}" delete --ignore-not-found \
    -f "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}/fleet-package/configdelivery-rbac.yaml"
done

gcloud storage rm --recursive \
  "gs://${GCS_BUCKET}/checkpoints/**" \
  "gs://${GCS_BUCKET}/adapters/**" \
  --project="${PROJECT_ID}" 2>/dev/null || true

for img in flwr-trainer flwr-superlink; do
  gcloud artifacts docker images delete \
    "${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${img}:${IMAGE_TAG}" \
    --delete-tags --quiet 2>/dev/null || true
done

rm -rf "${SOLUTION_HOME}"
```

Removing membership labels lets Config Delivery prune `fed-lora-poc` and
`fed-lora-aggregator` workloads while
`client.lifecycle.config.k8s.io/deletion: detach` preserves the `kube-system`
observability resource. Phase A retains `ConfigMap/time-slicing-config` and
`ClusterPolicy/cluster-policy` outside the `FleetPackage`.

---

## What's next

- Follow the [Solution User Guide (SUG)](user-guide.md) to build the Flower App
  Bundle (`.fab`), run local warm-start and Round-0 seeding, execute federated
  rounds, and manage Day-2 operations.
- Review the architecture diagram, VRAM budget formula, and design decisions in
  the [Solution Reference Architecture (SRA)](../README.md).
