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

# Deployment Guide: Edge-to-Cloud Federated Learning (Fed-LoRA) Turnkey Demo Lab

This deployment guide provides the end-to-end technical procedures for
provisioning, configuring, and verifying the demo infrastructure deployed via
GitOps and runtime services required for the **Edge-to-Cloud Federated Learning
(Fed-LoRA) Turnkey Demonstration**. It covers prerequisite infrastructure,
Config Sync and Fleet Package setup, runtime service activation, and manual
inspection commands across Google Distributed Cloud (GDC) Software-Only edge
clusters and the central Google Kubernetes Engine (GKE) aggregator.

📌 **NOTE:** For the architectural overview and key tenets of this solution, see
[Solution Architecture & Business Overview](../README.md#1-solution-architecture--business-overview).

---

## 1. Lab Prerequisites (Pre-Provisioned Infrastructure)

Before configuring the turnkey GitOps demonstration suite, ensure the following
workstation tools, core infrastructure, hardware, credentials, and network
routing preconditions are established in Google Cloud and the local environment.

### 1.1. Workstation Tools & Client Libraries

Ensure the following tools and CLI utilities are installed on the operator
workstation with matching recommended versions:

<!-- mdformat off -->

| Tool / Utility                                 | Recommended Version                              | Purpose                                                                              | Installation / Verification Command                                              |
| :--------------------------------------------- | :----------------------------------------------- | :----------------------------------------------------------------------------------- | :------------------------------------------------------------------------------- |
| **Google Cloud CLI (`gcloud`)**                | `510.0.0+` (or `490.0.0+`)                       | GCP resource management & Fleet operations                                           | `gcloud version` (requires `gke-gcloud-auth-plugin`, `alpha`, `beta` components) |
| **Kubernetes CLI (`kubectl`)**                 | `v1.30+` / `v1.35+` / `v1.36+`                   | Cluster inspection & manifest application                                            | `kubectl version --client`                                                       |
| **Anthos Config Management CLI (`nomos`)**     | `v1.18+` or later                                | Config Sync status and syntax validation                                             | `nomos version` (install via `gcloud components install nomos`)                  |
| **Helm Package Manager (`helm`)**              | `v3.14+` or `v3.16+`                             | NVIDIA GPU Operator deployment                                                       | `helm version --short`                                                           |
| **Flower Framework CLI (`flwr`)**              | `1.36.0` (`flwr[rest]==1.36.0`, image `v2.1.12`) | Federated training run dispatch (`--control-api-address 0.0.0.0:9093`) & node audits | `flwr --version` (install via `pip install "flwr[rest]==1.36.0"`)                |
| **Core Utilities (`curl`, `jq`, `git`, `nc`)** | Latest system packages                           | REST querying, JSON parsing, git operations                                          | `git --version && jq --version && curl --version`                                |
| **Python Runtime**                             | `3.10`–`3.12`                                    | Local test scripts & payload generation                                              | `python3 --version`                                                              |

<!-- mdformat on -->

### 1.2. Kubernetes Clusters & Host Node VMs

Deploy three dedicated Kubernetes clusters within a unified Google Cloud VPC
network:

📌 **NOTE on Virtualized Lab Environment:** This demonstration lab is built on a
fully virtualized environment hosted in Google Cloud, specifically using Google
Compute Engine (GCE) VMs to emulate bare-metal nodes that would normally be
physically hosted inside retail stores running GDC Software-Only bare-metal
clusters. The identical declarative manifests, Config Sync pipelines, and
automation scripts can be directly reused to run on real GDC Software-Only
bare-metal physical servers in production stores without modification.

1.  **Central GKE Aggregator Cluster
    (`${GKE_AGGREGATOR_CLUSTER:-YOUR_AGGREGATOR_CLUSTER}`):**
    - **Location & Version:** `us-central1-b` (zonal) or `us-central1`
      (regional), GKE release `v1.35+` or `v1.36+`.
    - **Networking:** VPC-Native (`10.200.0.0/24` primary subnet), registered to
      Google Cloud GKE Fleet with label `app-tier=fed-lora-aggregator`.
    - **Documentation:** Consult
      [Google Kubernetes Engine Documentation](https://docs.cloud.google.com/kubernetes-engine/docs)
      for detailed deployment and installation guidelines.
2.  **2x GDC Software-Only Edge Clusters
    (`${STORE1_CLUSTER:-YOUR_STORE_1_CLUSTER}` and
    `${STORE2_CLUSTER:-YOUR_STORE_2_CLUSTER}`):**

    - **Platform & Version:** Google Distributed Cloud (software only) for bare
      metal, release **`1.36.0-gke.532`** (Kubernetes `v1.36.0-gke.2800`).
    - **Edge Hardware VMs:** Deployed on Google Compute Engine `g4-standard-48`
      Spot VMs (48 vCPUs, 192 GB RAM, 1x NVIDIA RTX PRO 6000 Blackwell GPU, 200
      GB SSD boot disk, Ubuntu 22.04 LTS).
    - **Kernel & Headers:** Matching Linux kernel headers
      (`linux-headers-$(uname -r) build-essential`) and tuned inotify limits
      (`fs.inotify.max_user_instances=8192` in
      `/etc/sysctl.d/99-gdc-so-gpu.conf`).
    - **Alias IP CIDRs (`--can-ip-forward`):** GCE instances require secondary
      alias IP ranges to route MetalLB Layer 2 ARP announcements without
      physical network collisions:
      - Node 1 (`${STORE1_CLUSTER}`): Primary IP `10.200.0.11`, Alias Range
        `10.200.0.128/28` (Control Plane `10.200.0.129`, Ingress `10.200.0.130`,
        MetalLB VIP pool `10.200.0.131-10.200.0.142`).
      - Node 2 (`${STORE2_CLUSTER}`): Primary IP `10.200.0.12`, Alias Range
        `10.200.0.160/28` (Control Plane `10.200.0.161`, Ingress `10.200.0.162`,
        MetalLB VIP pool `10.200.0.163-10.200.0.174`).

    📌 **NOTE on IP Address Allocation:** IP address allocations (Node IPs,
    Control Plane VIPs, Ingress VIPs, and MetalLB address pools) must strictly
    follow the VPC network and subnet CIDR configuration established in your GCP
    project. The IP values specified in this guide (`10.200.0.x`) are provided
    as concrete examples matching the reference lab setup.

    - **Cluster Management:** Registered to Google Cloud GKE Fleet with label
      `app-tier=fed-lora-edge` and accessible via Google Cloud Connect Gateway.
    - **Documentation:** Consult
      [Google Distributed Cloud (software only) for bare metal documentation](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
      for deployment and installation instructions.

### 1.3. NVIDIA GPU Operator Installation (Blackwell Architecture)

The edge clusters require the official NVIDIA GPU Operator installed via Helm in
namespace `gpu-operator`.

- **Operator Version:** `v26.7.0` (or later).
- **Mandatory Open Kernel Module Configuration:** The NVIDIA RTX PRO 6000
  Blackwell GPU (`PCI ID 10de:2bb1`) running on Linux kernel 6.8+ requires the
  open-source kernel module driver (`595.91.07`):

  ```bash
  helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --version 26.7.0 \
    --set driver.enabled=true \
    --set driver.version=595.91.07 \
    --set driver.kernelModuleType=open
  ```

- **Documentation:** Consult
  [NVIDIA GPU Operator on GDC Guide](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu)
  for deployment and installation instructions.

### 1.4. User Credentials & Access Tokens

1.  **Hugging Face User Access Token (`HF_TOKEN`):**
    - Access to gated foundation weights for `google/gemma-4-E2B-it`.
    - Configured as environment variable in `.env` and deployed to namespace
      `fed-lora-poc` as secret `hf-token-secret`.
2.  **Cloud Build 2nd-Generation GitHub Connection (`YOUR_CONNECTION` /
    `YOUR_REPOSITORY`):**
    - Connects Google Cloud Config Delivery (`FleetPackage`) in `us-central1` to
      your **private** GitHub repository copy containing substituted `YOUR_*`
      environment values and rendered
      `software-only/bare-metal/fed-lora/fleet-package/environments` manifests
      (paired with publisher service account
      `YOUR_PUBLISHER_SA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com`; see
      [`../README.md`](../README.md)).
3.  **Artifact Registry Image Pull & Edge GCS Credentials (`ar-pull-secret` &
    Fleet Workload Identity):**
    - **Central GKE Cluster (`YOUR_AGGREGATOR_CLUSTER`):** No `imagePullSecret`
      is required. GKE worker nodes natively authenticate to private Artifact
      Registry repositories
      (`us-central1-docker.pkg.dev/${PROJECT_ID}/YOUR_AR_REPO`) via the node
      pool's attached IAM Service Account (`roles/artifactregistry.reader`), and
      `Deployment/flwr-superlink` authenticates to GCS via GKE Workload Identity
      (`ServiceAccount/default` $\rightarrow$ `YOUR_WORKLOAD_SA_NAME`).
    - **GDC Software-Only Edge Clusters (`YOUR_STORE_1_CLUSTER`,
      `YOUR_STORE_2_CLUSTER`):** Bare-metal Ubuntu 22.04 host nodes run upstream
      `containerd` and require a `kubernetes.io/dockerconfigjson` pull secret
      named `ar-pull-secret` in namespace `fed-lora-poc` (referenced via
      `imagePullSecrets: [{name: ar-pull-secret}]` on
      `deployment/flwr-trainer`). Because organization policy enforces
      `constraints/iam.disableServiceAccountKeyCreation`, credentials are
      managed via GKE Hub **Fleet Workload Identity**:
      - **Image Pull Refresher (`CronJob/ar-pull-refresher`):** Runs every 30
        minutes using `docker.io/library/python:3.12-slim` under
        `ServiceAccount/ar-pull-refresher` (bound directly to
        `roles/artifactregistry.reader` on `YOUR_AR_REPO` via
        `serviceAccount:${PROJECT_ID}.svc.id.goog[fed-lora-poc/ar-pull-refresher]`),
        exchanging its projected KSA JWT at
        `https://sts.googleapis.com/v1/token` and updating
        `secret/ar-pull-secret` in-place with zero GCS permissions.
      - **Edge Trainer GCS ADC (`ConfigMap/fleet-wi-credentials-config`):**
        Mounted into `deployment/flwr-trainer` along with a projected KSA token
        (`/var/run/secrets/tokens/gcp-ksa/token`) and referenced via
        `GOOGLE_APPLICATION_CREDENTIALS=/etc/workload-identity/fleet-wi-config.json`
        so `google.cloud.storage.Client()` transparently impersonates
        `YOUR_WORKLOAD_SA_NAME@${PROJECT_ID}.iam.gserviceaccount.com`.
      - **Initial Out-of-Band Bootstrap:** Run
        `./scripts/apply_cluster_secrets.sh` before or during initial cluster
        bring-up to seed `fed-lora-poc/hf-token-secret` and
        `fed-lora-poc/ar-pull-secret` via Fleet Workload Identity STS token
        exchange.

### 1.5. Shared Cloud Storage Bucket (`gs://${GCS_BUCKET_NAME}`) & Store-Local Training Data

A regional Cloud Storage bucket configured in `us-central1` holds model
artifacts (aggregated round checkpoints and baseline backups) only:

```text
gs://YOUR_GCS_BUCKET/
├── checkpoints/
│   ├── round-1/                     # Global FedLoRA checkpoint & metadata
│   └── baseline-backup/             # Pre-federation baseline backups
└── models/                          # Shared model artifact cache
```

📌 **NOTE on Data Sovereignty & Store-Local Dataset Architecture:** Training
data stays exclusively on the store node (`PVC` at
`/mnt/models/edge-data/store-{1,2}/train.jsonl`), never in Cloud Storage. In
this demonstration lab, each store's private dataset
(`overlays/store-{1,2}/data/train.jsonl`) is seeded declaratively onto the
node's local Persistent Volume (`ConfigMap/store-training-data` $\rightarrow$
`PVC` via the `seed-store-training-data` initContainer). In a production
enterprise environment, `/mnt/models/edge-data/store-{store_id}/train.jsonl` is
produced directly by the store's own local POS/edge systems, while the central
Cloud Storage bucket (`gs://${GCS_BUCKET_NAME}`) holds model artifacts only.

Google Cloud IAM Workload Identity Service Account (WISA) bindings must be
configured so GKE and GDC edge nodes read and write model checkpoints without
ambient credentials.

### 1.6. Network Routing & Firewall Rules

Ensure VPC firewall rules allow unobstructed bidirectional Layer 3/4 traffic.
This is especially true when the GDC Software-Only edge clusters are attached
directly to the same Google Cloud VPC network as the central GKE cluster:

- `${VPC_NAME}-allow-internal`: Allows `tcp,udp,icmp,ipip` across `10.0.0.0/24`
  and `10.200.0.0/24` (covering node IPs, alias VIPs, and GKE Pod/Service
  CIDRs).
- Central Flower SuperLink: Inbound TCP `9092` (Fleet API) and TCP `9093` (Exec
  API) to Internal LoadBalancer IP `${SUPERLINK_ILB_IP}` (e.g. `10.200.0.50`),
  restricted to edge store CIDRs via
  `spec.loadBalancerSourceRanges: [YOUR_STORE_CIDR]`.
- Edge vLLM Serving: Inbound TCP `8000` to Store 1 (`${STORE1_VLLM_VIP}`, e.g.
  `10.200.0.131`) and Store 2 (`${STORE2_VLLM_VIP}`, e.g. `10.200.0.163`).
- Edge SuperNodes: Zero inbound ports required (dial outbound to SuperLink).

### 1.7. Google Cloud Managed Service for Prometheus (GMP) & Application Logging (`Stackdriver` Custom Resource)

By default on Google Distributed Cloud (software only) bare-metal edge clusters,
the `stackdriver-operator` (`kube-system/stackdriver`) exports system
control-plane metrics and logs, while keeping application-level Prometheus
scraping (`spec.enableGMPForApplications`) and customer namespace log forwarding
(`spec.enableCloudLoggingForApplications`) disabled (`false`).

To enable end-to-end Google Cloud Observability (`PodMonitoring` CRDs in
`fed-lora-poc` and `gpu-operator`, plus structured JSON container logs from
`flwr-trainer`, `flwr-supernode`, and `vllm-gemma4`), this repository
declaratively reconciles the singleton `addons.gke.io/v1alpha1`
`Kind: Stackdriver` resource (`base/monitoring/edge-stackdriver-config.yaml`)
via Config Sync (`FleetPackage`):

- **Official Google Cloud Documentation References:**
  - [Configure Cloud Logging and Cloud Monitoring on Google Distributed Cloud Connected](https://cloud.google.com/distributed-cloud/connected/docs/configure-logging-monitoring)
  - [GDC Software-Only Logging and Monitoring Logical Architecture (`enableGMPForApplications` & `enableCloudLoggingForApplications`)](https://cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/concepts/Logical-architecture-logging-monitoring)
- **Declarative Config Sync `Stackdriver` Manifest
  (`base/monitoring/edge-stackdriver-config.yaml`):**

  ```yaml
  apiVersion: addons.gke.io/v1alpha1
  kind: Stackdriver
  metadata:
    name: stackdriver
    namespace: kube-system
    annotations:
      # Prevents Config Sync from deleting the cluster-critical Stackdriver CR if
      # the FleetPackage is ever removed (uses kpt/Config Sync lifecycle annotation;
      # configmanagement.gke.io/deletion-policy triggers KNV1010 reserved prefix error)
      client.lifecycle.config.k8s.io/deletion: detach
  spec:
    clusterLocation: us-central1
    clusterName: YOUR_STORE_1_CLUSTER # Patched per-store (YOUR_STORE_1_CLUSTER / YOUR_STORE_2_CLUSTER) in overlays/
    enableCloudLoggingForApplications: true
    enableGMPForApplications: true
    enableMultiline: true
    fleetWorkloadIdentitySecretName: google-cloud-credentials
    gcpServiceAccountSecretName: google-cloud-credentials
    namespaceProfile: baremetal
    projectID: YOUR_PROJECT_ID
    proxyConfigSecretName: bm-stackdriver-proxy-config
    scaling: auto
    stackdriverComponentLogVerbosityLevel: info
  ```

📌 **NOTE on Dependency Ordering (`config.kubernetes.io/depends-on`) &
`gmp-system` Registry Credentials:**

- All edge `monitoring.googleapis.com/v1` `PodMonitoring` CRDs
  (`vllm-gemma4-monitoring`, `flwr-trainer-monitoring`, and
  `nvidia-dcgm-exporter-monitoring`) include the annotation
  `config.kubernetes.io/depends-on: addons.gke.io/namespaces/kube-system/Stackdriver/stackdriver`.
  This ensures Config Sync reconciles `kube-system/stackdriver` first and waits
  for `stackdriver-operator` to install the `gmp-operator` and `PodMonitoring`
  CRD before applying the scrape targets.
- Because `gmp-system` pulls
  `gcr.io/anthos-baremetal-release/prometheus-engine/*` images,
  `base/credentials/ar-pull-refresher.yaml` (`CronJob/ar-pull-refresher`)
  automatically mints short-lived OAuth2 tokens via Fleet Workload Identity
  (`sts.googleapis.com/v1/token`), populates `ar-pull-secret` in both
  `fed-lora-poc` and `gmp-system` (`gcr.io` + `us-central1-docker.pkg.dev`), and
  attaches `imagePullSecrets: [{name: ar-pull-secret}]` to the `gmp-system`
  ServiceAccounts (`default`, `operator`, `collector`, `rule-evaluator`).

---

## 2. Turnkey GitOps Demo Setup via Config Sync & Fleet Packages

The Demo Setup ensures a complete decoupling of infrastructure deployment from
live demonstration execution. All workloads, volumes, drivers, and serving
containers are pre-deployed upfront via declarative GitOps.

### 2.1. Environment Configuration

Create or customize your local environment configuration file (e.g.
`fed_lora.env` or `.env`). Update the placeholder values to match your specific
Google Cloud project and cluster naming:

```bash
# ==============================================================================
# Fed-LoRA Demo Environment Configuration (fed_lora.env)
# ==============================================================================
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="us-central1"
export ZONE="us-central1-b"

# Cluster Names
export STORE1_CLUSTER="YOUR_STORE_1_CLUSTER"
export STORE2_CLUSTER="YOUR_STORE_2_CLUSTER"
export GKE_AGGREGATOR_CLUSTER="YOUR_AGGREGATOR_CLUSTER"

# Connect Gateway & Kubernetes Contexts
export STORE1_CONTEXT="connectgateway_${PROJECT_ID}_global_${STORE1_CLUSTER}"
export STORE2_CONTEXT="connectgateway_${PROJECT_ID}_global_${STORE2_CLUSTER}"
export GKE_CONTEXT="gke_${PROJECT_ID}_${ZONE}_${GKE_AGGREGATOR_CLUSTER}"

# Storage & Hugging Face Access Token
export GCS_BUCKET_NAME="YOUR_GCS_BUCKET"
export HF_TOKEN="your-huggingface-token"
```

Source the environment configuration in your shell before executing setup or
verification commands:

```bash
source fed_lora.env
```

#### Dynamically Retrieving LoadBalancer VIPs

Rather than hardcoding IP addresses, operators can dynamically query and export
the assigned LoadBalancer VIPs directly from the Kubernetes service status:

```bash
# 1. Retrieve the MetalLB External LoadBalancer VIP for Store 1 vLLM:
export STORE1_VLLM_VIP=$(kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc \
  get svc vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Store 1 vLLM VIP: ${STORE1_VLLM_VIP}"

# 2. Retrieve the MetalLB External LoadBalancer VIP for Store 2 vLLM:
export STORE2_VLLM_VIP=$(kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc \
  get svc vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Store 2 vLLM VIP: ${STORE2_VLLM_VIP}"

# 3. Retrieve the Internal LoadBalancer (ILB) VIP for Central GKE SuperLink:
export SUPERLINK_ILB_IP=$(kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator \
  get svc flwr-superlink-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Central SuperLink ILB IP: ${SUPERLINK_ILB_IP}"
```

### 2.2. Configuring Config Sync & Fleet Packages in GCP & Clusters

Declarative GitOps across Store 1, Store 2, and Central GKE is powered by Config
Sync and Google Cloud Config Delivery (`FleetPackage`), syncing from your
**private** GitHub repository copy (at path
`software-only/bare-metal/fed-lora/fleet-package/environments`) through a Cloud
Build 2nd-generation GitHub connection (`YOUR_CONNECTION` / `YOUR_REPOSITORY` in
`us-central1`; see [`../README.md`](../README.md)).

#### 1. Enable Required GCP APIs & Fleet Services

```bash
gcloud services enable \
  anthos.googleapis.com \
  gkehub.googleapis.com \
  connectgateway.googleapis.com \
  configmanagement.googleapis.com \
  fleetpackages.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"
```

#### 2. Register Clusters to Google Cloud Fleet

Ensure all 3 clusters are registered fleet members with appropriate membership
labels:

```bash
# Register Store 1 (Edge)
gcloud container fleet memberships register "${STORE1_CLUSTER}" \
  --project="${PROJECT_ID}" \
  --labels="app-tier=fed-lora-edge,store=store-1"

# Register Store 2 (Edge)
gcloud container fleet memberships register "${STORE2_CLUSTER}" \
  --project="${PROJECT_ID}" \
  --labels="app-tier=fed-lora-edge,store=store-2"

# Register Central GKE Aggregator
gcloud container fleet memberships register "${GKE_AGGREGATOR_CLUSTER}" \
  --gke-cluster="${ZONE}/${GKE_AGGREGATOR_CLUSTER}" \
  --project="${PROJECT_ID}" \
  --labels="app-tier=fed-lora-aggregator"
```

#### 3. Enable Config Sync on Fleet Members

Enable Anthos Config Management across the fleet:

```bash
gcloud container fleet config-management enable --project="${PROJECT_ID}"
```

#### 4. Bootstrap GCS Checkpoint Bucket (`stage_gcs_data.sh`)

Bootstrap the central Cloud Storage bucket (`gs://YOUR_GCS_BUCKET`) for Flower
SuperLink LoRA adapter checkpoint staging using the idempotent bootstrapper
script:

```bash
# Create or verify gs://YOUR_GCS_BUCKET:
./scripts/stage_gcs_data.sh

# Read-only verification of gs://YOUR_GCS_BUCKET (also run as Assertion 25 in verify_demo_setup.sh):
./scripts/stage_gcs_data.sh --verify-only
```

📌 **NOTE on Data Sovereignty (`Zero Edge Training Data in GCS`):**
`scripts/stage_gcs_data.sh` provisions **only** the central model checkpoint
bucket (`gs://YOUR_GCS_BUCKET`). Edge store training datasets
(`overlays/store-{1,2}/data/train.jsonl`) are never uploaded to GCS; they are
hydrated into each store's `ConfigMap/store-training-data` and seeded onto each
store's node-local `shared-model-pvc`
(`/mnt/models/edge-data/store-{1,2}/train.jsonl`).

#### 5. Configure Cluster Secrets (`apply_cluster_secrets.sh`) & Fleet Workload Identity Architecture

Provision `hf-token-secret` and the initial `ar-pull-secret` across both GDC
Software-Only edge clusters (`YOUR_STORE_1_CLUSTER` and `YOUR_STORE_2_CLUSTER`)
using `./scripts/apply_cluster_secrets.sh`:

```bash
source config/.env
./scripts/apply_cluster_secrets.sh
```

📌 **NOTE on Keyless Fleet Workload Identity (`svc.id.goog`) vs. Bare-Metal
`containerd` `ar-pull-secret`:** The GDC Software-Only edge clusters use two
complementary, non-overlapping authentication mechanisms:

1.  **Keyless GKE Hub Fleet Workload Identity (`svc.id.goog`) — Used for GCS
    Adapter Storage & Config Delivery OCI Reconciliation:**
    - Application pods (`flwr-trainer`, `flwr-supernode`, `flwr-superlink`)
      mount projected Kubernetes ServiceAccount tokens
      (`audience: ${PROJECT_ID}.svc.id.goog`) paired with
      `ConfigMap/fleet-wi-credentials-config`
      (`GOOGLE_APPLICATION_CREDENTIALS`), granting keyless
      `roles/storage.objectAdmin` access to `gs://YOUR_GCS_BUCKET` with zero
      static JSON service account keys.
    - Similarly, Google Cloud Config Delivery `RootSync` reconcilers
      (`flpkg-rb-fed-lora-edge` and `flpkg-rb-fed-lora-central`) pull rendered
      OCI `ResourceBundle` packages from Artifact Registry via keyless
      `spec.oci.auth: k8sserviceaccount` (no Git credential secret in
      `config-management-system` is required).
2.  **`ar-pull-secret` (`CronJob/ar-pull-refresher`) — Required Exclusively for
    Bare-Metal `containerd` Image Pulls:**
    - While application-layer Python/Go SDKs and Config Sync OCI reconcilers
      natively exchange `svc.id.goog` tokens via Google Cloud STS, the
      host-level `containerd` daemon on GDC Software-Only bare-metal Ubuntu
      22.04 nodes (`YOUR_STORE_1_NODE`, `YOUR_STORE_2_NODE`) requires a standard
      Kubernetes `kubernetes.io/dockerconfigjson` secret
      (`imagePullSecrets: [{name: ar-pull-secret}]`) to pull private container
      images from `us-central1-docker.pkg.dev`.
    - To prevent the 1-hour OAuth token TTL from causing `ImagePullBackOff`,
      each edge cluster runs a declarative `CronJob/ar-pull-refresher` (every 30
      minutes using `python:3.12-slim`) that exchanges its own Fleet Workload
      Identity token via STS and updates `Secret/ar-pull-secret` in-cluster
      automatically.

#### 6. Apply Phase A Cluster Prerequisites, Render & Deploy Fleet Packages (`fleet-package/`)

1.  **Apply Phase A GPU Time-Slicing & Config Delivery RBAC (One-Time Admin
    Setup):**
    - On single-GPU edge store clusters, apply the NVIDIA GPU time-slicing
      prerequisite outside the `FleetPackage` (skip on multi-GPU nodes; if
      migrating from an earlier `FleetPackage` that reconciled GPU time-slicing,
      annotate `ConfigMap/time-slicing-config` and
      `ClusterPolicy/cluster-policy` with
      `client.lifecycle.config.k8s.io/deletion=detach` first—see
      [`../prerequisites/gpu-time-slicing/README.md`](../prerequisites/gpu-time-slicing/README.md)):

      ```bash
      kubectl --context="${STORE1_CONTEXT}" apply -k prerequisites/gpu-time-slicing
      kubectl --context="${STORE2_CONTEXT}" apply -k prerequisites/gpu-time-slicing
      ```

    - Substitute `YOUR_PROJECT_NUMBER` in
      `fleet-package/configdelivery-rbac.yaml` and apply it on all three
      clusters so the Config Delivery service agent has namespace-scoped
      `RootSync` permissions in `config-management-system`:

      ```bash
      for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}" "${GKE_CONTEXT}"; do
        kubectl --context="${ctx}" apply -f fleet-package/configdelivery-rbac.yaml
      done
      ```

2.  **Render & Roll Out `FleetPackage` Bundles:** All application manifests are
    authored in `base/` + `overlays/{store-1,store-2,central-aggregator}/` and
    deterministically hydrated into
    `fleet-package/environments/{store-1,store-2,central-aggregator}/manifests.yaml`
    via `./fleet-package/render.sh` (verified via
    `./scripts/render_fleet_manifests.sh --check`). Substitute `YOUR_*`
    placeholders in your private GitHub repository copy, re-render, push an
    immutable release tag (`v1.0.0`), and create both `FleetPackage` resources
    (for container image builds via `docker/cloudbuild-images.yaml`, see
    [`../README.md`](../README.md)):

    - **`fleet-package/fleetpackage-edge.yaml` (`fed-lora-edge-package`):**
      Multi-cluster package targeting edge store clusters labeled with
      `app-tier=fed-lora-edge` (`variantSelector` matching `store=store-1` /
      `store=store-2`). Deploys the `fed-lora-poc` namespace, shared model PVC
      (`shared-model-pvc`), vLLM foundation model serving engine, CPU Flower
      SuperNode worker daemon (`flwr-supernode`), GPU `SuperExec` trainer pod
      (`flwr-trainer`), `CronJob/ar-pull-refresher`, and `Stackdriver` /
      `PodMonitoring` observability resources.
    - **`fleet-package/fleetpackage-central.yaml`
      (`fed-lora-central-package`):** Package targeting the central GKE
      aggregator cluster labeled with `app-tier=fed-lora-aggregator`. Deploys
      the central Flower SuperLink control plane and Internal Passthrough
      Network Load Balancer (`10.200.0.50`, restricted by
      `spec.loadBalancerSourceRanges: [YOUR_STORE_CIDR]`) exposing FleetAPI
      (port 9092) and ExecAPI (port 9093).

    ```bash
    ./fleet-package/render.sh
    ./scripts/render_fleet_manifests.sh --check

    # Deploy central aggregator package on GKE
    gcloud container fleet packages create fed-lora-central-package \
      --source=fleet-package/fleetpackage-central.yaml \
      --location="${REGION}" \
      --project="${PROJECT_ID}"

    # Deploy edge store package across Store 1 and Store 2
    gcloud container fleet packages create fed-lora-edge-package \
      --source=fleet-package/fleetpackage-edge.yaml \
      --location="${REGION}" \
      --project="${PROJECT_ID}"
    ```

### 2.3. Pre-Deployed Turnkey Workloads

Upon Config Sync and Fleet Package reconciliation, the following workloads are
active:

1.  **Phase A Prerequisite — NVIDIA GPU Time-Slicing
    (`prerequisites/gpu-time-slicing/`):**
    - Applied once by the platform administrator on single-GPU store clusters
      (outside the `FleetPackage`), partitioning each physical RTX PRO 6000 GPU
      into `2` virtual GPU resources (`nvidia.com/gpu: 2`) for co-located
      inference (`vllm-gemma4`) and training (`flwr-trainer`).
2.  **Node-Local Shared HostPath Storage (`shared-model-pvc.yaml`):**
    - Provisions `shared-model-pvc` (`50Gi`,
      `hostPath: /var/mnt/fed-lora-models`) mounted at `/mnt/models` inside
      `vllm-gemma4`, `flwr-supernode`, and `flwr-trainer`
      (`securityContext.fsGroup: 2000`).
3.  **Base vLLM Foundation Model Serving Engine
    (`vllm-gemma4-deployment.yaml`):**
    - Serves un-tuned `google/gemma-4-E2B-it` with `--enable-lora`,
      `--gpu-memory-utilization 0.85`, `--enable-sleep-mode`,
      `VLLM_SERVER_DEV_MODE=1`, `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True`, and
      `strategy.type: RollingUpdate (maxSurge: 0, maxUnavailable: 1)`.
    - Exposes OpenAI-compatible REST API endpoints on dedicated MetalLB External
      LoadBalancer VIPs:
      - Store 1: `http://${STORE1_VLLM_VIP}:8000` (e.g.
        `http://10.200.0.131:8000`)
      - Store 2: `http://${STORE2_VLLM_VIP}:8000` (e.g.
        `http://10.200.0.163:8000`)
4.  **3-Pod Edge Flower Split (`flwr-supernode` CPU + `flwr-trainer` GPU
    `SuperExec`) & Credential Refresher (`ar-pull-refresher`):**
    - `flwr-supernode` (`0` GPUs): Lightweight CPU control-plane daemon
      maintaining an outbound gRPC long-polling channel to Central SuperLink
      (`${SUPERLINK_ILB_IP}:9092`).
    - `flwr-trainer` (`1` GPU slice, image `v2.1.12`): Pre-baked GPU `SuperExec`
      worker executing `ClientApp` (`KLProxTrainer`, vLLM Level-1 Sleep/Wake
      coordination, and 14-probe canary evaluation).
    - `CronJob/ar-pull-refresher`: Refreshes `Secret/ar-pull-secret` every 30
      minutes via Fleet Workload Identity STS token exchange.
5.  **Central GKE Flower SuperLink Control Plane
    (`gke-flwr-superlink-deployment.yaml`):**
    - Deployed in namespace `fed-lora-aggregator` on GKE (`v2.1.12`) and exposed
      via an Internal Passthrough Network Load Balancer at `${SUPERLINK_ILB_IP}`
      on ports 9092 (FleetAPI) and 9093 (ExecAPI).

---

## 3. Pre-Flight Verification & System Audit

Before launching the interactive 5-stage federated learning demonstration,
operators and presenters must verify that all cluster infrastructure, GPU
time-slicing partitions, GitOps pipelines, serving engines, and Flower control
plane components are healthy and operational.

This section provides two complementary verification mechanisms:

1.  **Section 3.1 (Automated Pre-Flight Script):** The primary turnkey audit
    script (`verify_demo_setup.sh`) that validates all 17 system assertions in
    ~29 seconds using a resilient 3-tier health probe.
2.  **Section 3.2 (Comprehensive Manual Verification Reference):** A complete,
    step-by-step CLI reference for inspecting each subsystem individually via
    Connect Gateway, serving as a comprehensive superset of all automated
    assertions and operational diagnostics.

---

### 3.1. Automated Turnkey Pre-Flight Verification Script (`verify_demo_setup.sh`)

The fastest and most reliable way to audit the demo environment is executing the
automated pre-flight audit script from the root of the repository:

```bash
./scripts/verify_demo_setup.sh
```

#### Resilient 3-Tier Health Probe

The verification harness audits the vLLM model discovery endpoint
(`GET /v1/models`) and baseline adapter status across both store clusters using
an automated 3-tier fallback routing mechanism:

1.  **Tier 1 (Direct L3 Routing):** Attempts a direct HTTP query to each store's
    MetalLB External LoadBalancer VIP (`http://${STORE1_VLLM_VIP}:8000` and
    `http://${STORE2_VLLM_VIP}:8000`). This path succeeds when the operator
    workstation is located inside or peered with the GCP VPC network.
2.  **Tier 2 (In-Cluster Connect Gateway Fallback):** If direct L3 routing is
    unavailable (e.g. running from an external operator or corporate workstation
    outside the VPC), the script transparently executes `curl` inside the
    co-located `flwr-supernode` container using Connect Gateway
    (`http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models`),
    requiring zero VPN or bastion configuration.
3.  **Tier 3 (SSH Bastion Fallback):** Falls back to executing remote curl
    queries via the GDC Software-Only host VM SSH bastion if configured.

#### Live Execution Output (17/17 Assertions Passed)

```text
==============================================================================
 EDGE-TO-CLOUD FEDERATED LEARNING (Fed-LoRA) PoC -- TURNKEY SETUP AUDIT
==============================================================================
[INFO 2026-09-12T22:29:21+0000] Initiating automated pre-flight audit across Store 1, Store 2, and Central GKE...
[INFO 2026-09-12T22:29:21+0000] Configuration: DRY_RUN=false
[INFO 2026-09-12T22:29:21+0000] Store 1 Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER (VIP: 10.200.0.131:8000)
[INFO 2026-09-12T22:29:21+0000] Store 2 Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER (VIP: 10.200.0.163:8000)
[INFO 2026-09-12T22:29:21+0000] GKE Context:     gke_YOUR_PROJECT_ID_us-central1-b_YOUR_AGGREGATOR_CLUSTER (ILB: 10.200.0.50:8080)

[INFO 2026-09-12T22:29:21+0000] [Check 1/8] Auditing GPU Time-Slicing status (status.allocatable.nvidia.com/gpu: 2)...
[PASS 2026-09-12T22:29:22+0000] Store 1: GPU Time-Slicing active (allocatable: 2 virtual slices per physical GPU).
[PASS 2026-09-12T22:29:24+0000] Store 2: GPU Time-Slicing active (allocatable: 2 virtual slices per physical GPU).
[INFO 2026-09-12T22:29:24+0000] [Check 2/8] Auditing shared node-local hostPath storage (pvc/shared-model-pvc)...
[PASS 2026-09-12T22:29:25+0000] Store 1: pvc/shared-model-pvc is Bound in namespace fed-lora-poc.
[PASS 2026-09-12T22:29:26+0000] Store 2: pvc/shared-model-pvc is Bound in namespace fed-lora-poc.
[INFO 2026-09-12T22:29:26+0000] [Check 3/8] Auditing base vLLM serving engine deployment (vllm-gemma4)...
[PASS 2026-09-12T22:29:27+0000] Store 1: deployment/vllm-gemma4 is Ready (1/1 ready replicas on GPU slice #1).
[PASS 2026-09-12T22:29:28+0000] Store 2: deployment/vllm-gemma4 is Ready (1/1 ready replicas on GPU slice #1).
[INFO 2026-09-12T22:29:28+0000] [Check 4/8] Auditing edge Flower SuperNode training daemon (flwr-supernode)...
[PASS 2026-09-12T22:29:29+0000] Store 1: deployment/flwr-supernode is Ready (1/1 ready replicas on GPU slice #2).
[PASS 2026-09-12T22:29:30+0000] Store 2: deployment/flwr-supernode is Ready (1/1 ready replicas on GPU slice #2).
[INFO 2026-09-12T22:29:30+0000] [Check 5/8] Auditing Central GKE Flower SuperLink deployment (flwr-superlink)...
[PASS 2026-09-12T22:29:30+0000] Central GKE: deployment/flwr-superlink is Ready (1/1 ready replicas in fed-lora-aggregator).
[INFO 2026-09-12T22:29:30+0000] [Check 6/8] Auditing LoadBalancer VIP routing assignments...
[PASS 2026-09-12T22:29:33+0000] Store 1: Service vllm-service assigned expected MetalLB VIP '10.200.0.131:8000'.
[PASS 2026-09-12T22:29:33+0000] Store 2: Service vllm-service assigned expected MetalLB VIP '10.200.0.163:8000'.
[PASS 2026-09-12T22:29:33+0000] Central GKE: Service flwr-superlink-service assigned expected Internal LB IP '10.200.0.50' (:9092, :9093).
[INFO 2026-09-12T22:29:33+0000] [Check 7/8] Auditing vLLM model discovery (GET /v1/models) & clean baseline state...
[PASS 2026-09-12T22:29:38+0000] Store 1 (10.200.0.131:8000): vLLM serving endpoint healthy; base model 'google/gemma-4-E2B-it' discovered.
[PASS 2026-09-12T22:29:38+0000] Store 1 (10.200.0.131:8000): Clean baseline verified (zero custom LoRA adapters loaded in vLLM memory).
[PASS 2026-09-12T22:29:43+0000] Store 2 (10.200.0.163:8000): vLLM serving endpoint healthy; base model 'google/gemma-4-E2B-it' discovered.
[PASS 2026-09-12T22:29:43+0000] Store 2 (10.200.0.163:8000): Clean baseline verified (zero custom LoRA adapters loaded in vLLM memory).
[INFO 2026-09-12T22:29:43+0000] [Check 8/8] Auditing Flower SuperNode registration on SuperLink (10.200.0.50:9093)...
[PASS 2026-09-12T22:29:50+0000] SuperLink (10.200.0.50:9093): Active SuperNode registrations verified via 'flwr supernode list'.

==============================================================================
 TURNKEY DEMO LAB SETUP PRE-FLIGHT VERIFICATION SUMMARY
==============================================================================
Total Checks Executed : 17
Passed Checks         : 17
Failed Checks         : 0
Warnings              : 0
Audit Duration        : 29s (Budget: < 60s)
------------------------------------------------------------------------------
OVERALL AUDIT RESULT: PASSED (Turnkey Demo Lab is 100% Ready for Presentation)
==============================================================================
```

If all 17 assertions pass, the environment is certified ready for demonstration.
If any check fails, or if operators wish to manually inspect cluster internals,
consult the granular reference in Section 3.2.

---

### 3.2. Comprehensive Manual Verification & Component Inspection Reference

This section provides the complete, unified manual CLI reference across all
three clusters. It serves as an explicit superset of the 17 assertions tested by
the automated script, adding deep pipeline diagnostics, spec dumps, targeted log
event inspection, and Flower App package validation.

#### 3.2.1. Obtaining Cluster Credentials & Context Configuration

To interact with the clusters via `kubectl` from an operator workstation, obtain
cluster credentials via Google Cloud Connect Gateway:

```bash
# 1. Fetch credentials for Store 1 via Connect Gateway
gcloud container fleet memberships get-credentials "${STORE1_CLUSTER}" \
  --project="${PROJECT_ID}"

# 2. Fetch credentials for Store 2 via Connect Gateway
gcloud container fleet memberships get-credentials "${STORE2_CLUSTER}" \
  --project="${PROJECT_ID}"

# 3. Fetch credentials for Central GKE Aggregator
gcloud container clusters get-credentials "${GKE_AGGREGATOR_CLUSTER}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}"

# 4. Define context shorthand variables for active session:
export STORE1_CONTEXT="connectgateway_${PROJECT_ID}_global_${STORE1_CLUSTER}"
export STORE2_CONTEXT="connectgateway_${PROJECT_ID}_global_${STORE2_CLUSTER}"
export GKE_CONTEXT="gke_${PROJECT_ID}_${ZONE}_${GKE_AGGREGATOR_CLUSTER}"
```

#### 3.2.2. Verifying GitOps Continuous Delivery & Pipeline Status

Verify that Anthos Config Sync and Google Cloud Fleet Packages have synchronized
manifests across all three clusters:

```bash
# 1. Verify Anthos Config Sync status across all 3 demo clusters
nomos status --contexts="${STORE1_CONTEXT},${STORE2_CONTEXT},${GKE_CONTEXT}"
nomos status --contexts="${STORE1_CONTEXT},${STORE2_CONTEXT},${GKE_CONTEXT}" --resources=false

# 2. Inspect RootSync Custom Resource status on each individual cluster
kubectl --context="${STORE1_CONTEXT}" get rootsync -n config-management-system
kubectl --context="${STORE2_CONTEXT}" get rootsync -n config-management-system
kubectl --context="${GKE_CONTEXT}" get rootsync -n config-management-system

# 3. Check Google Cloud Fleet Packages & Rollout status
gcloud alpha container fleet packages list --location="${REGION}" --project="${PROJECT_ID}"
gcloud alpha container fleet packages rollouts list --fleet-package=fed-lora-edge-package --location="${REGION}" --project="${PROJECT_ID}"

# 4. Check Cloud Build packaging execution status (inspects builds spawned by Fleet Packages)
gcloud builds list --region="${REGION}" --project="${PROJECT_ID}" --limit=5
```

#### 3.2.3. Node Health & NVIDIA GPU Operator Infrastructure [Assertions 1 & 2]

Verify cluster node health, GPU Operator readiness, and GPU time-slicing
partitions:

```bash
# 1. Verify Cluster Node Readiness
kubectl --context="${STORE1_CONTEXT}" get nodes
kubectl --context="${STORE2_CONTEXT}" get nodes
kubectl --context="${GKE_CONTEXT}" get nodes

# 2. Verify NVIDIA GPU Operator ClusterPolicy Status (Expect: STATUS ready)
kubectl --context="${STORE1_CONTEXT}" get clusterpolicy
kubectl --context="${STORE2_CONTEXT}" get clusterpolicy

# 3. Verify GPU Operator DaemonSet Pods in gpu-operator namespace
kubectl --context="${STORE1_CONTEXT}" get pods -n gpu-operator
kubectl --context="${STORE2_CONTEXT}" get pods -n gpu-operator

# 4. [Assertion 1 & 2] Verify GPU Time-Slicing Allocatable Slices (Expect: 2 per node)
kubectl --context="${STORE1_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
kubectl --context="${STORE2_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
```

#### 3.2.4. Node-Local Shared Storage Verification [Assertions 3 & 4]

Verify that the node-local `shared-model-pvc` is bound on both edge clusters:

```bash
# [Assertion 3 & 4] Verify shared-model-pvc is Bound in namespace fed-lora-poc
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc
```

#### 3.2.5. Edge Serving & Training Daemon Deployments [Assertions 5, 6, 7, 8, 18, 20]

Verify that vLLM serving engines, CPU Flower SuperNode daemons, GPU `SuperExec`
trainer pods (`flwr-trainer`), and `CronJob/ar-pull-refresher` are running:

```bash
# 1. Inspect all running pods and CronJobs in fed-lora-poc namespace across edge clusters
kubectl --context="${STORE1_CONTEXT}" get pods,cronjobs -n fed-lora-poc -o wide
kubectl --context="${STORE2_CONTEXT}" get pods,cronjobs -n fed-lora-poc -o wide

# 2. [Assertion 5 & 6] Verify vLLM Serving Engine Deployment Health (Expect: 1/1 ready)
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deployment vllm-gemma4
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get deployment vllm-gemma4

# 3. [Assertion 7 & 8] Verify Flower SuperNode CPU Daemon & GPU Trainer Deployment Health (Expect: 1/1 ready)
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deployment flwr-supernode flwr-trainer
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get deployment flwr-supernode flwr-trainer
```

#### 3.2.6. Central GKE SuperLink Control Plane & Ingress Services [Assertions 9, 10, 11, 12]

Inspect the Central GKE aggregator control plane and load balancer VIP
allocations:

```bash
# 1. Inspect Central GKE pods and services in namespace fed-lora-aggregator
kubectl --context="${GKE_CONTEXT}" get pods,svc -n fed-lora-aggregator

# 2. [Assertion 9] Verify Central GKE Flower SuperLink Deployment Health (Expect: 1/1 ready)
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deployment flwr-superlink
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deployment flwr-superlink -o yaml

# 3. [Assertion 10 & 11] Verify Edge MetalLB External LoadBalancer VIPs
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get svc vllm-service
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get svc vllm-service

# 4. [Assertion 12] Verify Central GKE Internal LoadBalancer Service (Expect: 10.200.0.50 on ports 9092, 9093)
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get svc flwr-superlink-service
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get svc flwr-superlink-service -o yaml
```

#### 3.2.7. vLLM Model Discovery & Clean Baseline Audit [Assertions 13, 14, 15, 16]

Verify that the un-tuned base model `google/gemma-4-E2B-it` is active and zero
custom LoRA adapters are pre-loaded:

##### Method A: In-Cluster Exec Query via `flwr-trainer` (Zero Network Dependency / Automated Script Method)

```bash
# [Assertion 13 & 15] Query GET /v1/models via flwr-trainer (which includes curl) to verify base model discovery:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data[0].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data[0].id'

# [Assertion 14 & 16] Verify clean baseline adapter count (Expect: 1, base model only):
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data | length'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data | length'
```

##### Method B: Operator Workstation Port-Forwarding Query (`18081` & `18082`)

```bash
# Port-forward Store 1 and Store 2 vLLM services to local workstation ports 18081 and 18082:
lsof -i:18081 >/dev/null 2>&1 || kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 &
lsof -i:18082 >/dev/null 2>&1 || kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 &

# Query endpoints directly from workstation:
curl -s http://127.0.0.1:18081/v1/models | jq .
curl -s http://127.0.0.1:18082/v1/models | jq .
```

📌 **NOTE on Port Conflicts (`bind: address already in use`):** If ports 18081
or 18082 are already in use by a previous background `kubectl port-forward`
process, reuse the existing listeners or terminate and restart them:

```bash
kill $(lsof -t -i:18081 -i:18082) 2>/dev/null || true
```

#### 3.2.8. Flower SuperLink & SuperNode Log Inspection (Targeted Event Grep)

Rather than running an untargeted log tail, inspect specific operational log
strings to verify process startup, network connectivity, and node registration
events:

##### Central SuperLink Log Verification:

Filter the SuperLink logs for daemon startup, edge polling activity, and ExecAPI
requests:

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator logs deployment/flwr-superlink \
  | grep -E "(Starting Flower SuperLink|Fleet\.PullMessages|node_id|ControlServicer)" | tail -n 15
```

**Expected Log Matches & Diagnostic Significance:**

- `Starting Flower SuperLink`: Confirms the control plane process initialized
  successfully.
- `[Fleet.PullMessages] node_id=<id>`: Confirms edge SuperNodes are actively
  long-polling the FleetAPI on port 9092.
- `ControlServicer.ListRuns` / `ControlServicer.ListNodes`: Confirms the ExecAPI
  is servicing administrative and CLI queries on port 9093.

##### Edge SuperNode Log Verification:

Filter Store 1 and Store 2 SuperNode logs for outbound channel establishment,
registration, and assigned node IDs:

```bash
# Store 1 SuperNode log audit:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc logs deployment/flwr-supernode \
  | grep -E "(Establishing outbound connection|Starting Flower SuperNode|SuperNode ID|Application startup complete|Starting Flower SuperExec)"

# Store 2 SuperNode log audit:
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc logs deployment/flwr-supernode \
  | grep -E "(Establishing outbound connection|Starting Flower SuperNode|SuperNode ID|Application startup complete|Starting Flower SuperExec)"
```

**Expected Log Matches & Diagnostic Significance:**

- `[INFO] Establishing outbound connection to SuperLink 10.200.0.50:9092...`:
  Confirms outbound L3 routing from edge VM to GKE ILB.
- `INFO : Starting Flower SuperNode`: Confirms the Flower edge worker daemon
  initialized.
- `INFO : Application startup complete.`: Confirms the local runtime environment
  is ready.
- `INFO : SuperNode ID: <id>`: Confirms successful registration and node ID
  assignment by Central SuperLink.
- `INFO : Starting Flower SuperExec`: Confirms the local execution engine is
  ready to accept dispatched training tasks.

📌 **NOTE:** If streaming live output during an active training run, use
`kubectl logs -f deployment/flwr-superlink -n fed-lora-aggregator` or
`kubectl logs -f deployment/flwr-supernode -n fed-lora-poc`.

#### 3.2.9. Flower SuperNode Registration & Application Package Validation [Assertion 17]

Verify that edge SuperNodes are registered online on Central SuperLink and
validate the Flower App package definitions:

##### Option A: In-Cluster Exec (Zero-Install / Recommended)

```bash
# 1. [Assertion 17] List online registered SuperNodes directly inside the container:
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- flwr supernode list

# 2. Query execution run history directly inside the container:
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- flwr list
```

##### Option B: Workstation Flower CLI via Port-Forwarding

```bash
# 1. Forward ExecAPI port (9093) from GKE ILB to localhost (if not already active):
lsof -i:9093 >/dev/null 2>&1 || kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 9093:9093 &
```

📌 **NOTE on Port Conflicts (`bind: address already in use`):** If port 9093 is
already forwarded by a previous background job, reuse the active connection or
terminate: `kill $(lsof -t -i:9093) 2>/dev/null || true`

```bash

# 2. Configure ~/.flwr/config.toml connection profile:
cat << 'EOF' > ~/.flwr/config.toml
[superlink]
default = "gke-superlink"

[superlink.gke-superlink]
address = "127.0.0.1:9093"
insecure = true
EOF

# 3. Verify connection profile and list registered SuperNodes:
flwr config list
flwr supernode list

# 4. Inspect Flower App package definitions and run configurations:
cat apps/fed-lora/pyproject.toml
cat apps/fed-lora/run_config_local_sft.toml
cat apps/fed-lora/run_config_federated.toml

# 5. Query execution runs:
flwr list
```

📌 **NOTE on Flower Runs Visibility:** `flwr list` reports empty (`0 items`) on
a freshly deployed SuperLink instance because SuperLink stores run logs in an
in-memory session state. Historical runs populate dynamically when Stage 2
(Local SFT) or Stage 4 (Federated Averaging) is dispatched via `flwr run` or the
primary runner `./scripts/run_full_5stage_demo.sh`.

#### 3.2.10. Store-Local PVC Dataset Seeding & Checkpoint Bucket Verification

Training data stays on each store node (`PVC` at
`/mnt/models/edge-data/store-{1,2}/train.jsonl`), seeded declaratively in the
lab (`ConfigMap/store-training-data` $\rightarrow$ `PVC` via the
`seed-store-training-data` initContainer) and produced by the store's own local
systems in production; the GCS bucket holds model artifacts only. Verify that
each store's local PVC dataset matches the repository SHA-256 hash and that the
GCS checkpoints prefix is accessible:

```bash
# 1. Verify Store 1 and Store 2 fine-tuning datasets on store-local PVCs:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-1/train.jsonl
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-2/train.jsonl

# 2. Verify model checkpoints directory in GCS:
gcloud storage ls "gs://${GCS_BUCKET_NAME}/checkpoints/"
```

#### 3.2.11. Cross-Reference Mapping: Automated Assertions vs. Manual CLI Checks (`25/25` Checks)

The table below maps each of the 25 assertions validated by
`./scripts/verify_demo_setup.sh` to its corresponding manual CLI inspection
command in Section 3.2:

<!-- mdformat off -->

| Assertion #      | Target Subsystem / Resource                                                            | Manual Verification Command                                                                                                                                                               | Target Section |
| :--------------- | :------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------- |
| **Assertion 1**  | Store 1 GPU Time-Slicing (2 virtual slices)                                            | `kubectl --context="${STORE1_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'`                                                                            | Section 3.2.3  |
| **Assertion 2**  | Store 2 GPU Time-Slicing (2 virtual slices)                                            | `kubectl --context="${STORE2_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'`                                                                            | Section 3.2.3  |
| **Assertion 3**  | Store 1 Node-Local Storage (`shared-model-pvc`)                                        | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc`                                                                                                          | Section 3.2.4  |
| **Assertion 4**  | Store 2 Node-Local Storage (`shared-model-pvc`)                                        | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc`                                                                                                          | Section 3.2.4  |
| **Assertion 5**  | Store 1 vLLM Serving Engine Deployment                                                 | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deployment vllm-gemma4`                                                                                                        | Section 3.2.5  |
| **Assertion 6**  | Store 2 vLLM Serving Engine Deployment                                                 | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get deployment vllm-gemma4`                                                                                                        | Section 3.2.5  |
| **Assertion 7**  | Store 1 Flower SuperNode & GPU Trainer Pods                                            | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deployment flwr-supernode flwr-trainer`                                                                                        | Section 3.2.5  |
| **Assertion 8**  | Store 2 Flower SuperNode & GPU Trainer Pods                                            | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get deployment flwr-supernode flwr-trainer`                                                                                        | Section 3.2.5  |
| **Assertion 9**  | Central GKE Flower SuperLink Deployment                                                | `kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deployment flwr-superlink`                                                                                                 | Section 3.2.6  |
| **Assertion 10** | Store 1 MetalLB External LoadBalancer VIP                                              | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get svc vllm-service`                                                                                                              | Section 3.2.6  |
| **Assertion 11** | Store 2 MetalLB External LoadBalancer VIP                                              | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get svc vllm-service`                                                                                                              | Section 3.2.6  |
| **Assertion 12** | Central GKE Internal LoadBalancer Service                                              | `kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get svc flwr-superlink-service`                                                                                                | Section 3.2.6  |
| **Assertion 13** | Store 1 vLLM Model Discovery (`GET /v1/models`)                                        | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models \| jq '.data[0].id'`     | Section 3.2.7  |
| **Assertion 14** | Store 1 Clean Baseline (Zero Custom LoRA Adapters)                                     | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models \| jq '.data \| length'` | Section 3.2.7  |
| **Assertion 15** | Store 2 vLLM Model Discovery (`GET /v1/models`)                                        | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models \| jq '.data[0].id'`     | Section 3.2.7  |
| **Assertion 16** | Store 2 Clean Baseline (Zero Custom LoRA Adapters)                                     | `kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models \| jq '.data \| length'` | Section 3.2.7  |
| **Assertion 17** | Central SuperLink SuperNode Registrations                                              | `kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- flwr supernode list`                                                                         | Section 3.2.9  |
| **Assertion 18** | Edge `flwr-trainer` `fsGroup: 2000` & PVC Write Access                                 | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deploy flwr-trainer -o jsonpath='{.spec.template.spec.securityContext.fsGroup}'`                                               | Section 3.2.5  |
| **Assertion 19** | GCS `round-0` Seed Schema (`240` keys, `r=16, alpha=64`)                               | `gcloud storage ls gs://YOUR_GCS_BUCKET/adapters/gemma4-e2b/round-0/`                                                                                                                     | Section 2.2    |
| **Assertion 20** | Edge `ar-pull-secret` & `CronJob/ar-pull-refresher`                                    | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get secret ar-pull-secret && kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get cronjob ar-pull-refresher`                  | Section 2.2    |
| **Assertion 21** | Edge vLLM Level-1 Sleep Mode (`--enable-sleep-mode`, `VLLM_SERVER_DEV_MODE=1`)         | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get deploy vllm-gemma4 -o yaml \| grep -E "enable-sleep-mode\|VLLM_SERVER_DEV_MODE"`                                               | Section 2.3    |
| **Assertion 22** | Store 1 & Store 2 PVC `train.jsonl` SHA-256 Parity                                     | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deploy/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-1/train.jsonl`                                   | Section 3.2.10 |
| **Assertion 23** | Edge Fleet Workload Identity (`ConfigMap/fleet-wi-credentials-config`)                 | `kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get configmap fleet-wi-credentials-config`                                                                                         | Section 2.2    |
| **Assertion 24** | Central `flwr-superlink` & Edge `flwr-trainer` Image Parity (`v2.1.12`)                | `kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deploy flwr-superlink -o jsonpath='{.spec.template.spec.containers[0].image}'`                                             | Section 2.3    |
| **Assertion 25** | GCS Checkpoint Buckets & Two-Phase Canary Prefixes (`stage_gcs_data.sh --verify-only`) | `./scripts/stage_gcs_data.sh --verify-only`                                                                                                                                               | Section 2.2    |

<!-- mdformat on -->

---

## 4. Troubleshooting & Triage Runbook

<!-- mdformat off -->

| Symptom / Error                                                             | Root Cause                                                                                                                                            | Remediation Procedure                                                                                                                                                                                                                                     |
| :-------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `allocatable.nvidia.com/gpu: 1` (Expected `2`)                              | GPU Operator time-slicing ConfigMap not bound by ClusterPolicy.                                                                                       | Verify `kubectl get clusterpolicy cluster-policy -o yaml` contains `default: time-slicing-config`. Delete and restart NVIDIA device plugin daemonset: `kubectl -n gpu-operator rollout restart daemonset nvidia-device-plugin-daemonset`.                 |
| `pvc/shared-model-pvc` remains `Pending`                                    | Storage volume permission or missing hostPath `/var/mnt/fed-lora-models`.                                                                             | Ensure `/var/mnt/fed-lora-models` exists on the host node (`chmod 775 /var/mnt/fed-lora-models`). Re-apply `base/vllm-serving/shared-model-pvc.yaml`.                                                                                                     |
| `vllm-gemma4` pod in `CrashLoopBackOff`                                     | GPU VRAM OOM or missing Hugging Face access secret.                                                                                                   | Verify `hf-token-secret` exists in `fed-lora-poc`. Check pod logs (`kubectl logs deploy/vllm-gemma4 -n fed-lora-poc`). Verify `--gpu-memory-utilization 0.85` and `--enable-sleep-mode` are configured.                                                   |
| `flwr-trainer` pod in `ErrImagePull` / `ImagePullBackOff` (`403 Forbidden`) | Missing or expired `ar-pull-secret` (`oauth2accesstoken` 1h TTL) on GDC Software-Only bare-metal node when pulling from `us-central1-docker.pkg.dev`. | Verify `CronJob/ar-pull-refresher` is active (`kubectl --context=$STORE1_CONTEXT -n fed-lora-poc get cronjob ar-pull-refresher`), or run `./scripts/apply_cluster_secrets.sh` / `./scripts/verify_demo_setup.sh` to immediately refresh `ar-pull-secret`. |
| `flwr-superlink` LoadBalancer IP is empty (`<pending>`)                     | GKE Internal LoadBalancer subnet allocation delay.                                                                                                    | Check GKE events: `kubectl describe svc flwr-superlink-service -n fed-lora-aggregator`. Verify subnet `YOUR_SUBNET_NAME` has sufficient IP capacity.                                                                                                      |
| `flwr supernode list` shows 0 active nodes                                  | SuperNodes unable to reach SuperLink Fleet API on port 9092.                                                                                          | Verify SuperNode pod logs: `kubectl --context=$STORE1_CONTEXT logs deploy/flwr-supernode -n fed-lora-poc`. Confirm network connectivity to `${SUPERLINK_ILB_IP}:9092`.                                                                                    |
| `vLLM` returns 404 on adapter hot-swap                                      | Adapter files missing or dynamic loading disabled.                                                                                                    | Ensure `/mnt/models/<adapter-name>` contains valid `adapter_model.safetensors` and `adapter_config.json`. Ensure `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True` is present in vLLM container environment.                                                        |
| `bind: address already in use` (port `19093` / `18081` / `18082`)           | A previous background `kubectl port-forward` process is already listening on the workstation.                                                         | Verify active listeners via `lsof -i :<port>`. If already forwarding traffic, reuse the existing tunnel. To kill and restart: `kill $(lsof -t -i:<port>)` or `pkill -f "port-forward.*<port>"`. See Section 4.1.                                          |

<!-- mdformat on -->

### 4.1. Managing Background Port-Forwarding Processes & Listener Conflicts

When running verification queries from an operator workstation, multiple
`kubectl port-forward` background processes may conflict if launched repeatedly:

#### Option A: Inspect Active Background Listeners

```bash
# Check if canonical workstation ports 19093, 18081, or 18082 are currently in use:
lsof -i:19093 -i:18081 -i:18082
```

#### Option B: Terminate and Restart Background Listeners

To kill existing port-forward processes before establishing fresh tunnels:

```bash
# Kill port 19093 tunnel:
kill $(lsof -t -i:19093) 2>/dev/null || true

# Kill vLLM ports 18081 and 18082 tunnels:
kill $(lsof -t -i:18081 -i:18082) 2>/dev/null || true

# Or kill all demo port-forward tunnels at once:
pkill -f "port-forward.*(19093|18081|18082)"
```

#### Option C: Idempotent Port-Forward Commands

Guard all port-forward commands with `lsof` so they only execute if the port is
not already listening:

```bash
# Forward Store 1 vLLM to port 18081:
lsof -i:18081 >/dev/null 2>&1 || kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 &

# Forward Store 2 vLLM to port 18082:
lsof -i:18082 >/dev/null 2>&1 || kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 &

# Forward Central SuperLink ExecAPI to port 19093:
lsof -i:19093 >/dev/null 2>&1 || kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 &
```

---

## 5. Hardening: Hallucination Elimination, Cross-Subspace Residual Projection & Zero-VRAM Edge Judge

📌 **NOTE:** Hardens both the edge local QLoRA training loop (`Layer A`) and the
central Flower aggregation pipeline (`Layer B`) across all 3 federated rounds
(`14/14 [100.00%] -> PROMOTE`).

<!-- mdformat off -->

| Control Layer                                                             | Mechanism                                                                                                                                                                                                                                                                                                                                                                                                                      | Implementation Location                                                                                                            | Operational Effect                                                                                                                                                               |
| :------------------------------------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Dataset Hygiene & Silo Isolation**                                      | Fixed Store 2 boundary targets using non-overlapping excluded items (`air fryers`, `microwave ovens`, `denim coats`, `running shoes` across `39` positive/boundary rows) + `7` disjoint generic OOD abstention anchors (`14.0%`) + `4` general-capability replay examples (`8.0%`) (**`50` seeded examples/store**, `20` active curated training examples/round, `0%` sibling-store topic leakage, `0%` canary prompt overlap) | `overlays/store-{1,2}/data/train.jsonl` (`ConfigMap/store-training-data`)                                                          | Eliminates false category generalizations, tests true category generalization on `C6`, and prevents cross-silo opposing gradient interference during Stage 4 merging             |
| **Calibrated SFT + Zero-VRAM KL & FedProx**                               | `KLProxTrainer` (`with torch.no_grad(), model.disable_adapter():`, `kl_beta=0.15`, `proximal_mu=0.05`) + vLLM Level-1 Sleep/Wake (`POST /sleep?level=1` / `POST /wake_up`)                                                                                                                                                                                                                                                     | `apps/fed-lora/clientapp.py`                                                                                                       | Prevents memorization collapse and bounds weight drift from base Gemma 4 with 0 MB extra teacher VRAM while freeing vLLM KV cache during training                                |
| **Energy-Balanced Cross-Subspace Residual Projection (`subspace_resid`)** | Decomposes each client update into shared refusal subspace $\hat{R}$ and orthogonal store-unique residuals $\hat{F}_1, \hat{F}_2$ ($B_{\text{merged}}(\gamma) = \hat{R} + g_1 \hat{F}_1 + g_2 \hat{F}_2$ at $\gamma = 0.85$, inverse-energy gains `1.40x/1.30x`, `\|\|B_merged\|\|_F = 19.44`)                                                                                                                                 | `apps/fed-lora/serverapp.py`                                                                                                       | Eliminates shared-refusal logit inflation ($\cos(B_1, B_2) \approx 0.62$) while equalizing Store 1 (`45d`) and Store 2 (`STORE-VIP-99`) domain signal energy across all 3 rounds |
| **Transactional Two-Phase Canary Quarantine**                             | Server writes candidate weights to `adapters/gemma4-e2b/candidate/round-{r}/` $\rightarrow$ Edge evaluates `store-fed-lora-candidate` via 14-probe judge $\rightarrow$ Server atomically promotes to `promoted/latest/` iff `verdict == "PROMOTE"`                                                                                                                                                                             | `apps/fed-lora/serverapp.py`, `apps/fed-lora/clientapp.py`                                                                         | Guarantees production `store-fed-lora-promoted` slot is never overwritten by a degraded or poisoned federated round                                                              |
| **Decentralized Zero-VRAM Edge Judge**                                    | Held-out 6-category `canary_suite.json` (`C1`–`C6`, `14` probes, `0/14` prompt overlap with training) + two-pass `eval_local_gemma_judge.py` (`Pass-1` deterministic domain regex + `Pass-2` zero-VRAM base-model judge) achieving **`14/14 [100.00%] -> PROMOTE`**                                                                                                                                                            | `apps/fed-lora/canary_suite.json`, `scripts/eval_local_gemma_judge.py`, `apps/fed-lora/clientapp.py`, `apps/fed-lora/serverapp.py` | Audits and gates adapter promotion at 0 MB extra GPU VRAM without sharing private store rubrics across stores                                                                    |

<!-- mdformat on -->

💡 **TIP — Presenter Talking Point (Why Store 1 Never Trains on or Evaluates
Store 2's Secret Data):**

1.  **Zero Cross-Silo Curriculum Leakage via KL-Divergence Anchoring
    (`with model.disable_adapter():`):** Each store's training dataset
    (`overlays/store-1/data/train.jsonl` and
    `overlays/store-2/data/train.jsonl`) has **0%** mention of the sibling
    store's policy (`STORE-VIP-99` or `45 days`). Instead of hardcoding sibling
    refusals (which would require an omniscient oracle and create opposing
    gradients during Stage 4 merging), each store pairs genuinely disjoint
    out-of-domain retail abstentions with a zero-VRAM KL tether to the frozen
    4-bit base model—preserving abstention on unseen queries in Stage 3 while
    allowing clean Energy-Balanced Cross-Subspace Residual Projection
    (`subspace_resid`) in Stage 4.
2.  **Transactional Two-Phase Canary Promotion (`candidate/` $\rightarrow$
    `14/14` Gate $\rightarrow$ `promoted/`):** In Stage 4, candidate weights are
    first written to `adapters/gemma4-e2b/candidate/round-{r}/` and loaded into
    the isolated `store-fed-lora-candidate` slot on each store's vLLM server.
    Only after both Store 1 and Store 2 pass the 14-probe canary gate
    (`14/14 [100.00%]`) does `ServerApp.aggregate_evaluate()` copy the verified
    weights to `adapters/gemma4-e2b/promoted/latest/` and promote
    `store-fed-lora-promoted`.

### Verification Commands

```bash
# Stage 3 Siloed Local SFT Hallucination Control & C1-C6 Canary Gate:
./scripts/verify_stage3_siloed_qa.sh

# Stage 5 Federated Global Adapter Hallucination Control & C1-C6 Canary Gate:
./scripts/verify_stage5_federated_qa.sh
```

---

## 6. What's Next

With the Turnkey Demo Lab fully verified, proceed directly to live presentation
execution using the **Primary 5-Stage Demo Runner**
(`scripts/run_full_5stage_demo.sh`) guided by the
**[Interactive Demo Runbook & Script](fed-lora_poc_demo_script.md)**.
