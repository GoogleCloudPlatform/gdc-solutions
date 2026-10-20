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

# SFT model deployment using Fleet Packages on Distributed Cloud software only reference architecture

## Overview

This Solution Reference Architecture (SRA) defines the conceptual design for
automating the deployment of supervised fine-tuned (SFT) open-weight models on
[Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
bare-metal clusters. The solution uses
[Google Cloud Config Delivery (Fleet Packages)](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages)
and
[Config Sync](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/overview)
to roll out a versioned Kubernetes resource bundle from Git to matching fleet
clusters.

The architecture introduces two primary personas: the **Platform Administrator**
(PA) who manages cluster infrastructure and Config Delivery rollouts, and the
**Application Operator** (AO) who manages the model weights, GitOps manifests,
and interactive validation.

Enterprises fine-tuning models in Google Cloud—using
[managed open-model tuning in Gemini Enterprise Agent Platform](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tuning/open-model-tuning)—often
need to serve those models at the edge. This architecture applies to open-weight
models supported by [vLLM](https://github.com/vllm-project/vllm) running on a
single-node GPU. The model weights remain in
[Cloud Storage](https://docs.cloud.google.com/storage/docs/introduction), while
Git tracks the manifests and selected model version.

<!-- prettier-ignore -->
> [!IMPORTANT]
> SRA versus SRI scope. This document covers the architectural design and
> structural decisions. For the deployment manifests and step-by-step deployment
> and implementation instructions, see the [Solution Reference Implementation
> (SRI)](docs/reference-implementation.md). For detailed user instructions on
> how to use and demonstrate the solution capabilities, see the [Solution User
> Guide (SUG)](docs/user-guide.md).

<!-- prettier-ignore -->
> [!WARNING]
> **Disclaimer:** This is not an officially supported Google product. This
> project and solution guide are provided for architectural evaluation,
> reference, and educational purposes only, on a best-effort basis, with no
> official support and no service level agreement (SLA), and are not eligible
> for the [Google Open Source Software Vulnerability Rewards
> Program](https://bughunters.google.com/open-source-security). This solution
> does not include model weights: you must obtain any model you deploy yourself
> and comply with its upstream license (for example, the [Llama 3.1 Community
> License](https://www.llama.com/llama3_1/license/) and [Llama 3.1 Acceptable
> Use Policy](https://www.llama.com/llama3_1/use-policy/) for Llama 3.1
> derivatives). Organizations planning a deployment must independently analyze,
> test, and validate all sizing, availability, security, and operational
> considerations against their specific production requirements.

### Features and capabilities

- **Fleet-wide GitOps delivery:** A `FleetPackage` reads an immutable release
  tag from the GitOps repository and rolls the bundle out to selected fleet
  memberships automatically.
- **Model version selection:** The AO selects the checkpoint in the vLLM
  `Deployment` and cuts a SemVer release tag pinning manifests and weights
  together.
- **Local model cache:** An initContainer caches the selected checkpoint on a
  node-local volume, accelerating pod restarts and providing resilience during
  network outages.
- **Local serving API:** vLLM provides OpenAI-compatible endpoints internally,
  allowing cluster workloads to target the active model stream or an explicit
  release alias.
- **Full observability:** PodMonitoring resources scrape application metrics and
  hardware GPU telemetry into Cloud Monitoring, while log forwarders send
  container logs to Cloud Logging.

### Architectural principles

- **Git is the single source of truth:** Every workload object originates from a
  reviewed pull request; Config Sync drift correction continuously enforces this
  state.
- **Releases are immutable:** A release is a Git tag pinned by the
  `FleetPackage` to ensure consistent execution across the fleet.
- **Weights never enter Git:** Manifests reference model checkpoints by Cloud
  Storage URI, keeping the Git repository and Config Delivery bundles
  lightweight.
- **Keyless identity:** Workloads authenticate via Fleet Workload Identity using
  projected tokens, avoiding static credentials or Kubernetes secrets on the
  cluster.
- **Least privilege end to end:** Workload identity is scoped to read-only
  bucket access, and Config Delivery utilizes namespace-scoped permissions for
  rollout orchestration.

## Architecture and design

### Components

The architecture deploys workload resources into a configurable Kubernetes
namespace (`<NAMESPACE>`, defaulting to `sft-model-serving`) across five layers:

- **Edge cluster infrastructure (customer managed):**
  - **Distributed Cloud software only standalone cluster:** Bare-metal
    Kubernetes cluster registered to a fleet, running Config Sync.
  - **Single-node edge inference GPU:** Dedicated hardware accelerator
    (`nvidia.com/gpu: 1`) for the serving pod.
  - **[NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html)
    and [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter):**
    Manages GPU drivers, exposes the `nvidia` `RuntimeClass`, and exports
    hardware GPU metrics.
- **GitOps delivery pipeline (Google Cloud, `<REGION>`):**
  - **GitOps repository:** Customer repository storing DRY
    [Kustomize](https://github.com/kubernetes-sigs/kustomize) sources
    (`fleet-package/src/`) and rendered plain-KRM WET manifests
    (`fleet-package/environments/default/`).
  - **Cloud Build connection (2nd gen) and Secret Manager:** Read-only link to
    the GitOps repository authenticated with a dedicated machine-user token in
    Google Cloud Secret Manager via the Cloud Build GitHub App installation
    scoped to that repository.
  - **Publisher service account and
    [Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs/overview):**
    Packages the rendered variant directory into an immutable OCI bundle in the
    managed `fleet-packages` repository.
  - **`FleetPackage` and Config Sync reconciler:** `FleetPackage` rolls tagged
    releases out across matching labeled memberships (`maxConcurrent: 1`) using
    namespace-scoped `Role/configdelivery-rootsync-manager`, while Config Sync
    reconciles the 9-resource bundle and remediates drift.
- **vLLM model serving engine:**
  - **vLLM `Deployment` and `ClusterIP` `Service`:** Single-replica `Deployment`
    (`strategy: Recreate`, `runtimeClassName: nvidia`) serving OpenAI-compatible
    HTTP endpoints behind internal port `8000`, mounting its chat template and
    `generation_config.json` from `ConfigMap/vllm-llama-sft-config`.
  - **Model downloader `initContainer` and cache storage:** Authenticates via
    Fleet Workload Identity (`ServiceAccount` plus per-cluster onboarding
    `ConfigMap` `gcs-credential-config`) to sync checkpoints into a `100Gi`
    `local-shared` `PersistentVolumeClaim` (`/model-cache`), paired with a
    `16Gi` memory-backed `/dev/shm`.
- **Interactive validation UI:**
  - **Gradio `Deployment` and `ClusterIP` `Service`:** Web application on
    internal port `8080` (container port `7860`) forwarding chat validation
    requests to vLLM using the release model alias.
- **Google Cloud integration:**
  - **Cloud Storage:** Stores immutable SFT checkpoints under versioned prefixes
    (`.../checkpoints/v1/`, `.../checkpoints/v2/`).
  - **Cloud Monitoring and Cloud Logging:** `PodMonitoring` scrapes vLLM and GPU
    metrics into Managed Service for Prometheus, while cluster log forwarders
    ship container logs to Cloud Logging.

### High-level architecture overview

The following diagram shows the delivery and runtime paths:

![High-level architecture of SFT model serving with Fleet Packages on Distributed Cloud software only](docs/images/sft-model-serving-architecture.png)

1. **Pull request and release tag:** The AO commits rendered manifests and
   pushes an immutable SemVer release tag to the GitOps repository.
2. **Set target release tag:** The PA updates the `FleetPackage` tag to match
   the new release version.
3. **Package and publish bundle:** A managed Cloud Build job packages the
   variant into an immutable OCI bundle stored in Artifact Registry.
4. **Fleet rollout and reconciliation:** Config Delivery updates the target
   `RootSync`, and Config Sync reconciles the bundle into the cluster namespace.
5. **Keyless token exchange:** The initContainer exchanges its projected token
   via Fleet Workload Identity for read-only access to the Cloud Storage bucket.
6. **Checkpoint download and caching:** The initContainer downloads the
   checkpoint into the local persistent volume cache, verifying integrity and
   pruning older versions.
7. **GPU model loading and serving:** The vLLM Pod loads cached weights onto the
   GPU and serves internal OpenAI-compatible HTTP endpoints.
8. **Metrics scraping and log forwarding:** PodMonitoring scrapes vLLM and GPU
   metrics into Cloud Monitoring, while the **Log Forwarder** DaemonSet streams
   logs to Cloud Logging.
9. **Interactive release validation:** The AO uses port forwarding to access the
   Gradio Service and interactively tests the active model release.

### Hardware constraints

Operators must size model parameters, precision, context window
(`--max-model-len`), and concurrency (`--max-num-seqs`) to fit the dedicated GPU
VRAM.

<!-- mdformat off -->

| GPU Profile | Example Hardware       | Sizing and KV Cache Headroom                                                                                                                                                |
| :---------- | :--------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **96 GB**   | RTX PRO 6000 Blackwell | 8B BF16 weights leave `~69 GiB` for KV cache, supporting max concurrency at `--max-model-len=16384`, `--gpu-memory-utilization=0.90`, and `--max-num-seqs=256` (32 layers). |
| **48 GB**   | L40S, RTX 6000 Ada     | 8B BF16 weights leave `~20 GiB` to `~25 GiB` for KV cache; tune limits to prevent preemption under peak load.                                                               |
| **24 GB**   | L4, RTX 4000 Ada       | 8B BF16 weights leave minimal headroom; requires smaller models (2B-4B) or quantization.                                                                                    |

<!-- mdformat on -->

## Supportability matrix (responsibilities)

<!-- mdformat off -->

| Component                       | Executed / Managed by | Notes                                                                                                                                                                                                                                                                                                                                           |
| :------------------------------ | :-------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Physical hardware and OS        | Customer              | Customer-sourced server with local disk and one dedicated single-node inference GPU.                                                                                                                                                                                                                                                            |
| Distributed Cloud software only | Customer              | Installed and registered to a fleet on version 1.35 or later.                                                                                                                                                                                                                                                                                   |
| NVIDIA GPU Operator             | Customer              | Installed and maintained by the customer; Google does not support the deployment.                                                                                                                                                                                                                                                               |
| Config Sync                     | Joint                 | Google supports the managed feature; customer enables it before the first rollout.                                                                                                                                                                                                                                                              |
| Config Delivery                 | Joint                 | Google operates the managed service; customer configures the connection, package, and RBAC.                                                                                                                                                                                                                                                     |
| GitOps repository               | Customer              | Customer creates the repository and manages pull requests and release tags.                                                                                                                                                                                                                                                                     |
| Reference manifests             | Google                | Published under Apache 2.0 without official product support or SLA.                                                                                                                                                                                                                                                                             |
| Fine-tuned checkpoint           | Joint                 | Google operates Gemini Enterprise Agent Platform open-model tuning; customer runs jobs (see the [Llama 3 / open-model SFT Jupyter notebook](https://github.com/GoogleCloudPlatform/generative-ai/blob/main/open-models/fine-tuning/get_started_with_oss_tuning_on_vertexai.ipynb)), complies with model licensing, and manages bucket prefixes. |
| vLLM and Gradio images          | Customer              | Customer pins, scans, and mirrors upstream open source images.                                                                                                                                                                                                                                                                                  |
| Cloud Logging and Monitoring    | Joint                 | Google operates the backend; customer enables cluster application logging and metric collection.                                                                                                                                                                                                                                                |

<!-- mdformat on -->

## Concepts and technologies

### Infrastructure and platform

- **Fleet membership selection:** Bare-metal clusters register to a fleet and
  receive one-time onboarding (`Role/configdelivery-rootsync-manager` and
  cluster-specific `ConfigMap` `gcs-credential-config`). Membership labels
  dynamically select rollout targets while keeping packaged workload manifests
  100% identical across clusters.
- **Dedicated single-GPU node profile:** The serving pod claims one whole GPU
  without MIG or time-slicing for deterministic latency, backed by a `100Gi`
  `local-shared` `PersistentVolumeClaim` for offline restart resilience and a
  `16Gi` memory-backed `/dev/shm` segment for PyTorch/vLLM IPC.

### Services and logic

- **Keyless model sync and pruning (`initContainer`):** Uses
  [Fleet Workload Identity](https://docs.cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity)
  (`PROJECT_ID.svc.id.goog`) to authenticate without static keys and requires no
  host-level service account credentials, verifies required
  [Hugging Face Safetensors](https://github.com/huggingface/safetensors) and
  tokenizer files before writing `.complete`, and prunes superseded model
  directories under `/model-cache/<MODEL_NAME>/`.
- **vLLM runtime and prompt control:** Serves cached BF16 checkpoints with
  PagedAttention, prefix caching (`--enable-prefix-caching`), chunked prefill
  (`--enable-chunked-prefill`), three `--served-model-name` aliases (stream,
  SemVer release, and model version), Git-mounted
  [Jinja](https://jinja.palletsprojects.com/) chat templates and
  `generation_config.json` stop tokens, and `--trust-remote-code` omitted.
- **Gradio validation UI:** Displays
  `You are chatting with: <MODEL_NAME>-vX.Y.Z` and sends that release alias to
  `/v1/chat/completions` over `kubectl port-forward`.

### Cloud observability integration

- **Metrics and logs:** A workload `PodMonitoring` scrapes vLLM `/metrics`
  (`vllm:kv_cache_usage_perc`, token counters, and TTFT histograms) every 15
  seconds and a cluster `PodMonitoring` (`dcgm-gmp`) scrapes NVIDIA DCGM
  Exporter (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`) into
  [Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus)
  (`enableGMPForApplications`), while log forwarders ship CRI container
  stdout/stderr (`jsonPayload.log`) to
  [Cloud Logging](https://docs.cloud.google.com/logging/docs/overview). See
  [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)
  and
  [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics).

### Cloud Build and Config Delivery integration

- **Immutable OCI packaging and reconciliation:** A regional 2nd-gen Cloud Build
  repository connection links the GitOps repository without cluster Git secrets;
  setting a new bare SemVer `tag` triggers a managed Cloud Build job as the
  publisher service account to push a plain-KRM OCI bundle to Artifact Registry
  (`fleet-packages`) and roll out `RootSync` updates (`maxConcurrent: 1`)
  reconciled by Config Sync.

## Considerations

### Scalability and performance

- **One GPU per cluster:** Serving capacity scales horizontally across the fleet
  by onboarding additional clusters rather than scaling replicas on a single
  node.
- **Progressive blast-radius control:** Rollouts target one cluster at a time,
  halting propagation if Config Sync reconciliation fails.
- **Cold-start latency:** Promoting a new model version requires downloading
  weights over the network, whereas configuration-only releases boot instantly
  from the local cache.

### Resource management

- **Container sizing:** Workload requests must equal limits to guarantee quality
  of service (`4` CPU, `32Gi` memory, `1` GPU in the 8B reference profile), on
  nodes with at least `16` vCPU, `64 GiB` RAM, and `250 GiB` fast local NVMe/SSD
  storage (size CPU, memory, and NVMe capacity to your model and hardware SKU).
- **96 GB GPU headroom (validation profile):** At
  `--gpu-memory-utilization=0.90` (`86,963 / 97,887 MiB` total GPU memory used),
  subtracting `14.96 GiB` of weights (`128 KiB/token`, `2.0 GiB` per full
  `16,384`-token sequence) and runtime overhead leaves `68.63 GiB` for the KV
  cache (`562,224` tokens—`34.32x` max concurrency at full `16,384`-token
  sequences on `vllm/vllm-openai:v0.32.0`).
- **Cache pruning and eviction protection:** Sizing the `100Gi` PVC to hold the
  active checkpoint plus one incoming download prevents unbounded disk growth
  and avoids `node.kubernetes.io/disk-pressure` evictions.

### Availability and reliability

- **Rollout downtime and rollback timings:** `strategy: Recreate` stops the
  running pod before starting the replacement; rolling back via an immutable
  forward tag (such as `v2.0.1`) re-downloads pruned weights (`~2` minutes
  managed Cloud Build packaging with zero downtime, `21` seconds at
  `922–952 MiB/s` for `14.97 GiB` Fleet Workload Identity download and cache
  pruning, `3` minutes `11–13` seconds `Recreate` pause, and `5` minutes `47–49`
  seconds to HTTP `200` / `7` minutes `39` seconds to `Rollout COMPLETED` on
  `vllm/vllm-openai:v0.32.0`).
- **Offline resilience and drift remediation:** Verified `.complete` checkpoints
  reload locally across offline node reboots, Config Sync reverts manual cluster
  drift, and removing the target fleet label prunes `<NAMESPACE>` (requiring
  re-applying `namespace.yaml` and `gcs-credential-config` before re-labeling).

### Operational complexity

- **DRY-to-WET workflow:** Authors edit Kustomize sources and commit both DRY
  and rendered WET YAML in the same pull request before tagging (optionally add
  a pull-request CI check verifying `render.sh` leaves zero diff).
- **SemVer tag discipline:** Customers hosting multiple solutions in one
  repository must isolate releases using `cloudBuildRepository.path` subfolders
  and disjoint three-part SemVer major ranges.
- **CLI-driven operations:** Operators manage edge rollouts and diagnose
  inference health using `gcloud`, `kubectl`, Cloud Monitoring, and Cloud
  Logging.

### Security and compliance

- **Least-privilege cluster RBAC:** The Config Delivery service agent holds only
  `create`, `delete`, `get`, and `patch` on `rootsyncs.configsync.gke.io` in
  `config-management-system` (`Role/configdelivery-rootsync-manager`), and
  operators requiring strict multi-tenant isolation can scope the Config Sync
  reconciler via Server-Side Apply on `RootSync.spec.override.roleRefs`
  (`--field-manager=platform-admin`, pairing a `ClusterRole` granting read-only
  `get`, `list`, and `watch` on the 6 non-Secret packaged kinds with a namespace
  write `Role` in `<NAMESPACE>`, preserving `secrets` denial across rollouts).
- **Zero static secrets:** Fleet Workload Identity exchanges tokens dynamically,
  ensuring no Git credentials or Kubernetes secrets persist on edge clusters.
- **Request logging privacy:** Enabling `--enable-log-requests` on
  `vllm/vllm-openai:v0.32.0` writes HTTP access metadata to container stdout and
  Cloud Logging at default `INFO` level and raw prompt/completion payloads if
  `VLLM_LOGGING_LEVEL=DEBUG` is set; omit or restrict request logging when
  serving regulated or personal data.
- **Internal exposure:** Serving (`:8000`) and validation (`:8080`) endpoints
  use internal `ClusterIP` services accessed via `kubectl port-forward`;
  production external exposure requires an authenticating API gateway and TLS
  termination.
- **Pinned provenance:** Runtime images are pinned to explicit version tags
  (`vllm-openai:v0.32.0` on driver `580+` or `v0.32.0-cu129` on `575–579`;
  `cloud-sdk:589.0.0-slim`; `gradio-app:v1.0.4`) and should be scanned and
  mirrored into Artifact Registry.

## Design decision

### Delivery mechanism: Config Delivery Fleet Packages versus standalone Config Sync RootSync versus manual kubectl apply

- **Selected option:** **Config Delivery Fleet Packages with Config Sync**
- **Rationale:** Provides a regional control plane that selects target clusters
  by fleet label and orchestrates progressive rollouts (`maxConcurrent: 1`)
  across the edge fleet without storing Git credentials on clusters.
- **Alternatives rejected:** Standalone Config Sync lacks progressive rollout
  waves and centralized fleet history and requires per-cluster Git credentials
  across multi-cluster fleets. Manual application provides no drift remediation
  or audit trail.

### Release and manifest rendering: WET bundle committed with SemVer tags versus CI hydration

- **Selected option:** **Commit locally rendered manifests in the pull request
  and use bare SemVer tags**
- **Rationale:** Config Delivery packages plain KRM manifests verbatim without
  Kustomize (avoiding `KNV2010`). Committing rendered manifests lets reviewers
  inspect exact diffs, and bare three-part SemVer tags (`vX.Y.Z`) atomically
  bind configuration and `MODEL_VERSION`.
- **Alternatives rejected:** CI hydration bots require write credentials and
  race with tags. Slash-prefixed or prerelease tags are rejected by Config
  Delivery, direct CI bundle uploads bypass native repository integration, and
  mutable branches break immutability.

### Model weight distribution: Cloud Storage with a version-scoped PVC cache versus weights in Git

- **Selected option:** **Immutable checkpoints in Cloud Storage synchronized to
  a node-local PVC**
- **Rationale:** Keeps multi-gigabyte safetensors shards out of Git and OCI
  bundles. The `.complete` marker ensures offline restart resilience, and
  post-sync pruning bounds disk consumption.
- **Alternatives rejected:** Committing weights to Git or bundles exceeds size
  limits, baking weights into images couples weight updates to container
  rebuilds, and runtime hub downloads add external dependencies.

### Identity and access: Fleet Workload Identity and least-privilege RBAC versus service account key

- **Selected option:** **Fleet Workload Identity (`gcs-credential-config`
  applied per cluster) and namespace-scoped Config Delivery RBAC**
- **Rationale:** Isolating the per-cluster `gcs-credential-config` `ConfigMap`
  at onboarding keeps the packaged bundle identical across all fleet clusters
  while exchanging projected tokens without static keys, and
  `Role/configdelivery-rootsync-manager` eliminates `cluster-admin` blast
  radius.
- **Alternatives rejected:** Embedding `gcs-credential-config` in the shared
  bundle hard-codes one cluster membership ID, exported JSON keys require manual
  rotation, node credentials violate least privilege, and unscoped
  `cluster-admin` over-privileges service agents.

### Model serving runtime: vLLM versus Triton Inference Server versus Ollama

- **Selected option:** **Upstream [vLLM](https://github.com/vllm-project/vllm)
  OpenAI-compatible server**
- **Rationale:** Loads Safetensors BF16/FP8 checkpoints directly, maximizes
  single-GPU throughput via PagedAttention and prefix caching, accepts explicit
  Jinja chat templates and `generation_config.json` stop tokens, and exports
  native Prometheus metrics.
- **Alternatives rejected:**
  [NVIDIA Triton Inference Server](https://github.com/triton-inference-server/server)
  adds unnecessary repository scaffolding for single-model edge serving, while
  [Ollama](https://github.com/ollama/ollama) centers on GGUF conversion and
  lacks native OpenMetrics serving telemetry.

### Telemetry collection: Google Cloud Managed Service for Prometheus versus a local Prometheus stack

- **Selected option:**
  **[Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus)**
- **Rationale:** Scrapes vLLM and DCGM Exporter `PodMonitoring` targets into
  Cloud Monitoring for unified fleet dashboards without running full Prometheus
  storage servers on single-node edge hosts.
- **Alternatives rejected:** Self-managed local Prometheus and Grafana stacks
  consume edge node resources and fragment fleet observability.

## Assumptions and limitations

### Assumptions

<!-- mdformat off -->

| Identity / Component       | Role / Assumption                                                                            |
| :------------------------- | :------------------------------------------------------------------------------------------- |
| **Target cluster**         | Distributed Cloud software only 1.35+ standalone cluster with one dedicated single-node GPU. |
| **GPU tooling**            | NVIDIA GPU Operator and DCGM Exporter installed with a compatible driver branch.             |
| **GitOps repository**      | Customer-managed repository connected via 2nd-gen Cloud Build with a machine-user account.   |
| **Network path**           | Clusters reach Google Cloud APIs and container registries over outbound HTTPS.               |
| **Publisher SA**           | Holds Config Delivery publisher, Artifact Registry writer, and log writer roles.             |
| **Workload SA**            | Holds Workload Identity user and object viewer roles for the checkpoint bucket.              |
| **Platform Administrator** | Manages fleet memberships, Config Delivery, IAM bindings, and cluster RBAC.                  |
| **Application Operator**   | Manages GitOps pull requests and holds namespace RBAC for port forwarding.                   |

<!-- mdformat on -->

### Limitations

- **Single-GPU boundary:** Multi-GPU tensor or pipeline parallelism is out of
  scope for this architecture.
- **Brief serving pauses:** The recreate strategy interrupts inference during
  upgrades or rollbacks.
- **Rollback downloads:** Pruned caches mean rolling back requires
  re-downloading prior weights.
- **Volume affinity:** The local persistent volume binds the serving pod to a
  specific node.
- **Validation-only UI:** Gradio provides no authentication and is strictly for
  interactive operator validation.

## What's next

- [Solution Reference Implementation (SRI)](docs/reference-implementation.md)
- [Solution User Guide (SUG)](docs/user-guide.md)
- [Fleet packages overview](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages)
- [Open model serving on Distributed Cloud software only reference architecture](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/solutions/open-model-serving-sw-only)
