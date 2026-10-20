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

# SFT model deployment using Fleet Packages on Distributed Cloud software only reference implementation

## Overview

This Solution Reference Implementation (SRI) provides step-by-step instructions
to deploy a supervised fine-tuned (SFT) open-weight model on
[Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
bare-metal clusters using
[Google Cloud Config Delivery (`FleetPackage`)](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages)
and
[Config Sync](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/overview).
It instantiates the `<MODEL_NAME>` reference architecture with a **Llama 3.1 8B
SFT** math checkpoint served by [vLLM](https://github.com/vllm-project/vllm)
(`vllm/vllm-openai:v0.32.0`, port `8000`) and a
[Gradio](https://github.com/gradio-app/gradio) validation UI (`ClusterIP` port
`8080`, container port `7860`) inside `Namespace/sft-model-serving`, executed
from a workstation with
[`gcloud`](https://docs.cloud.google.com/sdk/docs/install), `git`,
[`gh`](https://cli.github.com/), and `kubectl` via the
[Connect gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway).

For the system architecture diagram, GPU sizing methodology, and design
trade-offs, see **Architecture and design** in the
[Solution Reference Architecture (SRA)](../README.md). For day-2 UI testing,
telemetry, upgrades (`v2.0.0`), and forward rollbacks (`v2.0.1`), see the
[Solution User Guide (SUG)](user-guide.md).

<!-- prettier-ignore -->
> [!WARNING]
> Reference implementation disclaimer. This guide and its Apache 2.0 sample
> manifests are provided for architectural evaluation and reference purposes
> only, without official product support or service-level agreement (SLA)
> warranty. Validate all sizing, security, and operational controls against your
> production requirements before deployment.

## Objectives

- Configure least-privilege publisher and keyless
  [Fleet Workload Identity](https://docs.cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity)
  Google service accounts.
- Initialize a customer GitOps repository (standalone root layout or
  `GoogleCloudPlatform/gdc-solutions` fork) and link it to
  [Cloud Build](https://docs.cloud.google.com/build/docs/overview).
- Customize [Kustomize](https://github.com/kubernetes-sigs/kustomize) DRY
  manifests, render the plain-KRM WET bundle, merge a pull request, and push tag
  `v1.0.0`.
- Onboard the target cluster (Config Sync, least-privilege RBAC,
  `gcs-credential-config` `ConfigMap`, and GPU `PodMonitoring`) and create the
  `FleetPackage`.
- Verify the rollout, keyless checkpoint download, and OpenAI-compatible
  inference response.

## Before you begin

### Prerequisites (cluster setup)

- Distributed Cloud software only for bare metal 1.35 or later (validated on
  Distributed Cloud software only `1.35.0-gke.525` / Kubernetes
  `v1.35.2-gke.300`), standalone cluster registered to a fleet in your Google
  Cloud project; see
  [Distributed Cloud software only installation preparation](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prep).
- One dedicated single-node NVIDIA GPU sized per **Hardware constraints** in the
  SRA (validated on RTX PRO 6000 Blackwell 96 GB), with the
  [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
  `nvidia` `RuntimeClass`, and
  [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) installed; see
  [Configure GPUs on bare metal](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-manual-use).
- NVIDIA driver branch `580+` for `vllm/vllm-openai:v0.32.0` (validated on
  `580.126.20`), or branch `575–579` with `vllm/vllm-openai:v0.32.0-cu129` in
  `src/base/vllm-llama-sft-deployment.yaml` (verify `v0.32.0-cu129` on `575–579`
  hosts before production rollout).
- `StorageClass` `local-shared` and at least `250 GiB` local disk on the GPU
  node (`100Gi` `ReadWriteOnce` `PersistentVolumeClaim` cache plus images and
  kubelet headroom).
- Application logging and
  [Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus)
  (`enableGMPForApplications`) enabled; see
  [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)
  and
  [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics).
- Outbound HTTPS (`443`) from cluster nodes to `*.googleapis.com`,
  [Cloud Storage](https://docs.cloud.google.com/storage/docs/introduction),
  `gcr.io`, `us-docker.pkg.dev`, and Docker Hub (or
  [Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs/overview)
  mirrors).

<!-- prettier-ignore -->
> [!TIP]
> Mirror the three pinned images (`vllm/vllm-openai:v0.32.0`,
> `gcr.io/google.com/cloudsdktool/cloud-sdk:589.0.0-slim`, and
> `us-docker.pkg.dev/google-samples/containers/gke/gradio-app:v1.0.4`) into
> Artifact Registry and update `image:` in `src/base/` to avoid Docker Hub rate
> limits.

### Client workstation prerequisites

- [`gcloud` CLI](https://docs.cloud.google.com/sdk/docs/install), authenticated
  (`gcloud auth login`) to the fleet host project.
- `kubectl` with Kustomize v5 or later (`kubectl kustomize`).
- `git`, the [GitHub CLI `gh`](https://cli.github.com/) (authenticated as the
  owner of your GitOps repository), `curl`, and [`jq`](https://jqlang.org/).

### Model checkpoint

- A merged
  [Hugging Face Safetensors](https://github.com/huggingface/safetensors) SFT
  checkpoint in Cloud Storage, such as the output of
  [**Gemini Enterprise Agent Platform** managed open-model fine-tuning](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tuning/open-model-tuning)
  (formerly Vertex AI; see the worked
  [Llama 3 / open-model SFT Jupyter notebook](https://github.com/GoogleCloudPlatform/generative-ai/blob/main/open-models/fine-tuning/get_started_with_oss_tuning_on_vertexai.ipynb)),
  containing `config.json`, `tokenizer.json`, `special_tokens_map.json`, either
  `model.safetensors.index.json` with safetensors shards or a single
  `model.safetensors` file, and optional `generation_config.json` /
  `tokenizer_config.json`. The bundle stores one immutable prefix per model
  version, defaulting to `gs://BUCKET/sft-model-serving/checkpoints/v1/`.
- Compliance with the upstream model license for every deployment (for example,
  the Llama 3.1 Community License when serving a Llama 3.1 derivative).

### Identities and roles

- **Platform Administrator:** permissions to enable Google Cloud APIs, manage
  service accounts and IAM policy bindings, create Cloud Build repository
  connections and `FleetPackage` resources, update fleet membership labels, and
  apply cluster onboarding RBAC.
- **Application Operator:** write access to the GitOps repository (pull requests
  and tags) and namespace RBAC in `sft-model-serving` (`get`/`list` pods and
  Services, read pod logs, and create `pods/portforward` and `pods/exec`).
- **Machine-user (bot) GitHub account:** dedicated read-only account that
  authorizes the 2nd-gen Cloud Build GitHub connection so personal developer
  tokens never enter
  [Google Cloud Secret Manager](https://docs.cloud.google.com/secret-manager/docs/overview)
  and zero Git secrets sit on clusters.

### Central reference configuration

- [Workstation] Create the local working directory and `.env` configuration
  file. Set `REGION` to any supported Google Cloud region (for example
  `us-central1`); both the Cloud Build repository connection and the
  `FleetPackage` use this same region.

```bash
export SOLUTION_HOME="${HOME}/gdcso-solutions/sft-model-serving"
mkdir -p "${SOLUTION_HOME}"
cat << 'EOF' > "${SOLUTION_HOME}/.env" && echo "Successfully created." || echo "Failed to create!"
# Working directory
SOLUTION_HOME="${HOME}/gdcso-solutions/sft-model-serving"
# Google Cloud and fleet
PROJECT_ID="PROJECT_ID"
PROJECT_NUMBER="PROJECT_NUMBER"
REGION="us-central1"
MEMBERSHIP="MEMBERSHIP"
# Identities
PUBLISHER_SA_NAME="PUBLISHER_SA_NAME"
GSA_NAME="GSA_NAME"
# Checkpoint
BUCKET="BUCKET"
TUNING_OUTPUT_URI="TUNING_OUTPUT_URI"
# GitOps repository and delivery (supports standalone repo OR gdc-solutions fork)
GITOPS_OWNER="GITOPS_OWNER"
GITOPS_REPO="sft-model-serving-gitops"
SOLUTION_SUBDIR="."
GITOPS_DIR="${HOME}/sft-model-serving-gitops"
CONNECTION="CONNECTION"
REPOSITORY="REPOSITORY"
FLEET_PACKAGE="sft-model-serving"
RELEASE_TAG="v1.0.0"
NAMESPACE="sft-model-serving"
DCGM_NAMESPACE="nvidia-gpu-operator"
EOF
```

Replace the following:

- `PROJECT_ID`, `PROJECT_NUMBER`: Google Cloud project ID and number hosting
  your fleet.
- `REGION`: Google Cloud region for both the Cloud Build connection and
  `FleetPackage` (for example `us-central1`).
- `MEMBERSHIP`: fleet membership ID of the target bare-metal cluster.
- `PUBLISHER_SA_NAME`, `GSA_NAME`: names for the publisher service account and
  checkpoint reader Google service account.
- `BUCKET`, `TUNING_OUTPUT_URI`: checkpoint bucket name (without `gs://`) and
  source `gs://` folder URI (without trailing slash).
- `GITOPS_OWNER`, `GITOPS_REPO`, `SOLUTION_SUBDIR`, `GITOPS_DIR`: GitHub owner
  plus repository layout—keep defaults for **Option A** (standalone repo), or
  set `GITOPS_REPO="gdc-solutions"`,
  `SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`,
  `GITOPS_DIR="${HOME}/gdc-solutions"` for **Option B** (monorepo fork).
- `CONNECTION`, `REPOSITORY`: Cloud Build connection and repository link names
  in `REGION`.
- `DCGM_NAMESPACE`: namespace running `nvidia-dcgm-exporter` (`gpu-operator` on
  Helm installs or `nvidia-gpu-operator`).

- [Workstation] Source the environment configuration in every new shell session.

```bash
export SOLUTION_HOME="${HOME}/gdcso-solutions/sft-model-serving"
set -a; source "${SOLUTION_HOME}/.env"; set +a
```

## Set up environment and credentials

- [Workstation] Enable the required Google Cloud APIs
  (`artifactregistry.googleapis.com` stores Config Delivery's auto-created
  `fleet-packages` OCI bundle repository in `REGION`):

```bash
gcloud services enable \
    configdelivery.googleapis.com \
    anthosconfigmanagement.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    gkehub.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}"
```

- [Workstation] Fetch cluster credentials through the Connect gateway and verify
  node readiness.

```bash
gcloud container fleet memberships get-credentials "${MEMBERSHIP}" --project="${PROJECT_ID}"
kubectl get nodes
```

- [Workstation] Create the per-solution publisher service account and grant the
  IAM roles needed to publish OCI release bundles to Artifact Registry and
  Config Delivery.

```bash
gcloud iam service-accounts create "${PUBLISHER_SA_NAME}" \
    --display-name="Fleet Package publisher for sft-model-serving" \
    --project="${PROJECT_ID}"
for ROLE in roles/configdelivery.resourceBundlePublisher roles/artifactregistry.writer roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --role="${ROLE}" --condition=None
done
```

- [Workstation] Copy the merged SFT checkpoint files into version prefix `v1` in
  Cloud Storage.

```bash
gcloud storage cp -r "${TUNING_OUTPUT_URI%/}/*" "gs://${BUCKET}/sft-model-serving/checkpoints/v1/"
```

- [Workstation] Create the keyless workload Google service account, grant
  read-only access on the checkpoint bucket, and bind Fleet Workload Identity to
  Kubernetes `ServiceAccount` `${NAMESPACE}/vllm-llama-sft-sa`:

```bash
gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name="sft-model-serving checkpoint reader" \
    --project="${PROJECT_ID}"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/storage.objectViewer"
gcloud iam service-accounts add-iam-policy-binding \
    "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/vllm-llama-sft-sa]" \
    --project="${PROJECT_ID}"
```

## Initialize and connect the GitOps repository

Choose **either** Option A (a dedicated standalone repository with its own clean
commit history and repository-scoped SemVer tag namespace) **or** Option B (a
fork of `GoogleCloudPlatform/gdc-solutions`).

<!-- prettier-ignore -->
> [!NOTE]
> Set `SEED_REF` to `main` (default) or override it to a specific release tag or
> staging branch when testing pre-release changes before merging into `main`.

### Option A: Create a standalone GitOps repository from scratch

- [Workstation] Create a private GitHub repository with `fleet-package/` at its
  root (`SOLUTION_SUBDIR="."`), seed it from the Apache-2.0 reference sample,
  set `cloudBuildRepository.path` to `fleet-package/environments`, and push
  `main`:

```bash
gh repo create "${GITOPS_OWNER}/${GITOPS_REPO}" --private
git clone "https://github.com/${GITOPS_OWNER}/${GITOPS_REPO}.git" "${GITOPS_DIR}"
SEED_REF="${SEED_REF:-main}"
TMP_SEED="$(mktemp -d)"
git init -q "${TMP_SEED}"
git -C "${TMP_SEED}" remote add origin https://github.com/GoogleCloudPlatform/gdc-solutions.git
git -C "${TMP_SEED}" sparse-checkout set software-only/bare-metal/sft-model-serving/fleet-package
git -C "${TMP_SEED}" fetch --depth 1 origin "${SEED_REF}"
git -C "${TMP_SEED}" checkout -q FETCH_HEAD
cp -R "${TMP_SEED}/software-only/bare-metal/sft-model-serving/fleet-package" "${GITOPS_DIR}/"
rm -rf "${TMP_SEED}"
sed -i 's|software-only/bare-metal/sft-model-serving/fleet-package/environments|fleet-package/environments|g' \
    "${GITOPS_DIR}/fleet-package/fleetpackage.yaml"
cd "${GITOPS_DIR}" && git checkout -B main
git add fleet-package
git commit -m "chore: initialize standalone SFT serving GitOps repository"
git push -u origin main
```

### Option B: Fork the public reference repository

- [Workstation] For the monorepo layout (`GITOPS_REPO="gdc-solutions"`,
  `SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`), fork
  `GoogleCloudPlatform/gdc-solutions` (pass `--org "${GITOPS_OWNER}"` for an
  organization) and clone it. In a shared fork, use disjoint bare SemVer major
  ranges per solution or prefer Option A (see **Design decision** in the SRA):

```bash
gh repo fork GoogleCloudPlatform/gdc-solutions --clone=false
git clone "https://github.com/${GITOPS_OWNER}/${GITOPS_REPO}.git" "${GITOPS_DIR}"
```

<!-- prettier-ignore -->
> [!NOTE]
> Because Config Delivery requires bare three-part SemVer tags (`v1.0.0`,
> `v2.0.0`, `v2.0.1`), Git tags in a shared `gdc-solutions` fork are
> repository-global. If you manage multiple solutions from one fork, use
> disjoint SemVer major ranges per solution—or prefer Option A so each solution
> has an isolated repository and tag namespace.

### Connect the GitOps repository to Cloud Build

- [Workstation] Grant the Cloud Build service agent `roles/secretmanager.admin`
  so creating the 2nd-gen GitHub connection can store the machine-user OAuth
  token in Secret Manager; see
  [Connect to a GitHub repository](https://docs.cloud.google.com/build/docs/automating-builds/github/connect-repo-github).

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com" \
    --role="roles/secretmanager.admin" --condition=None
```

- [Workstation] Create the 2nd-gen Cloud Build GitHub connection in `REGION`.

```bash
gcloud builds connections create github "${CONNECTION}" \
    --region="${REGION}" --project="${PROJECT_ID}"
```

- [Console] Open the authorization URL printed by the previous command, sign in
  to GitHub as the dedicated machine-user (bot) account, authorize Cloud Build,
  and install the Cloud Build GitHub App scoped strictly to
  `${GITOPS_OWNER}/${GITOPS_REPO}`.

- [Workstation] Confirm that `installationState.stage` prints `COMPLETE`, then
  link your GitOps repository:

```bash
gcloud builds connections describe "${CONNECTION}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(installationState.stage)"
gcloud builds repositories create "${REPOSITORY}" \
    --remote-uri="https://github.com/${GITOPS_OWNER}/${GITOPS_REPO}.git" \
    --connection="${CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}"
```

The output is similar to the following:

```text
COMPLETE
```

<!-- prettier-ignore -->
> [!NOTE]
> In production, authorize the connection with a dedicated machine-user (bot)
> GitHub account rather than a personal developer account.

## Customize and release the bundle

Under `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/`,
`ConfigMap/vllm-llama-sft-config` mounts two files required by the Llama 3.1 8B
SFT checkpoint (whose exported `tokenizer_config.json` omits a chat template and
lists only `128001` as `eos_token_id`): `llama3_sft_chat_template.jinja`
(`<|start_header_id|>` / `<|eot_id|>` headers) and `generation_config.json`
(`eos_token_id: [128001, 128009]`, `temperature: 0.2`, `top_p: 1.0`).

<!-- prettier-ignore -->
> [!TIP]
> For another `<MODEL_NAME>` family, update model names and
> `--max-model-len`/`--dtype` in `src/base/vllm-llama-sft-deployment.yaml`,
> `MODEL_ID` in `src/base/gradio-llama-sft-deployment.yaml`, and the Jinja
> template and stop token IDs in `src/base/vllm-llama-sft-config.yaml`.

- [Workstation] Create release branch `sft-model-serving-v1.0.0`, update
  `REGION` and all project-wide `YOUR_*` placeholders across the DRY sources,
  `fleetpackage.yaml`, and `configdelivery-rbac.yaml`, and verify that zero
  placeholders remain.

```bash
cd "${GITOPS_DIR}" && git checkout -b sft-model-serving-v1.0.0
BUNDLE_ROOT="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package"
find "${BUNDLE_ROOT}/src" "${BUNDLE_ROOT}/fleetpackage.yaml" "${BUNDLE_ROOT}/configdelivery-rbac.yaml" -name '*.yaml' \
    -exec sed -i \
        -e "s|/locations/us-central1/|/locations/${REGION}/|g" \
        -e "s|--location=us-central1|--location=${REGION}|g" \
        -e "s/YOUR_PROJECT_ID/${PROJECT_ID}/g" \
        -e "s/YOUR_PROJECT_NUMBER/${PROJECT_NUMBER}/g" \
        -e "s/YOUR_GSA_NAME/${GSA_NAME}/g" \
        -e "s/YOUR_BUCKET/${BUCKET}/g" \
        -e "s/YOUR_CONNECTION/${CONNECTION}/g" \
        -e "s/YOUR_REPOSITORY/${REPOSITORY}/g" \
        -e "s/YOUR_PUBLISHER_SA_NAME/${PUBLISHER_SA_NAME}/g" {} +
rc=0
grep -rn "YOUR_" "${BUNDLE_ROOT}/src" "${BUNDLE_ROOT}/fleetpackage.yaml" "${BUNDLE_ROOT}/configdelivery-rbac.yaml" || rc=$?
if [ "${rc}" -eq 1 ]; then
  echo "No placeholders left."
else
  echo "ERROR: unexpected placeholder matches or missing files (grep rc=${rc})" >&2
  false
fi
```

<!-- prettier-ignore -->
> [!NOTE]
> Confirm that the script prints `No placeholders left.`
> `fleet-package/gcs-credential-config.yaml` intentionally retains
> `YOUR_MEMBERSHIP` outside `src/base/` and is applied once per cluster in
> [Prepare the target cluster](#prepare-the-target-cluster) so
> `environments/default/manifests.yaml` stays identical across the fleet.

- [Workstation] Render `environments/default/manifests.yaml` from the DRY
  sources and review the diff (in Option A without monorepo `prettier`,
  `render.sh` skips formatting, leaving harmless indentation-only diffs on first
  run):

```bash
cd "${GITOPS_DIR}"
"${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/render.sh"
git status --short
git diff --stat
```

```text
Rendered .../fleet-package/src/overlays/default to .../fleet-package/environments/default/manifests.yaml
Format .../fleet-package/environments/default/manifests.yaml with prettier before you commit it.
```

- [Workstation] Commit the DRY and rendered WET files together, open a pull
  request against `main`, and merge it after review.

```bash
cd "${GITOPS_DIR}"
git add "${SOLUTION_SUBDIR}"
git commit -m "sft-model-serving: configure release v1.0.0"
git push origin sft-model-serving-v1.0.0
gh pr create --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --base main \
    --head sft-model-serving-v1.0.0 --fill
gh pr merge sft-model-serving-v1.0.0 --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --merge
```

- [Workstation] Tag the merged commit on `main` with bare three-part SemVer tag
  `v1.0.0`.

```bash
cd "${GITOPS_DIR}" && git checkout main && git pull origin main
git tag "${RELEASE_TAG}"
git push origin "${RELEASE_TAG}"
```

## Prepare the target cluster

- [Workstation] Enable Config Sync on the target fleet membership; see
  [Install Config Sync](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/how-to/installing-config-sync).

```bash
gcloud beta container fleet config-management enable --project="${PROJECT_ID}"
cat << 'EOF' > "${SOLUTION_HOME}/config-sync-apply-spec.yaml" && echo "Successfully created." || echo "Failed to create!"
applySpecVersion: 1
spec:
  configSync:
    enabled: true
EOF
gcloud beta container fleet config-management apply \
    --membership="${MEMBERSHIP}" \
    --config="${SOLUTION_HOME}/config-sync-apply-spec.yaml" \
    --project="${PROJECT_ID}"
kubectl get namespace config-management-system
```

<!-- prettier-ignore -->
> [!NOTE]
> On some pre-configured clusters `config-management-system` is already present;
> running the fleet `config-management` enablement command ensures consistent
> fleet state across newly installed bare-metal clusters.

- [Workstation] Apply the namespace-scoped `Role` and `RoleBinding`
  (`configdelivery-rootsync-manager`, granting `get`, `create`, `patch`, and
  `delete` on `rootsyncs.configsync.gke.io` instead of `cluster-admin`) in
  `config-management-system`:

```bash
kubectl apply -f "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/configdelivery-rbac.yaml"
```

<!-- prettier-ignore -->
> [!CAUTION]
> Never bind the Config Delivery service agent to `cluster-admin`. Without
> `RoleBinding/configdelivery-rootsync-manager` in `config-management-system`,
> rollouts stall with `403 Forbidden` on `rootsyncs.configsync.gke.io`.

<!-- prettier-ignore -->
> [!NOTE]
> Config Sync's `reconciler-manager` binds `root-reconciler-sft-model-serving`
> to `cluster-admin` by default. Because Config Delivery's `rollouts-manager`
> field manager owns only `spec.override.resources`, operators requiring strict
> least-privilege scoping can pair a minimal `ClusterRole` (granting
> `resourcegroups` inventory access, `namespaces` management restricted via
> `resourceNames` to `<NAMESPACE>`, and cluster-scoped read-only `get`, `list`,
> `watch` on the 6 non-Secret packaged kinds required by Config Sync status
> informers: `serviceaccounts`, `persistentvolumeclaims`, `configmaps`,
> `services`, `deployments.apps`, and
> `podmonitorings.monitoring.googleapis.com`) with a namespace `Role` in
> `<NAMESPACE>` for write verbs, applied to `spec.override.roleRefs` via
> Server-Side Apply under a distinct field manager (`kubectl apply --server-side
> --field-manager=platform-admin -f -`). Disjoint Server-Side Apply field
> ownership preserves `roleRefs` across in-place `FleetPackage` upgrades and
> rollbacks; re-apply only if the `RootSync` is deleted and recreated.

- [Workstation] Create the target namespace and apply this cluster's keyless
  Fleet Workload Identity credential `ConfigMap` (`gcs-credential-config`),
  substituting `YOUR_PROJECT_ID`, `YOUR_GSA_NAME`, and `YOUR_MEMBERSHIP`; see
  [Authenticate to Google Cloud APIs from fleet workloads](https://docs.cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity).

```bash
kubectl apply -f "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/src/base/namespace.yaml"
sed -e "s/YOUR_PROJECT_ID/${PROJECT_ID}/g" \
    -e "s/YOUR_GSA_NAME/${GSA_NAME}/g" \
    -e "s/YOUR_MEMBERSHIP/${MEMBERSHIP}/g" \
    "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/gcs-credential-config.yaml" \
    | kubectl apply -f -
```

- [Workstation] Apply a `PodMonitoring` resource (`dcgm-gmp`) in
  `DCGM_NAMESPACE` so Google Cloud Managed Service for Prometheus scrapes GPU
  hardware utilization and framebuffer memory metrics from NVIDIA DCGM Exporter;
  see
  [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics).

```bash
kubectl apply -f - <<EOF
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: dcgm-gmp
  namespace: ${DCGM_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  endpoints:
  - port: metrics
    interval: 30s
EOF
```

- [Workstation] Label the fleet membership so the `FleetPackage` targets this
  cluster.

```bash
gcloud container fleet memberships update "${MEMBERSHIP}" \
    --location=global --update-labels=app-tier=sft-model-serving \
    --project="${PROJECT_ID}"
```

## Create the FleetPackage

- [Workstation] Create the `FleetPackage` in `REGION`.

```bash
gcloud container fleet packages create "${FLEET_PACKAGE}" \
    --source="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/fleetpackage.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"
```

## Verification

- [Workstation] Wait until the rollout reaches state `COMPLETED` for release
  `v1-0-0`.

```bash
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}"
```

- [Workstation] Verify that `RootSync` is synced and both serving and UI pods
  are `Running` and `Ready`.

```bash
kubectl get rootsyncs.configsync.gke.io -n config-management-system
kubectl -n "${NAMESPACE}" get pods
```

The output is similar to the following:

```text
NAME                                           READY   STATUS    RESTARTS   AGE
gradio-llama-sft-deployment-6c9f7b8d5d-x2k4p   1/1     Running   0          6m
vllm-llama-sft-deployment-7d8b9c6f4b-q7m2n     1/1     Running   0          6m
```

- [Workstation] Confirm in the `gcs-model-downloader` logs that Fleet Workload
  Identity authenticated as your dedicated workload Google service account and
  verified all checkpoint files before writing `.complete`.

```bash
kubectl -n "${NAMESPACE}" logs deploy/vllm-llama-sft-deployment -c gcs-model-downloader
```

The output is similar to the following:

```text
Checking the cache for model version 'v1'...
Active account: GSA_NAME@PROJECT_ID.iam.gserviceaccount.com
Downloading gs://BUCKET/sft-model-serving/checkpoints/v1 with fleet Workload Identity credentials...
Checking the required files for model version 'v1'...
Deleting other model versions from the cache...
Model version 'v1' sync and cache maintenance complete.
```

<!-- prettier-ignore -->
> [!NOTE]
> Validate clean-state `FleetPackage` onboarding, GPU scheduling, and Fleet
> Workload Identity token exchange on a staging bare-metal cluster before
> rolling out across production sites.

- [Workstation] Confirm GPU memory allocation inside the vLLM container.

```bash
kubectl -n "${NAMESPACE}" exec deploy/vllm-llama-sft-deployment -c vllm-container -- \
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

The output on the 96 GB validation GPU is similar to the following:

```text
memory.used [MiB], memory.total [MiB]
86963 MiB, 97887 MiB
```

- [Workstation] Port-forward the vLLM `Service`, check `/health`, and inspect
  `/v1/models`.

```bash
kubectl -n "${NAMESPACE}" port-forward svc/vllm-llama-sft-service 8000:8000 >/dev/null &
PF_PID=$!
sleep 5
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health
curl -s http://localhost:8000/v1/models | jq -r '.data[].id'
```

The output is similar to the following:

```text
200
llama-3.1-8b-sft
llama-3.1-8b-sft-v1.0.0
llama-3.1-8b-sft-v1
```

- [Workstation] Send a GSM8K math word problem to `/v1/chat/completions`, verify
  `finish_reason` is `stop`, and close the tunnel.

```bash
curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-3.1-8b-sft", "max_tokens": 512, "temperature": 0,
         "messages": [{"role": "user", "content": "Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May?"}]}' \
    | jq -r '.choices[0].finish_reason, .choices[0].message.content'
kill "${PF_PID}"
```

The output is similar to the following:

```text
stop
...
#### 72
The answer is: 72
```

## Operations

See the Solution User Guide (SUG) for interactive Gradio validation, application
and GPU monitoring, promoting checkpoint `v2` (`v2.0.0`), and forward rollback
to `v1` (`v2.0.1`).

## Troubleshooting

<!-- mdformat off -->

| Symptom                                                                                                                              | Cause                                                                                                            | Resolution                                                                                                                                         |
| :----------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gcloud builds repositories create` fails with `FAILED_PRECONDITION: repository ... is not accessible to the Cloud Build GitHub App` | The connection stores a different GitHub App installation ID than the one installed on your repository           | Run `gcloud builds connections update github "${CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}" --app-installation-id=INSTALLATION_ID` |
| Rollout fails with `RESOURCE_BUNDLE_BUILD_FAILED` (`could not parse reference` or invalid version)                                   | The tag uses a slash prefix (`sft-model-serving/v1.0.0`) or prerelease suffix (`-rc1`)                           | Push a bare three-part SemVer tag (`v1.0.0`) and update `FleetPackage` `tag`                                                                       |
| Rollout stalls with `403 Forbidden` on `rootsyncs`                                                                                   | Missing Config Delivery RBAC in `config-management-system`                                                       | Apply `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/configdelivery-rbac.yaml`                                                                    |
| Config Sync error `KNV2010` about `kind: Kustomization`                                                                              | A `kustomization.yaml` file is inside `fleet-package/environments/default/`                                      | Keep only plain rendered KRM in `environments/default/`; rerun `render.sh`                                                                         |
| `FleetPackage` targets zero clusters                                                                                                 | Target cluster membership lacks `app-tier=sft-model-serving`                                                     | Run `gcloud container fleet memberships update` to apply `app-tier=sft-model-serving`                                                              |
| vLLM pod stuck in `ContainerCreating` with `configmap "gcs-credential-config" not found`                                             | Per-cluster onboarding `ConfigMap` wasn't applied (or cluster was previously un-labeled, deleting `<NAMESPACE>`) | Re-apply `src/base/namespace.yaml` and `gcs-credential-config.yaml` with `YOUR_PROJECT_ID`, `YOUR_GSA_NAME`, and `YOUR_MEMBERSHIP` substituted     |
| `initContainer` fails with missing `config.json`, `tokenizer.json`, `special_tokens_map.json`, or `model.safetensors*`               | `MODEL_GCS_URI` prefix is empty or incomplete                                                                    | Upload all checkpoint files to the target Cloud Storage prefix                                                                                     |
| `initContainer` shows node service account or `403` on `storage.objects.get`                                                         | Fleet Workload Identity binding or audience mismatch                                                             | Check `roles/iam.workloadIdentityUser`, bucket IAM, and `MEMBERSHIP` in `gcs-credential-config.yaml`                                               |
| Pod `Pending` with `Insufficient nvidia.com/gpu`                                                                                     | GPU Operator not healthy or another pod holds the GPU                                                            | Inspect NVIDIA GPU Operator pods and free the GPU                                                                                                  |
| vLLM fails at startup with CUDA driver error                                                                                         | Driver branch `575–579` with default CUDA 13 image, or branch older than `575`                                   | Upgrade NVIDIA driver to `580+`, or select `vllm/vllm-openai:v0.32.0-cu129` on driver branch `575–579`                                             |
| Answers emit `<\|im_end\|>` or never stop                                                                                            | Chat template or `generation_config.json` mismatch with SFT training format                                      | Verify `--chat-template` and `--generation-config` mount `/etc/vllm/config`                                                                        |
| Image pull slow or `429 Too Many Requests`                                                                                           | Docker Hub anonymous pull rate limit                                                                             | Mirror pinned images into Artifact Registry                                                                                                        |
| `gcloud container fleet packages delete` fails with `FAILED_PRECONDITION`                                                            | Child `Rollout` resources still exist                                                                            | Pass `--force` to `gcloud container fleet packages delete`                                                                                         |
| `PersistentVolumeClaim/sft-model-cache-pvc` stuck in `Terminating`                                                                   | Unmanaged pod still mounts `sft-model-cache-pvc`                                                                 | Delete any unmanaged pod mounting the PVC so `kubernetes.io/pvc-protection` clears                                                                 |

<!-- mdformat on -->

## Clean up

- [Workstation] Remove the membership label first so Config Delivery prunes the
  managed `RootSync` and workload namespace cleanly in the foreground, then wait
  for `COMPLETED`.

```bash
gcloud container fleet memberships update "${MEMBERSHIP}" \
    --location=global --remove-labels=app-tier --project="${PROJECT_ID}"
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}"
kubectl get rootsyncs.configsync.gke.io -n config-management-system
```

Removing `app-tier` deletes `RootSync` and `Namespace/sft-model-serving`
(including `sft-model-cache-pvc` and `gcs-credential-config`). Verify that the
namespace has terminated and inspect any `Released` local PersistentVolumes.

```bash
kubectl delete namespace "${NAMESPACE}" --ignore-not-found
kubectl get pv
```

- [Workstation] Delete the `FleetPackage` and its rollout records (`--force`),
  Cloud Build repository and connection, IAM bindings, and service accounts.

```bash
gcloud container fleet packages delete "${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}" --force
gcloud builds repositories delete "${REPOSITORY}" \
    --connection="${CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}"
gcloud builds connections delete "${CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}"
gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/storage.objectViewer"
for ROLE in roles/configdelivery.resourceBundlePublisher roles/artifactregistry.writer roles/logging.logWriter; do
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --role="${ROLE}" --condition=None
done
gcloud iam service-accounts delete "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}"
gcloud iam service-accounts delete "${PUBLISHER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}"
```

- [Workstation] If no other 2nd-gen Cloud Build connection in the project needs
  it, remove `roles/secretmanager.admin` from the Cloud Build service agent and
  delete any retained regional OAuth token secret created by the connection.

```bash
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com" \
    --role="roles/secretmanager.admin" --condition=None
CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.${REGION}.rep.googleapis.com/" \
    gcloud secrets list --location="${REGION}" --project="${PROJECT_ID}" \
    --filter="name:${CONNECTION}-github-oauthtoken"
CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.${REGION}.rep.googleapis.com/" \
    gcloud secrets delete SECRET_NAME --location="${REGION}" --project="${PROJECT_ID}"
```

Replace the following:

- `SECRET_NAME`: regional secret ID (`${CONNECTION}-github-oauthtoken-*`) listed
  by the previous command if deleting the Cloud Build connection did not remove
  it automatically.

- [Workstation] Remove the Config Delivery RBAC manifest, DCGM `PodMonitoring`
  resource, and local working clones and configuration files.

```bash
kubectl delete -f "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/configdelivery-rbac.yaml" --ignore-not-found
kubectl delete podmonitoring dcgm-gmp -n "${DCGM_NAMESPACE}" --ignore-not-found
rm -rf "${GITOPS_DIR}" "${SOLUTION_HOME}"
rmdir --ignore-fail-on-non-empty "${HOME}/gdcso-solutions" 2>/dev/null || true
```

<!-- prettier-ignore -->
> [!NOTE]
> Retained by default (delete only if unused elsewhere):
> `gs://${BUCKET}/sft-model-serving/checkpoints/v1/` (`gcloud storage rm -r`),
> `${GITOPS_OWNER}/${GITOPS_REPO}` (`gh repo delete`) and its GitHub App
> installation, `fleet-packages` in Artifact Registry (`gcloud artifacts
> repositories delete fleet-packages --location=${REGION}
> --project=${PROJECT_ID}`), and cluster Config Sync.

## What's next

- [Solution Reference Architecture (SRA)](../README.md)
- [Solution User Guide (SUG)](user-guide.md): Gradio validation, telemetry,
  `v2.0.0` upgrades, and `v2.0.1` rollbacks
