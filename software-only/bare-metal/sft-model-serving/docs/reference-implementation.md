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
to automate the deployment of a supervised fine-tuned (SFT) open-weight model on
[Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
bare-metal clusters through
[Google Cloud Config Delivery (Fleet Packages)](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages)
and
[Config Sync](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/overview).
While the solution architecture supports any single-GPU
[vLLM](https://github.com/vllm-project/vllm)-compatible SFT checkpoint
(`<MODEL_NAME>`) and customer-owned GitOps repository, this guide instantiates
the architecture using a **Llama 3.1 8B SFT** checkpoint (fully fine-tuned on
MetaMathQA math word problems via
[**Gemini Enterprise Agent Platform** open-model tuning](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tuning/open-model-tuning),
formerly Vertex AI; see the
[open-model SFT Jupyter notebook](https://github.com/GoogleCloudPlatform/generative-ai/blob/main/open-models/fine-tuning/get_started_with_oss_tuning_on_vertexai.ipynb))
served on an **NVIDIA RTX PRO 6000 Blackwell GPU** (`vllm/vllm-openai:v0.32.0`).

The rendered 9-resource `default` variant bundle deploys a `Namespace`
(`sft-model-serving`), a workload `ServiceAccount` for keyless
[Fleet Workload Identity](https://docs.cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity),
a `100Gi` local model cache `PersistentVolumeClaim` (`sft-model-cache-pvc`,
`ReadWriteOnce`, `local-shared`), the vLLM `Deployment` with its
model-downloader `initContainer` and [Jinja](https://jinja.palletsprojects.com/)
`ConfigMap`, a [Gradio](https://github.com/gradio-app/gradio) validation
`Deployment`, two `ClusterIP` Services (vLLM on port `8000`; Gradio on port
`8080`, container port `7860`), and a `PodMonitoring` resource for
[Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus).
Because the worked-example checkpoint is fine-tuned on math word problems, smoke
tests verify inference with a math word problem.

You run every command from an operator workstation with
[Google Cloud CLI (`gcloud`)](https://docs.cloud.google.com/sdk/docs/install),
`git`, [GitHub CLI (`gh`)](https://cli.github.com/), and `kubectl` access to the
cluster through the
[Connect gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway).
For architectural trade-offs and component boundaries, see the
[Solution Reference Architecture (SRA)](../README.md). For interactive Gradio
validation, application and GPU monitoring, upgrading to `v2.0.0`, and rolling
back to `v2.0.1`, see the [Solution User Guide (SUG)](user-guide.md).

<!-- prettier-ignore -->
> [!WARNING]
> Reference implementation disclaimer. This guide and its Apache 2.0 sample
> manifests are provided for architectural evaluation and reference purposes
> only, without official product support or service-level agreement (SLA)
> warranty. Validate all sizing, security, and operational controls against your
> production requirements before deployment.

![High-level architecture of SFT model serving with Fleet Packages on Distributed Cloud software only](images/sft-model-serving-architecture.png)

## Objectives

- Configure least-privilege Google Cloud identities: the per-solution publisher
  service account and the keyless Fleet Workload Identity checkpoint reader
  account.
- Initialize your own GitOps repository—either **created from scratch as a
  dedicated standalone repository** (`SOLUTION_SUBDIR="."`) or forked from
  `GoogleCloudPlatform/gdc-solutions`
  (`SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`)—and connect
  it to [Cloud Build](https://docs.cloud.google.com/build/docs/overview) via a
  machine-user account.
- Customize the [Kustomize](https://github.com/kubernetes-sigs/kustomize) DRY
  manifests for your project and model (`<MODEL_NAME>`), render the plain-KRM
  WET bundle, merge through a pull request, and tag release `v1.0.0`.
- Onboard the target bare-metal cluster with Config Sync, least-privilege Config
  Delivery RBAC, the per-cluster Fleet Workload Identity `ConfigMap`, and
  optional DCGM GPU `PodMonitoring`, then create the `FleetPackage`.
- Verify the rollout, keyless
  [Cloud Storage](https://docs.cloud.google.com/storage/docs/introduction)
  download, and OpenAI-compatible vLLM endpoint with a math word problem.

## Before you begin

### Prerequisites (cluster setup)

- Distributed Cloud software only for bare metal 1.35 or later (validated on
  Distributed Cloud software only `1.35.0-gke.525` / Kubernetes
  `v1.35.2-gke.300`), standalone cluster registered to a fleet in your Google
  Cloud project; see
  [Distributed Cloud software only installation preparation](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prep).
- One dedicated single-node edge inference GPU sized for your
  checkpoint—validated with an NVIDIA RTX PRO 6000 Blackwell (96 GB) serving an
  unquantized 8B BF16 checkpoint (for smaller GPUs such as 48 GB L40S/RTX 6000
  Ada or 24 GB L4/RTX 4000 Ada, size context length, concurrency, model
  parameter count, or quantization per the SRA)—with the
  [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
  `nvidia` `RuntimeClass`, `nvidia.com/gpu` resource, and
  [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) installed; see
  [Configure GPUs on bare metal](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-manual-use).
- An NVIDIA driver from branch `580` or later when running the default CUDA 13
  image `vllm/vllm-openai:v0.32.0` (validated with driver `580.126.20`). If your
  GPU node runs NVIDIA driver branch `575–579` (CUDA 12.9), switch the vLLM
  image tag in `src/base/vllm-llama-sft-deployment.yaml` to
  `vllm/vllm-openai:v0.32.0-cu129` (verify `v0.32.0-cu129` on `575–579` hosts
  before production rollout).
- A `StorageClass` named `local-shared`, and at least `250 GiB` of local disk
  space on the GPU node for the `100Gi` cache volume, container images, and
  system reservations.
- Application logging and
  [Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus)
  collection (`enableGMPForApplications`) enabled on the cluster if shipping
  telemetry to
  [Cloud Monitoring](https://docs.cloud.google.com/monitoring/docs/monitoring-overview)
  and [Cloud Logging](https://docs.cloud.google.com/logging/docs/overview); see
  [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)
  and
  [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics).
- Outbound HTTPS (`443`) from cluster nodes to `*.googleapis.com`, Cloud
  Storage, `gcr.io`, `us-docker.pkg.dev`, and Docker Hub (or private
  [Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs/overview)
  image mirrors).

<!-- prettier-ignore -->
> [!TIP]
> Docker Hub rate-limits anonymous pulls and the vLLM image exceeds several
> gigabytes. Mirror the pinned container images into Artifact Registry in your
> Google Cloud project and point the `image:` fields in `src/base/` to your
> private registry.

### Client workstation prerequisites

- [`gcloud` CLI](https://docs.cloud.google.com/sdk/docs/install), authenticated
  (`gcloud auth login`) to the fleet host project.
- `kubectl` with [Kustomize](https://github.com/kubernetes-sigs/kustomize) v5 or
  later (`kubectl kustomize`).
- `git`, the [GitHub CLI `gh`](https://cli.github.com/) (authenticated as the
  owner of your GitOps repository), `curl`, and [`jq`](https://jqlang.org/).

### Model checkpoint

- A merged
  [Hugging Face Safetensors](https://github.com/huggingface/safetensors) SFT
  checkpoint in
  [Cloud Storage](https://docs.cloud.google.com/storage/docs/introduction), such
  as the output of
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

- `PROJECT_ID`, `PROJECT_NUMBER`: the Google Cloud project ID and project number
  hosting your fleet.
- `REGION`: any supported Google Cloud region where Config Delivery and Cloud
  Build 2nd-gen connections are available, for example `us-central1`.
- `MEMBERSHIP`: the fleet membership ID of the target Distributed Cloud software
  only cluster.
- `PUBLISHER_SA_NAME`: name of the per-solution publisher service account, for
  example `sft-model-serving-publisher`.
- `GSA_NAME`: name of the workload Google service account granted read access to
  the checkpoint bucket, for example `sft-model-serving-reader`.
- `BUCKET`: Cloud Storage bucket name holding model checkpoints, without
  `gs://`.
- `TUNING_OUTPUT_URI`: Cloud Storage folder URI containing the fine-tuned merged
  checkpoint files, without a trailing slash.
- `GITOPS_OWNER`: GitHub organization or user owning your GitOps repository.
- `GITOPS_REPO`, `SOLUTION_SUBDIR`, and `GITOPS_DIR`:
  - **Option A — Standalone GitOps repository created from scratch:** keep
    `GITOPS_REPO="sft-model-serving-gitops"`, `SOLUTION_SUBDIR="."`, and
    `GITOPS_DIR="${HOME}/sft-model-serving-gitops"`.
  - **Option B — Fork of `GoogleCloudPlatform/gdc-solutions`:** set
    `GITOPS_REPO="gdc-solutions"`,
    `SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`, and
    `GITOPS_DIR="${HOME}/gdc-solutions"`.
- `CONNECTION`, `REPOSITORY`: names for the Cloud Build connection and
  repository link in `REGION`, for example `sft-gitops-github` and
  `sft-gitops-repo`.
- `DCGM_NAMESPACE`: namespace running `nvidia-dcgm-exporter` on your cluster
  (`gpu-operator` on NVIDIA Helm chart installations or `nvidia-gpu-operator` on
  operator bundles; verify with
  `kubectl get pods -A -l app=nvidia-dcgm-exporter`).

- [Workstation] Source the environment configuration in every new shell session.

```bash
export SOLUTION_HOME="${HOME}/gdcso-solutions/sft-model-serving"
set -a; source "${SOLUTION_HOME}/.env"; set +a
```

## Set up environment and credentials

- [Workstation] Enable the required Google Cloud APIs. Note that
  `artifactregistry.googleapis.com` is required because Config Delivery's
  managed Cloud Build packaging job pushes each packaged release bundle to a
  `fleet-packages` Artifact Registry OCI repository in `REGION` (created
  automatically when publishing a `FleetPackage` release).

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
  Kubernetes service account `${NAMESPACE}/vllm-llama-sft-sa`.

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

A standalone GitOps repository holds `fleet-package/` at its root
(`SOLUTION_SUBDIR="."`):

- `fleet-package/fleetpackage.yaml` — `FleetPackage` specification
  (`resourceBundleSelector.cloudBuildRepository.path: fleet-package/environments`).
- `fleet-package/configdelivery-rbac.yaml` — namespace-scoped `Role` and
  `RoleBinding` in `config-management-system`.
- `fleet-package/gcs-credential-config.yaml` — per-cluster Fleet Workload
  Identity STS audience `ConfigMap` template.
- `fleet-package/render.sh` — Kustomize rendering script outputting
  `fleet-package/environments/default/manifests.yaml`.
- `fleet-package/src/base/` — DRY Kubernetes manifests (`namespace.yaml`,
  `vllm-llama-sft-serviceaccount.yaml`, `sft-model-cache-pvc.yaml`,
  `vllm-llama-sft-config.yaml`, `vllm-llama-sft-deployment.yaml`,
  `vllm-llama-sft-service.yaml`, `vllm-llama-sft-podmonitoring.yaml`,
  `gradio-llama-sft-deployment.yaml`, `gradio-llama-sft-service.yaml`, and
  `kustomization.yaml`).
- `fleet-package/src/overlays/default/kustomization.yaml` and
  `fleet-package/environments/default/manifests.yaml`.

- [Workstation] Create a new private GitHub repository under `GITOPS_OWNER`,
  fetch the `fleet-package/` directory from the Apache-2.0 reference sample
  (without monorepo wrapper files), set `cloudBuildRepository.path` to
  `fleet-package/environments`, and push the initial `main` branch.

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

- [Workstation] If using `GITOPS_REPO="gdc-solutions"` and
  `SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`, fork
  `GoogleCloudPlatform/gdc-solutions` (pass `--org "${GITOPS_OWNER}"` if
  `GITOPS_OWNER` is a GitHub organization rather than your personal account) and
  clone your fork into `GITOPS_DIR`.

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

- [Workstation] Confirm that the connection is `COMPLETE`, then link your GitOps
  repository.

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

The manifests reside under `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/`. In
the worked example (`<MODEL_NAME>` instantiated as `llama-3.1-8b-sft`),
`ConfigMap` `vllm-llama-sft-config` supplies two model-specific files matched to
the Llama 3.1 8B SFT training format:

1. `llama3_sft_chat_template.jinja`: Reproduces the exact Llama 3 turn headers
   (`<|start_header_id|>`, `<|end_header_id|>`, `<|eot_id|>`) used during
   supervised fine-tuning because the exported checkpoint's
   `tokenizer_config.json` omits a chat template (using a generic ChatML
   template emits unmapped strings).
2. `generation_config.json`: Sets `eos_token_id` to `[128001, 128009]`
   (`<|end_of_text|>` and `<|eot_id|>`) with `temperature: 0.2` and
   `top_p: 1.0`, since the exported file includes only `128001`.

<!-- prettier-ignore -->
> [!TIP]
> To serve a different SFT open-weight model family (`<MODEL_NAME>`), update the
> model identifier and `--served-model-name` aliases in
> `src/base/vllm-llama-sft-deployment.yaml` and `MODEL_ID` in
> `src/base/gradio-llama-sft-deployment.yaml`, replace the Jinja chat template
> and `eos_token_id` values in `src/base/vllm-llama-sft-config.yaml` to match
> your model's tokenizer, and tune `--max-model-len` and `--dtype` for your edge
> GPU.

<!-- mdformat off -->

| Placeholder              | Description                                                                                                   | Files                                                                                                                     |
| :----------------------- | :------------------------------------------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------------------------------ |
| `YOUR_PROJECT_ID`        | Fleet host project ID and Fleet Workload Identity pool (`YOUR_PROJECT_ID.svc.id.goog`)                        | `vllm-llama-sft-serviceaccount.yaml`, `vllm-llama-sft-deployment.yaml`, `fleetpackage.yaml`, `gcs-credential-config.yaml` |
| `YOUR_PROJECT_NUMBER`    | Fleet host project number used in `service-YOUR_PROJECT_NUMBER@gcp-sa-configdelivery.iam.gserviceaccount.com` | `configdelivery-rbac.yaml`                                                                                                |
| `YOUR_MEMBERSHIP`        | Fleet membership name of the target cluster (substituted per cluster during onboarding)                       | `gcs-credential-config.yaml`                                                                                              |
| `YOUR_GSA_NAME`          | Workload Google service account reading the checkpoint bucket                                                 | `vllm-llama-sft-serviceaccount.yaml`, `gcs-credential-config.yaml`                                                        |
| `YOUR_BUCKET`            | Cloud Storage bucket storing versioned checkpoints                                                            | `vllm-llama-sft-deployment.yaml`                                                                                          |
| `YOUR_CONNECTION`        | Regional 2nd-gen Cloud Build repository connection name                                                       | `fleetpackage.yaml`                                                                                                       |
| `YOUR_REPOSITORY`        | Linked Cloud Build repository name                                                                            | `fleetpackage.yaml`                                                                                                       |
| `YOUR_PUBLISHER_SA_NAME` | Per-solution publisher Google service account name                                                            | `fleetpackage.yaml`                                                                                                       |

<!-- mdformat on -->

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

The output is similar to the following:

```text
No placeholders left.
```

<!-- prettier-ignore -->
> [!NOTE]
> `fleet-package/gcs-credential-config.yaml` intentionally retains
> `YOUR_MEMBERSHIP` outside `fleet-package/src/base/` and is applied once per
> target cluster in [Prepare the target cluster](#prepare-the-target-cluster) so
> the rendered `environments/default/manifests.yaml` bundle stays 100% identical
> across all clusters matching `app-tier=sft-model-serving`.

- [Workstation] Render the plain-KRM WET bundle from the DRY sources and review
  the diff.

```bash
cd "${GITOPS_DIR}"
"${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/render.sh"
git status --short
git diff --stat
```

The output is similar to the following:

```text
Rendered .../fleet-package/src/overlays/default to .../fleet-package/environments/default/manifests.yaml
Format .../fleet-package/environments/default/manifests.yaml with prettier before you commit it.
```

<!-- prettier-ignore -->
> [!NOTE]
> In a standalone repository (Option A), `render.sh` skips automatic `prettier`
> formatting because no monorepo `node_modules/.bin/prettier` is present, so the
> initial pull request includes harmless YAML indentation-only diff lines while
> producing identical rendered KRM resources.

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

- [Workstation] Apply the least-privilege `Role` and `RoleBinding`
  (`configdelivery-rootsync-manager`) in `config-management-system` for the
  Config Delivery service agent.

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
> informers) with a namespace `Role` in `<NAMESPACE>` for write verbs, applied
> to `spec.override.roleRefs` via Server-Side Apply under a distinct field
> manager (`kubectl apply --server-side --field-manager=platform-admin -f -`).
> Disjoint Server-Side Apply field ownership preserves `roleRefs` across
> in-place `FleetPackage` upgrades and rollbacks; re-apply only if the
> `RootSync` is deleted and recreated.

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

Day-2 operations are detailed in the [Solution User Guide (SUG)](user-guide.md):
interactive Gradio validation, application and DCGM GPU monitoring, promoting
model `v2` via release `v2.0.0`, and rolling back to model `v1` via forward
release `v2.0.1`. Every change follows the same GitOps lifecycle: edit DRY
manifests, run `render.sh`, merge a pull request, push a bare SemVer tag, and
update the `FleetPackage` `tag`. Because the serving pod claims the full
single-node GPU under `strategy: Recreate`, each pod replacement briefly pauses
serving.

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
> Resources retained by default (delete manually only if no other workload or
> `FleetPackage` shares them): the
> `gs://${BUCKET}/sft-model-serving/checkpoints/v1/` checkpoint prefix (`gcloud
> storage rm -r`), your remote GitOps repository (`gh repo delete
> "${GITOPS_OWNER}/${GITOPS_REPO}"`) and GitHub App installation in GitHub
> settings, the regional `fleet-packages` Artifact Registry OCI repository
> (`gcloud artifacts repositories delete fleet-packages --location="${REGION}"
> --project="${PROJECT_ID}"`), and cluster-wide Config Sync enablement.

## What's next

- [Solution Reference Architecture (SRA)](../README.md)
- [Solution User Guide (SUG)](user-guide.md): Gradio validation UI, application
  and GPU monitoring, upgrading to `v2.0.0`, and rolling back to `v2.0.1`
