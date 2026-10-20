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

The architecture consists of five functional layers spanning Google Cloud and
the edge cluster.

- **Edge cluster infrastructure:**
  - **Distributed Cloud software only cluster:** Bare-metal Kubernetes cluster
    registered to a fleet, running Config Sync.
  - **Single-node edge inference GPU:** Dedicated hardware accelerator for the
    serving pod.
  - **NVIDIA GPU Operator and DCGM Exporter:** Manages GPU drivers and exports
    hardware metrics.
- **GitOps delivery pipeline:**
  - **GitOps repository:** Customer repository storing declarative Kustomize
    sources and rendered manifests.
  - **Cloud Build connection:** Read-only link to the GitOps repository
    authenticated via Secret Manager.
  - **FleetPackage:** Config Delivery resource orchestrating the release
    rollout.
  - **Config Sync reconciler:** In-cluster component that applies the bundle and
    remediates drift.
- **vLLM model serving engine:**
  - **vLLM Deployment:** Runs the OpenAI-compatible HTTP server on the edge GPU.
  - **Model downloader initContainer:** Synchronizes weights from Cloud Storage
    to local disk.
  - **Model cache storage:** Node-local persistent volume and shared memory
    segment for vLLM.
- **Interactive validation UI:**
  - **Gradio Deployment:** Lightweight web application for chat completion
    validation.
- **Google Cloud integration:**
  - **Cloud Storage:** Stores immutable fine-tuned model checkpoints.
  - **Cloud Monitoring and Logging:** Centralized observability for metrics and
    container logs.

### Design decision

- **Fleet Workload Identity:** The initContainer exchanges projected service
  account tokens for short-lived Google Cloud credentials to download
  checkpoints securely without static keys.
- **Local caching and pruning:** Checkpoints are stored in a version-scoped
  persistent volume; the downloader skips fetching verified files and prunes
  obsolete versions to constrain disk usage.
- **Serving optimization:** vLLM maximizes GPU throughput using PagedAttention,
  prefix caching, and customized Jinja chat templates loaded from a Git-managed
  configuration map.
- **Immutable artifact packaging:** Config Delivery uses a managed Cloud Build
  job to package rendered manifests into an OCI bundle stored in Artifact
  Registry.
- **Least privilege deployment:** Config Delivery operates with a
  namespace-scoped Role in `config-management-system`, delegating final
  application to Config Sync.

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

| Component                       | Executed / Managed by | Notes                                                                                            |
| :------------------------------ | :-------------------- | :----------------------------------------------------------------------------------------------- |
| Physical hardware and OS        | Customer              | Customer-sourced server with local disk and one dedicated single-node inference GPU.             |
| Distributed Cloud software only | Customer              | Installed and registered to a fleet on version 1.35 or later.                                    |
| NVIDIA GPU Operator             | Customer              | Installed and maintained by the customer; Google does not support the deployment.                |
| Config Sync                     | Joint                 | Google supports the managed feature; customer enables it before the first rollout.               |
| Config Delivery                 | Joint                 | Google operates the managed service; customer configures the connection, package, and RBAC.      |
| GitOps repository               | Customer              | Customer creates the repository and manages pull requests and release tags.                      |
| Reference manifests             | Google                | Published under Apache 2.0 without official product support or SLA.                              |
| Fine-tuned checkpoint           | Joint                 | Google operates Gemini tuning; customer executes jobs and manages bucket prefixes.               |
| vLLM and Gradio images          | Customer              | Customer pins, scans, and mirrors upstream open source images.                                   |
| Cloud Logging and Monitoring    | Joint                 | Google operates the backend; customer enables cluster application logging and metric collection. |

<!-- mdformat on -->

## Design decision

### Delivery mechanism: Config Delivery Fleet Packages versus standalone Config Sync RootSync versus standalone RootSync

- **Selected option:** **Config Delivery Fleet Packages with Config Sync**
- **Rationale:** Provides a regional control plane that selects target clusters
  by fleet label and orchestrates progressive rollouts across the edge fleet
  without storing Git credentials on clusters.
- **Alternatives rejected:** Standalone Config Sync lacks progressive rollout
  waves and centralized fleet history. Manual application provides no drift
  remediation or audit trail.

### Release and manifest rendering: WET bundle committed with SemVer tags versus CI hydration

- **Selected option:** **Commit locally rendered manifests in the pull request
  and use bare SemVer tags**
- **Rationale:** Config Delivery packages plain KRM manifests. Committing the
  rendered WET bundle ensures reviewers see exact diffs. Pinning the tag via
  `MODEL_VERSION` atomically binds infrastructure and weights. Config Delivery
  enforces bare SemVer tags for resource bundle and release validation.
- **Alternatives rejected:** CI hydration bots require write credentials. Custom
  CI uploads bypass the native Cloud Build integration. Mutable release branches
  break immutability.

### Model weight distribution: Cloud Storage with a version-scoped PVC cache versus weights in Git

- **Selected option:** **Immutable checkpoints in Cloud Storage synchronized to
  a node-local PVC**
- **Rationale:** Keeps multi-gigabyte safetensors shards out of Git and OCI
  bundles. The `.complete` marker ensures offline restart resilience, and
  post-sync pruning bounds disk consumption.
- **Alternatives rejected:** Committing weights to Git exceeds repository
  limits. Baking weights into images couples model updates to container
  lifecycles.

### Identity and access: Fleet Workload Identity and least-privilege RBAC versus service account key

- **Selected option:** **Fleet Workload Identity and namespace-scoped Config
  Delivery RBAC**
- **Rationale:** Projected tokens exchange for short-lived read access to Cloud
  Storage, eliminating static cluster secrets. The Config Delivery service agent
  requires only namespace-scoped permissions in `config-management-system`,
  minimizing blast radius.
- **Alternatives rejected:** Exported JSON keys require manual rotation.
  Unscoped cluster-admin roles violate least privilege.

### Model serving runtime: vLLM versus Triton Inference Server versus Triton Inference Server versus Ollama

- **Selected option:** **Upstream vLLM OpenAI-compatible server**
- **Rationale:** Delivers high single-GPU throughput via PagedAttention, loads
  Safetensors directly, accepts explicit Jinja templates, and exposes native
  Prometheus endpoints.
- **Alternatives rejected:** Triton Inference Server introduces unnecessary
  scaffolding complexity for single-model edge serving. Ollama focuses on GGUF
  conversion rather than native cloud pipeline outputs.

### Telemetry collection: Google Cloud Managed Service for Prometheus versus a local Prometheus stack

- **Selected option:** **Google Cloud Managed Service for Prometheus**
- **Rationale:** Scrapes application and GPU metrics into Cloud Monitoring,
  providing unified fleet-wide dashboards without running full storage servers
  on edge hosts.
- **Alternatives rejected:** A self-managed local Prometheus stack consumes edge
  resources and fragments fleet observability.

## Concepts and technologies

This section describes the concepts and technologies used in the solution.

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
  of service. For a Llama 3.1 8B SFT model on a 96 GB GPU, the default `0.9`
  cache ratio yields a `68.63 GiB` KV cache (supporting `562,224` tokens or
  `34.32x` capacity). Monitor `vllm:kv_cache_usage_perc` via the
  `nvidia-gpu-operator` DCGM exporter to tune capacity.
- **Node sizing:** Bare-metal nodes require sufficient CPU, memory, and fast
  local NVMe storage to accommodate the cache PVC and kubelet eviction
  thresholds.
- **Cache pruning:** Sizing the PVC to hold the active checkpoint plus one
  incoming download prevents unbounded disk growth across atomic version
  transitions.

### Availability and reliability

- **Rollout downtime:** The recreate deployment strategy terminates the running
  pod before starting the replacement, causing a brief inference pause during
  rollouts.
- **Offline resilience:** After the active model downloads and verifies
  successfully, node reboots reload weights directly from local storage.
- **Rollback behavior:** Because older versions are pruned, rolling back to a
  previous release triggers a fresh download of the prior checkpoint from Cloud
  Storage.

### Operational complexity

- **DRY-to-WET workflow:** Authors edit Kustomize sources and commit both DRY
  and rendered WET YAML in the same pull request before tagging.
- **SemVer tag discipline:** Customers hosting multiple solutions in one
  repository must isolate releases using subfolders and disjoint major version
  ranges.
- **CLI-driven operations:** Operators manage edge rollouts and diagnose
  inference health using the CLI, Cloud Monitoring, and Cloud Logging.
- **Structured logging:** Kubernetes on Distributed Cloud software only parses
  `stdout` into `jsonPayload.log` rather than `textPayload`. Operators use
  Logging Query Language (LQL) with `jsonPayload.log` filters to extract traces.

### Security and compliance

- **Zero static secrets:** Fleet Workload Identity exchanges tokens dynamically,
  ensuring no Git credentials or Kubernetes secrets persist on the edge
  clusters.
- **Request privacy:** vLLM logs full completion prompts by default. In
  production, pass `--enable-log-requests false` (or explicitly set it to true
  only during debugging) to prevent PII from leaking into container logs.
- **Internal exposure:** Serving and validation endpoints use internal
  `ClusterIP` services and are accessed via `kubectl port-forward`; production
  exposure requires authenticating API gateways and TLS termination.
- **Pinned provenance:** Runtime images are pinned to explicit version tags and
  should be mirrored into a private artifact registry after vulnerability
  scanning.

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
