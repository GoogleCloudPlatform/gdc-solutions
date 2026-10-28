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
It instantiates the Solution Reference Architecture with a **Llama 3.1 8B SFT**
checkpoint served by [vLLM](https://github.com/vllm-project/vllm)
(`vllm/vllm-openai:v0.32.0`, port `8000`) and a
[Gradio](https://github.com/gradio-app/gradio) validation UI (`ClusterIP` port
`8080`, container port `7860`) inside `Namespace/sft-model-serving`, executed
from a workstation through the Connect gateway.

The SRA and this SRI are model-agnostic. The checkpoint, chat template, and
served-model names in this guide belong to the Llama 3.1 8B SFT worked example,
whose Day-2 operations are in its model-specific Solution User Guide (SUG).

For the system architecture diagram, GPU sizing methodology, and design
trade-offs, see [Architecture and design](../README.md#architecture-and-design)
in the Solution Reference Architecture (SRA). For day-2 UI testing, telemetry,
upgrades (`v2.0.0`), and forward rollbacks (`v2.0.1`), see the
[Solution User Guide (SUG)](user-guide.md).

<!-- prettier-ignore -->
> [!IMPORTANT]
> Fine-tuning the model is out of scope for this solution and is a prerequisite
> for this implementation. To run full supervised fine-tuning of Llama 3.1 8B
> and store the resulting checkpoint in a Cloud Storage bucket, see [Supervised
> and distillation fine-tuning for open
> models](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tuning/open-model-tuning)
> and [Model checkpoint prerequisites](#model-checkpoint-prerequisites) in this
> guide.

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
- Create a private GitOps repository from the public sample in
  `GoogleCloudPlatform/gdc-solutions` and link it to
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

### Cluster setup prerequisites

- Distributed Cloud software only for bare metal 1.35 or later (validated on
  Distributed Cloud software only `1.35.0-gke.525` / Kubernetes
  `v1.35.2-gke.300`), standalone cluster registered to a fleet in your Google
  Cloud project; see
  [Distributed Cloud software only installation preparation](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/install-prep).
- One dedicated single-node NVIDIA GPU sized per
  [Hardware constraints](../README.md#hardware-constraints) in the SRA (for
  example, NVIDIA L4, L40S, RTX Ada series, or RTX PRO 6000 Blackwell; this
  guide was validated on RTX PRO 6000 Blackwell 96 GB).
- The
  [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
  the `nvidia` RuntimeClass, and
  [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) installed.
  Install the GPU Operator with Helm as described in
  [Install and verify the NVIDIA GPU Operator](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-manual-use),
  and confirm that the node reports `nvidia.com/gpu: 1` under `Allocatable`.
- An NVIDIA driver branch that matches the vLLM image: branch 580 or later for
  the default `vllm/vllm-openai:v0.32.0` image (CUDA 13.0.2, validated on driver
  `580.126.20`), or branch 575–579 with the `vllm/vllm-openai:v0.32.0-cu129`
  image (CUDA 12.9.1) set in `src/base/vllm-llama-sft-deployment.yaml`. Verify
  `v0.32.0-cu129` on 575–579 hosts before a production rollout.
- A driver installed either by the GPU Operator (pin the branch with the chart's
  `driver.version` option; see
  [Common chart customization options](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#gpu-operator-helm-chart-options))
  or preinstalled on the node (`--set driver.enabled=false`). Run `nvidia-smi`
  on the GPU node to check the installed driver version.
- A `local-shared` StorageClass and at least 256 GiB of local disk on the GPU
  node, for the `100Gi` ReadWriteOnce model cache PersistentVolumeClaim plus
  container images and kubelet headroom; see
  [node machine prerequisites](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/installing/node-machine-prerequisites).
- Application logging and
  [Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus)
  (`enableGMPForApplications`) enabled; see
  [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)
  and
  [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics).
- Outbound HTTPS (`443`) from cluster nodes to `*.googleapis.com`,
  [Cloud Storage](https://docs.cloud.google.com/storage/docs/introduction),
  `gcr.io`, `us-docker.pkg.dev`, and Docker Hub.

### Client workstation prerequisites

- [`gcloud` CLI](https://docs.cloud.google.com/sdk/docs/install), authenticated
  (`gcloud auth login`) to the fleet host project.
- `kubectl` with Kustomize v5 or later (`kubectl kustomize`).
- `git`, `curl`, and [`jq`](https://jqlang.org/). For a GitHub-hosted GitOps
  repository (the worked example), also the
  [GitHub CLI `gh`](https://cli.github.com/), authenticated as the owner of that
  repository.
- [Connect gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway)
  access to the target cluster, so that every `kubectl` command in this guide
  reaches that cluster from your workstation:
  - IAM roles `roles/gkehub.gatewayEditor` and `roles/gkehub.viewer` on the
    fleet host project for your Google account.
  - Kubernetes RBAC for your Google account on the cluster: either list the
    account in `clusterSecurity.authorization.clusterAdmin.gcpAccounts` of the
    [cluster configuration](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/reference/cluster-config-ref),
    or apply gateway RBAC with
    `gcloud container fleet memberships generate-gateway-rbac`; see
    [Set up the Connect gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway/setup).
  - You fetch the gateway credentials in
    [Set up environment and credentials](#set-up-environment-and-credentials),
    after you create the `.env` file.

### GitOps repository prerequisites

This guide stores the bundle in your own private Git repository, which you
create from the public sample in
[Initialize and connect the GitOps repository](#initialize-and-connect-the-gitops-repository).
Config Delivery reads it through a
[Cloud Build repository connection](https://docs.cloud.google.com/build/docs/repositories#2nd-gen-repos),
which supports GitHub and GitLab, among others. The commands in this guide use
GitHub (validated in our test environment); the GitLab differences are noted
where they apply. Before you start, make sure that you have:

- A user, organization, or group on your Git provider (`GITOPS_OWNER`) where you
  can create a private repository; for GitHub, the `gh` CLI signed in as that
  owner (`gh auth login`).
- A dedicated machine-user (bot) account on your Git provider with access to
  that repository; it authorizes the Cloud Build connection, so no personal
  developer credential is used. On GitHub, the bot authorizes the Cloud Build
  GitHub App; for GitLab, see the GitLab note in Connect the GitOps repository
  to Cloud Build.
- On GitHub, permission to install the Cloud Build GitHub App on `GITOPS_OWNER`
  (in an organization, this needs an organization owner or their approval).

<!-- prettier-ignore -->
> [!WARNING]
> Keep the GitOps repository private. After you customize the bundle, it
> contains your project ID, project number, Cloud Storage bucket, and service
> account names. These values aren't credentials, but you shouldn't publish
> them.

### Model checkpoint prerequisites

You need a merged
[Hugging Face Safetensors](https://github.com/huggingface/safetensors) SFT
checkpoint in Cloud Storage before you start. This guide doesn't cover
fine-tuning; the worked example used full supervised fine-tuning of Llama 3.1 8B
(`meta/llama3_1@llama-3.1-8b`) on the MetaMathQA dataset with Gemini Enterprise
Agent Platform managed open-model tuning (formerly Vertex AI). To produce an
equivalent checkpoint, follow that guide or the worked
[Llama 3 / open-model SFT Jupyter notebook](https://github.com/GoogleCloudPlatform/generative-ai/blob/main/open-models/fine-tuning/get_started_with_oss_tuning_on_vertexai.ipynb):

- Prepare a training dataset, and optionally a validation dataset, in a
  supported JSON Lines format (for example,
  `{"prompt": "...", "completion": "..."}` per line) and upload it to Cloud
  Storage.
- Create a full fine-tuning job, for example with the Agent Platform SDK for
  Python (or **Create tuned model** on the **Tuning** page of the Google Cloud
  console):

```python
sft_tuning_job = sft.train(
    source_model=SourceModel(
        base_model="meta/llama3_1@llama-3.1-8b",
    ),
    tuning_mode="FULL",  # FULL or PEFT_ADAPTER
    epochs=3,
    train_dataset="gs://DATASET_BUCKET/train.jsonl",
    validation_dataset="gs://DATASET_BUCKET/validation.jsonl",
    output_uri="gs://OUTPUT_DIR",
)
```

- When the job finishes, the final merged checkpoint is in
  `gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/`. Use this folder as
  `TUNING_OUTPUT_URI` in the `.env` file, and check that it holds `config.json`,
  `tokenizer.json`, `special_tokens_map.json`, and either
  `model.safetensors.index.json` with safetensors shards or a single
  `model.safetensors` file (`generation_config.json` and `tokenizer_config.json`
  are optional):

```bash
gcloud storage ls -l "gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/"
```

The output for the Llama 3.1 8B worked example is similar to the following:

```text
       838  2026-07-24T20:48:51Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/config.json
       121  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/generation_config.json
        78  2026-07-24T20:48:51Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/managed_oss_fine_tuning_marker.json
4976698672  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/model-00001-of-00004.safetensors
4999802720  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/model-00002-of-00004.safetensors
4915916176  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/model-00003-of-00004.safetensors
1168138808  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/model-00004-of-00004.safetensors
     23986  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/model.safetensors.index.json
       599  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/special_tokens_map.json
  17209920  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/tokenizer.json
     50600  2026-07-24T20:48:52Z  gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final/tokenizer_config.json
TOTAL: 11 objects, 16077842518 bytes (14.97GiB)
```

Replace the following:

<!-- mdformat off -->

| Placeholder      | Value to set                                                                |
| :--------------- | :-------------------------------------------------------------------------- |
| `OUTPUT_DIR`     | The Cloud Storage folder that you passed as `output_uri` to the tuning job. |
| `DATASET_BUCKET` | The Cloud Storage location of your JSON Lines datasets.                     |

<!-- mdformat on -->

Comply with the upstream model license for every deployment (for example, the
Llama 3.1 Community License when serving a Llama 3.1 derivative). The bundle
copies the checkpoint into one immutable Cloud Storage prefix per model version,
starting with `gs://BUCKET/sft-model-serving/checkpoints/v1/`.

### Identities and roles

- **Platform Administrator:** permissions to enable Google Cloud APIs
  (`roles/serviceusage.serviceUsageAdmin`), manage service accounts
  (`roles/iam.serviceAccountAdmin`) and IAM policy bindings
  (`roles/resourcemanager.projectIamAdmin`, `roles/storage.admin`), create Cloud
  Build repository connections (`roles/cloudbuild.connectionAdmin`) and
  `FleetPackage` resources (`roles/configdelivery.admin`), update fleet
  membership labels (`roles/gkehub.editor`), reach the cluster through the
  Connect gateway (`roles/gkehub.gatewayEditor`, `roles/gkehub.viewer`), and
  apply cluster onboarding RBAC.
- **Application Operator:** write access to the GitOps repository (pull requests
  and tags), Connect gateway access (`roles/gkehub.gatewayEditor`,
  `roles/gkehub.viewer`), and namespace RBAC in `sft-model-serving`
  (`get`/`list` pods and Services, read pod logs, and create `pods/portforward`
  and `pods/exec`).
- **Machine-user (bot) Git account:** dedicated account on your Git provider
  (GitHub or GitLab) that authorizes the 2nd-gen Cloud Build repository
  connection so personal developer tokens never enter
  [Google Cloud Secret Manager](https://docs.cloud.google.com/secret-manager/docs/overview)
  and zero Git secrets sit on clusters.

### Central reference configuration

- [Workstation] Create the local working directory and `.env` configuration
  file. Keep `REGION="us-central1"`: the Config Delivery API is available only
  in `us-central1`, and the Cloud Build repository connection must be in the
  same region as the `FleetPackage`; see
  [Deploy fleet packages](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/how-to/fleet-packages).

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
# GitOps repository and delivery
GITOPS_OWNER="GITOPS_OWNER"
GITOPS_REPO="sft-model-serving-gitops"
SOLUTION_SUBDIR="."
GITOPS_DIR="${HOME}/sft-model-serving-gitops"
CONNECTION="CONNECTION"
REPOSITORY="REPOSITORY"
FLEET_PACKAGE="sft-model-serving"
RELEASE_TAG="v1.0.0"
NAMESPACE="sft-model-serving"
DCGM_NAMESPACE="gpu-operator"
EOF
```

Replace the following values in the `.env` file:

<!-- mdformat off -->

| Variable                                    | Value to set                                                                                                                                                                                                 |
| :------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROJECT_ID`, `PROJECT_NUMBER`              | Google Cloud project ID and number hosting your fleet.                                                                                                                                                       |
| `REGION`                                    | Keep `us-central1`, the only Config Delivery location; the Cloud Build connection and the `FleetPackage` both use it.                                                                                        |
| `MEMBERSHIP`                                | Fleet membership ID of the target bare-metal cluster.                                                                                                                                                        |
| `PUBLISHER_SA_NAME`, `GSA_NAME`             | Names for the publisher service account and the checkpoint reader Google service account.                                                                                                                    |
| `BUCKET`, `TUNING_OUTPUT_URI`               | Checkpoint bucket name (without `gs://`) and the source `gs://` folder of the tuned checkpoint (without trailing slash), for example `gs://OUTPUT_DIR/postprocess/node-0/checkpoints/final`.                 |
| `GITOPS_OWNER`, `GITOPS_REPO`, `GITOPS_DIR` | Owner (GitHub user or organization, or GitLab group) and name of your private GitOps repository, and its local clone path. Keep `SOLUTION_SUBDIR="."`, which places `fleet-package/` at the repository root. |
| `CONNECTION`, `REPOSITORY`                  | Cloud Build connection and repository link names in `REGION`.                                                                                                                                                |
| `DCGM_NAMESPACE`                            | Namespace running `nvidia-dcgm-exporter`: `gpu-operator` for the Helm install described in Before you begin, or `nvidia-gpu-operator` if your installation uses that namespace.                              |

<!-- mdformat on -->

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

- [Workstation] Fetch cluster credentials through the Connect gateway, confirm
  that `kubectl` now targets the solution cluster, and verify node readiness.
  All later `kubectl` commands in this guide use this context.

```bash
gcloud container fleet memberships get-credentials "${MEMBERSHIP}" --project="${PROJECT_ID}"
kubectl config current-context
kubectl get nodes
```

The `kubectl config current-context` output is similar to the following:

```text
connectgateway_PROJECT_ID_global_MEMBERSHIP
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

Config Delivery reads the bundle from a Git repository that you own, because you
customize the manifests with your project values and cut your own release tags.
You create that repository as a private copy of the Apache 2.0 sample in
[`GoogleCloudPlatform/gdc-solutions`](https://github.com/GoogleCloudPlatform/gdc-solutions/tree/main/software-only/bare-metal/sft-model-serving),
so that it has its own commit history and release tags.

<!-- prettier-ignore -->
> [!NOTE]
> Set `SEED_REF` to `main` (default) or override it to a specific release tag or
> staging branch when testing pre-release changes before merging into `main`.

### Create your GitOps repository from the sample

- [Workstation] Create a private GitOps repository (GitHub in this example),
  copy the sample `fleet-package/` folder to its root (`SOLUTION_SUBDIR="."`),
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
git commit -m "chore: initialize SFT serving GitOps repository"
git push -u origin main
```

The resulting `${GITOPS_DIR}/fleet-package/fleetpackage.yaml` is similar to the
following (license header omitted). Only `cloudBuildRepository.path` changes;
you replace the `YOUR_*` placeholders in
[Customize and release the bundle](#customize-and-release-the-bundle):

```yaml
deletionPropagationPolicy: FOREGROUND
resourceBundleSelector:
  cloudBuildRepository:
    name: projects/YOUR_PROJECT_ID/locations/us-central1/connections/YOUR_CONNECTION/repositories/YOUR_REPOSITORY
    path: fleet-package/environments
    serviceAccount: projects/YOUR_PROJECT_ID/serviceAccounts/YOUR_PUBLISHER_SA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com
    tag: v1.0.0
rolloutStrategy:
  rolling:
    maxConcurrent: 1
target:
  fleet:
    project: projects/YOUR_PROJECT_ID
    selector:
      matchLabels:
        app-tier: sft-model-serving
variantSelector:
  variantNameTemplate: default
```

Config Delivery packages the `default` variant folder (`variantNameTemplate`)
under `path` from the Git tag in `tag`, and rolls it out one cluster at a time
(`maxConcurrent: 1`) to every fleet membership labeled
`app-tier=sft-model-serving`.

<!-- prettier-ignore -->
> [!NOTE]
> Config Delivery requires bare three-part SemVer tags (`v1.0.0`, `v2.0.0`,
> `v2.0.1`), and Git tags are repository-wide. Keep one solution per repository,
> or use disjoint SemVer major ranges if several solutions share a repository
> (see [Operational complexity](../README.md#operational-complexity) in the
> SRA).

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
> GitHub account rather than a personal developer account, or pass
> `--authorizer-token-secret-version=projects/${PROJECT_ID}/secrets/SECRET_NAME/versions/VERSION
> --app-installation-id=INSTALLATION_ID` directly to `gcloud builds connections
> create github`.

<!-- prettier-ignore -->
> [!NOTE]
> If your GitOps repository is on GitLab, make these changes; the
> `FleetPackage`, release tags, and cluster steps are the same:

- Create the private project in GitLab instead of running `gh repo create`,
  clone it from your GitLab host, and use merge requests where this guide uses
  `gh pr`.
- Store the bot account's `api` and `read_api` personal access tokens and a
  webhook secret in Secret Manager, then run
  `gcloud builds connections create gitlab` in `REGION` instead of the GitHub
  connection steps.
- Link the repository with `gcloud builds repositories create` and your GitLab
  `--remote-uri`; see
  [Connect to a GitLab host](https://docs.cloud.google.com/build/docs/automating-builds/gitlab/connect-host-gitlab)
  and
  [Connect to a GitLab repository](https://docs.cloud.google.com/build/docs/automating-builds/gitlab/connect-repo-gitlab).

## Customize and release the bundle

The bundle under `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/` contains the
following files. This guide shows the files that you edit or apply by hand; the
others are in the
[public sample](https://github.com/GoogleCloudPlatform/gdc-solutions/tree/main/software-only/bare-metal/sft-model-serving/fleet-package).

<!-- mdformat off -->

| File                                                                                  | Purpose                                                                                                                                                                                                                                       | Shown in                                                                                        |
| :------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------- |
| `fleetpackage.yaml`                                                                   | `FleetPackage` specification: Cloud Build repository, variant `path`, release `tag`, rollout strategy, and fleet label selector                                                                                                               | [Create your GitOps repository from the sample](#create-your-gitops-repository-from-the-sample) |
| `configdelivery-rbac.yaml`                                                            | Namespace-scoped `Role` and `RoleBinding` for the Config Delivery service agent; applied once per cluster                                                                                                                                     | [Prepare the target cluster](#prepare-the-target-cluster)                                       |
| `gcs-credential-config.yaml`                                                          | Per-cluster Fleet Workload Identity credential `ConfigMap`; applied once per cluster                                                                                                                                                          | [Prepare the target cluster](#prepare-the-target-cluster)                                       |
| `src/base/vllm-llama-sft-config.yaml`                                                 | `ConfigMap` with the chat template and `generation_config.json` for the checkpoint                                                                                                                                                            | This section                                                                                    |
| `src/base/vllm-llama-sft-deployment.yaml`                                             | vLLM `Deployment` with the `gcs-model-downloader` initContainer; both containers read the release from `ConfigMap/vllm-llama-sft-release`; pod seccomp profile `RuntimeDefault`                                                               | Public sample                                                                                   |
| `src/base/vllm-llama-sft-serviceaccount.yaml`                                         | Kubernetes `ServiceAccount` `vllm-llama-sft-sa` annotated with the workload Google service account                                                                                                                                            | Public sample                                                                                   |
| `src/base/vllm-llama-sft-service.yaml`                                                | `ClusterIP` `Service` on port `8000`                                                                                                                                                                                                          | Public sample                                                                                   |
| `src/base/vllm-llama-sft-podmonitoring.yaml`                                          | `PodMonitoring` that scrapes vLLM `/metrics` every 15 seconds                                                                                                                                                                                 | Public sample                                                                                   |
| `src/base/sft-model-cache-pvc.yaml`                                                   | `100Gi` `local-shared` ReadWriteOnce model cache `PersistentVolumeClaim`                                                                                                                                                                      | Public sample                                                                                   |
| `src/base/gradio-llama-sft-deployment.yaml`, `src/base/gradio-llama-sft-service.yaml` | Gradio validation UI `Deployment` and `ClusterIP` `Service` (port `8080` to container port `7860`)                                                                                                                                            | Public sample                                                                                   |
| `src/base/namespace.yaml`                                                             | `Namespace/sft-model-serving`                                                                                                                                                                                                                 | Public sample                                                                                   |
| `src/base/kustomization.yaml`, `src/overlays/default/kustomization.yaml`              | DRY Kustomize base (nine resources plus the generated `vllm-llama-sft-release` `ConfigMap` that defines `MODEL_VERSION`, `MODEL_GCS_URI`, and `RELEASE_TAG` once) and the `default` overlay (namespace and `app.kubernetes.io/part-of` label) | Public sample                                                                                   |
| `render.sh`                                                                           | Renders the overlay into `environments/default/manifests.yaml` with `kubectl kustomize`                                                                                                                                                       | Public sample                                                                                   |
| `environments/default/manifests.yaml`                                                 | WET plain-KRM bundle that Config Delivery packages; never edit by hand                                                                                                                                                                        | Generated                                                                                       |

<!-- mdformat on -->

`ConfigMap/vllm-llama-sft-config` mounts two files at `/etc/vllm/config` that
the Llama 3.1 8B SFT checkpoint needs, because its exported
`tokenizer_config.json` omits a chat template and its `generation_config.json`
lists only `128001` as `eos_token_id`:

- `llama3_sft_chat_template.jinja`: wraps each message in the Llama 3
  `<|start_header_id|>` / `<|end_header_id|>` / `<|eot_id|>` format that the
  checkpoint was tuned on.
- `generation_config.json`: adds `<|eot_id|>` (`128009`) as a stop token
  (`eos_token_id: [128001, 128009]`) and sets `temperature: 0.2` and
  `top_p: 1.0`.

The file is similar to the following (license header omitted):

```yaml
# Chat template and generation config for the Llama 3.1 8B SFT checkpoint.
# vLLM reads both files at startup: restart the vLLM pod after you change them.
apiVersion: v1
data:
  generation_config.json: |
    {"bos_token_id": 128000, "eos_token_id": [128001, 128009], "temperature": 0.2, "top_p": 1.0}
  llama3_sft_chat_template.jinja: |
    {{- bos_token }}
    {%- for message in messages %}
        {{- '<|start_header_id|>' + message['role'] + '<|end_header_id|>\n\n' + (message['content'] | trim) + '<|eot_id|>' }}
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|start_header_id|>assistant<|end_header_id|>\n\n' }}
    {%- endif %}
kind: ConfigMap
metadata:
  labels:
    app: vllm-llama-sft
  name: vllm-llama-sft-config
  namespace: sft-model-serving
```

<!-- prettier-ignore -->
> [!TIP]
> For another `<MODEL_NAME>` family, derive the template from the prompt format
> used during fine-tuning (usually the base model's `chat_template` in
> `tokenizer_config.json`), list every end-of-turn token ID in `eos_token_id`,
> and update model names and `--max-model-len`/`--dtype` in
> `src/base/vllm-llama-sft-deployment.yaml` and `MODEL_ID` in
> `src/base/gradio-llama-sft-deployment.yaml`.

- [Workstation] Create release branch `sft-model-serving-v1.0.0`, replace all
  project-wide `YOUR_*` placeholders across the DRY sources,
  `fleetpackage.yaml`, and `configdelivery-rbac.yaml`, and verify that zero
  placeholders remain.

```bash
cd "${GITOPS_DIR}" && git checkout -b sft-model-serving-v1.0.0
BUNDLE_ROOT="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package"
find "${BUNDLE_ROOT}/src" "${BUNDLE_ROOT}/fleetpackage.yaml" "${BUNDLE_ROOT}/configdelivery-rbac.yaml" -name '*.yaml' \
    -exec sed -i \
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
  sources and review the diff (your repository has no `prettier` setup, so
  `render.sh` skips formatting, leaving harmless indentation-only diffs on first
  run):

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
> If `config-management-system` already exists on the cluster, still run `gcloud
> beta container fleet config-management apply` so that the fleet records Config
> Sync as enabled for this membership.

- [Workstation] Apply the namespace-scoped `Role` and `RoleBinding`
  (`configdelivery-rootsync-manager`, granting `get`, `create`, `patch`, and
  `delete` on `rootsyncs.configsync.gke.io` instead of `cluster-admin`) in
  `config-management-system`:

```bash
kubectl apply -f "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/configdelivery-rbac.yaml"
```

The manifest is similar to the following (license header omitted);
`YOUR_PROJECT_NUMBER` was replaced in
[Customize and release the bundle](#customize-and-release-the-bundle):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configdelivery-rootsync-manager
  namespace: config-management-system
rules:
  - apiGroups:
      - configsync.gke.io
    resources:
      - rootsyncs
    verbs:
      - create
      - delete
      - get
      - patch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: configdelivery-rootsync-manager
  namespace: config-management-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: configdelivery-rootsync-manager
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: service-YOUR_PROJECT_NUMBER@gcp-sa-configdelivery.iam.gserviceaccount.com
```

<!-- prettier-ignore -->
> [!CAUTION]
> Never bind the Config Delivery service agent to `cluster-admin`. Without
> `RoleBinding/configdelivery-rootsync-manager` in `config-management-system`,
> rollouts stall with `403 Forbidden` on `rootsyncs.configsync.gke.io`.

<!-- prettier-ignore -->
> [!NOTE]
> Config Sync's `reconciler-manager` binds `root-reconciler-sft-model-serving`
> to `cluster-admin` by default. Config Delivery's `rollouts-manager` field
> manager owns only `spec.override.resources`, so operators who need strict
> least privilege can scope the reconciler:

- Create a minimal `ClusterRole` that grants `resourcegroups` inventory access,
  `namespaces` management restricted through `resourceNames` to `<NAMESPACE>`,
  and cluster-scoped read-only `get`, `list`, and `watch` on the 6 non-Secret
  packaged kinds that Config Sync status informers need: `serviceaccounts`,
  `persistentvolumeclaims`, `configmaps`, `services`, `deployments.apps`, and
  `podmonitorings.monitoring.googleapis.com`.
- Pair it with a namespace `Role` in `<NAMESPACE>` for write verbs, and apply
  both to `spec.override.roleRefs` with Server-Side Apply under a distinct field
  manager (`kubectl apply --server-side --field-manager=platform-admin -f -`).
- Disjoint Server-Side Apply field ownership preserves `roleRefs` across
  in-place `FleetPackage` upgrades and rollbacks; re-apply only if the
  `RootSync` is deleted and recreated.

- [Workstation] Create the target namespace and apply this cluster's keyless
  Fleet Workload Identity credential `ConfigMap` (`gcs-credential-config`),
  substituting `YOUR_PROJECT_ID`, `YOUR_GSA_NAME`, and `YOUR_MEMBERSHIP`.

```bash
kubectl apply -f "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/src/base/namespace.yaml"
sed -e "s/YOUR_PROJECT_ID/${PROJECT_ID}/g" \
    -e "s/YOUR_GSA_NAME/${GSA_NAME}/g" \
    -e "s/YOUR_MEMBERSHIP/${MEMBERSHIP}/g" \
    "${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/gcs-credential-config.yaml" \
    | kubectl apply -f -
```

The source file is similar to the following (license header omitted). The
`audience` binds the token exchange to this cluster's fleet membership, so you
apply it per cluster instead of packaging it in the shared bundle:

```yaml
apiVersion: v1
data:
  credential-configuration.json: |
    {
      "audience": "identitynamespace:YOUR_PROJECT_ID.svc.id.goog:https://gkehub.googleapis.com/projects/YOUR_PROJECT_ID/locations/global/memberships/YOUR_MEMBERSHIP",
      "credential_source": {
        "file": "/var/run/secrets/tokens/gcp-ksa/token"
      },
      "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/YOUR_GSA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com:generateAccessToken",
      "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
      "token_url": "https://sts.googleapis.com/v1/token",
      "type": "external_account"
    }
kind: ConfigMap
metadata:
  labels:
    app: vllm-llama-sft
  name: gcs-credential-config
  namespace: sft-model-serving
```

- [Workstation] Apply a `PodMonitoring` resource (`dcgm-gmp`) in
  `DCGM_NAMESPACE` so Google Cloud Managed Service for Prometheus scrapes GPU
  hardware utilization and framebuffer memory metrics from NVIDIA DCGM Exporter.

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

<!-- prettier-ignore -->
> [!NOTE]
> Instead of applying `dcgm-gmp` by hand, you can add it to the bundle so that
> Config Delivery rolls it out with the workload. This variant isn't validated
> in the reference lab:

- List it as a file in `src/base/kustomization.yaml`, not in the `FleetPackage`
  specification, which holds no resources.
- Do this only if every target cluster runs DCGM Exporter in the same namespace,
  because the bundle must stay identical across clusters.
- Don't do this if you scope the Config Sync reconciler with
  `spec.override.roleRefs`, which limits writes to `NAMESPACE`.

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
Cache check: no verified copy of gs://BUCKET/sft-model-serving/checkpoints/v1.
Active account: GSA_NAME@PROJECT_ID.iam.gserviceaccount.com
Downloading gs://BUCKET/sft-model-serving/checkpoints/v1 with fleet Workload Identity credentials...
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

| Symptom                                                                                                                                         | Cause                                                                                                            | Resolution                                                                                                                                                                                                                                                                                                  |
| :---------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| On GitHub, `gcloud builds repositories create` fails with `FAILED_PRECONDITION: repository ... is not accessible to the Cloud Build GitHub App` | The connection stores a different GitHub App installation ID than the one installed on your repository           | Run `gcloud builds connections update github "${CONNECTION}" --region="${REGION}" --project="${PROJECT_ID}" --app-installation-id=INSTALLATION_ID`                                                                                                                                                          |
| Rollout fails with `RESOURCE_BUNDLE_BUILD_FAILED` (`could not parse reference` or invalid version)                                              | The tag uses a slash prefix (`sft-model-serving/v1.0.0`) or prerelease suffix (`-rc1`)                           | Push a bare three-part SemVer tag (`v1.0.0`) and update `FleetPackage` `tag`                                                                                                                                                                                                                                |
| Rollout stalls with `403 Forbidden` on `rootsyncs`                                                                                              | Missing Config Delivery RBAC in `config-management-system`                                                       | Apply `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/configdelivery-rbac.yaml`                                                                                                                                                                                                                             |
| Config Sync error `KNV2010` about `kind: Kustomization`                                                                                         | A `kustomization.yaml` file is inside `fleet-package/environments/default/`                                      | Keep only plain rendered KRM in `environments/default/`; rerun `render.sh`                                                                                                                                                                                                                                  |
| `FleetPackage` targets zero clusters                                                                                                            | Target cluster membership lacks `app-tier=sft-model-serving`                                                     | Run `gcloud container fleet memberships update` to apply `app-tier=sft-model-serving`                                                                                                                                                                                                                       |
| vLLM pod stuck in `ContainerCreating` with `configmap "gcs-credential-config" not found`                                                        | Per-cluster onboarding `ConfigMap` wasn't applied (or cluster was previously un-labeled, deleting `<NAMESPACE>`) | Re-apply `src/base/namespace.yaml` and `gcs-credential-config.yaml` with `YOUR_PROJECT_ID`, `YOUR_GSA_NAME`, and `YOUR_MEMBERSHIP` substituted                                                                                                                                                              |
| `initContainer` fails with `Cache check: ... missing or empty` and `ERROR: the checkpoint at ... is incomplete`                                 | `MODEL_GCS_URI` prefix is empty or incomplete                                                                    | Upload all checkpoint files to the target Cloud Storage prefix                                                                                                                                                                                                                                              |
| `initContainer` fails with `MODEL_VERSION '...' is not a safe directory name`                                                                   | `MODEL_VERSION` is empty or contains characters other than letters, digits, `.`, `_`, and `-`                    | Fix the `MODEL_VERSION` literal in `src/base/kustomization.yaml` and re-render                                                                                                                                                                                                                              |
| `initContainer` shows node service account or `403` on `storage.objects.get`                                                                    | Fleet Workload Identity binding or audience mismatch                                                             | Check `roles/iam.workloadIdentityUser`, bucket IAM, and `MEMBERSHIP` in `gcs-credential-config.yaml`                                                                                                                                                                                                        |
| Pod `Pending` with `Insufficient nvidia.com/gpu`                                                                                                | GPU Operator not healthy or another pod holds the GPU                                                            | Inspect NVIDIA GPU Operator pods and free the GPU                                                                                                                                                                                                                                                           |
| vLLM fails at startup with CUDA driver error                                                                                                    | Driver branch `575–579` with default CUDA 13 image, or branch older than `575`                                   | Upgrade NVIDIA driver to `580+`, or select `vllm/vllm-openai:v0.32.0-cu129` on driver branch `575–579`                                                                                                                                                                                                      |
| Answers emit `<\|im_end\|>` or never stop                                                                                                       | Chat template or `generation_config.json` mismatch with SFT training format                                      | Verify `--chat-template` and `--generation-config` mount `/etc/vllm/config`                                                                                                                                                                                                                                 |
| Image pull slow or `429 Too Many Requests`                                                                                                      | Docker Hub anonymous pull rate limit                                                                             | Pull `vllm/vllm-openai` through an Artifact Registry Docker Hub remote repository (see [Create a Docker Hub remote repository](https://docs.cloud.google.com/artifact-registry/docs/repositories/create-dockerhub-remote-repository)) and point `image:` in `src/base/vllm-llama-sft-deployment.yaml` to it |
| `gcloud container fleet packages delete` fails with `FAILED_PRECONDITION`                                                                       | Child `Rollout` resources still exist                                                                            | Pass `--force` to `gcloud container fleet packages delete`                                                                                                                                                                                                                                                  |
| `PersistentVolumeClaim/sft-model-cache-pvc` stuck in `Terminating`                                                                              | Unmanaged pod still mounts `sft-model-cache-pvc`                                                                 | Delete any unmanaged pod mounting the PVC so `kubernetes.io/pvc-protection` clears                                                                                                                                                                                                                          |

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

<!-- mdformat off -->

| Placeholder   | Value to set                                                                                                                                                    |
| :------------ | :-------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SECRET_NAME` | Regional secret ID (`${CONNECTION}-github-oauthtoken-*`) listed by the previous command if deleting the Cloud Build connection did not remove it automatically. |

<!-- mdformat on -->

<!-- prettier-ignore -->
> [!NOTE]
> On GitLab, delete the `api` token, `read_api` token, and webhook secrets that
> you created in Secret Manager for the connection, and revoke the two personal
> access tokens in GitLab.

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

- [Solution Reference Architecture (SRA)](../README.md): architecture, sizing,
  and design decisions
- [Solution User Guide (SUG)](user-guide.md): Gradio validation, telemetry,
  `v2.0.0` upgrades, and `v2.0.1` rollbacks
