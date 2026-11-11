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

# Federated Learning for Edge AI on Distributed Cloud software only

Reference GitOps fleet packages, Flower (`flwr==1.36.0`) edge trainer and
central SuperLink applications, and two-phase canary verification scripts for
running privacy-preserving federated LoRA (`Fed-LoRA`) fine-tuning and hot-swap
`vLLM` serving of `google/gemma-4-E2B-it` across Distributed Cloud software only
edge store clusters and a central Google Kubernetes Engine (GKE) aggregator.

📌 **NOTE:** Full Solution Reference Architecture (SRA), Solution Reference
Implementation (`docs/reference-implementation.md`), and Solution User Guide
(`docs/user-guide.md`) documentation will be added in a follow-up update.

## Disclaimer

This is not an officially supported Google product. This project is provided for
reference and educational purposes only, on a best-effort basis, with no
official support and no service level agreement (SLA). It is not eligible for
the
[Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

## Model license notice

This solution does not include model weights. You must obtain the model you
deploy yourself and comply with its license, specifically the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms) before deploying Gemma 4
weights in your environment.

## Architecture

Each Distributed Cloud software only edge store cluster keeps raw domain JSONL
records strictly on local persistent storage, runs `vLLM`
(`google/gemma-4-E2B-it`) with dynamic LoRA adapter loading and sleep-mode VRAM
elasticity on a single shared GPU, and executes local KL-regularized LoRA
fine-tuning (`KLProxTrainer` in `apps/fed-lora/clientapp.py`). Only compact
rank-16 `lora_B` weight deltas cross the WAN to the central GKE Flower SuperLink
(`apps/fed-lora/serverapp.py`), which merges store updates via subspace residual
projection / TIES-Merging and gates promotion behind deterministic + zero-VRAM
base-model canary checks (`apps/fed-lora/canary_eval.py`).

## Prerequisites

The Distributed Cloud software only edge clusters and central GKE aggregator
cluster are prerequisites (not provisioned by the `FleetPackage` bundles):

- Two Distributed Cloud software only standalone bare-metal clusters (`1.36.0`
  or later) registered to your Google Cloud fleet with Config Sync enabled,
  labeled `app-tier=fed-lora-edge` and `store=store-1` / `store=store-2`, each
  equipped with an NVIDIA GPU (48 GB+ VRAM recommended) and NVIDIA GPU Operator.
- One central GKE Standard cluster registered to the same fleet with Config Sync
  and Workload Identity enabled, labeled `app-tier=fed-lora-aggregator`.
- Cloud Storage bucket (`gs://YOUR_GCS_BUCKET`), Artifact Registry Docker
  repository (`YOUR_AR_REPO`), and least-privilege Workload Identity bindings
  for `YOUR_WORKLOAD_SA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com`.

## Repository layout

```text
fed-lora/
├── README.md
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
│   ├── flwr-client/
│   ├── flwr-server/
│   ├── gpu-time-slicing/
│   ├── monitoring/
│   └── vllm-serving/
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
│   ├── store-1/
│   └── store-2/
└── scripts/
    ├── apply_cluster_secrets.sh
    ├── build_and_stage_fab.sh
    ├── demo_runner.sh
    ├── deploy_demo_dashboard.sh
    ├── eval_local_gemma_judge.py
    ├── render_fleet_manifests.sh
    └── ...
```

## Configuration

Replace these placeholders in a private GitOps repository copy or rendered
release bundle before deploying (never commit real environment values to a
public fork):

<!-- mdformat off -->

| Placeholder               | Description                                                                        |
| :------------------------ | :--------------------------------------------------------------------------------- |
| `YOUR_PROJECT_ID`         | Google Cloud fleet host project ID                                                 |
| `YOUR_PROJECT_NUMBER`     | Numeric Google Cloud fleet host project number (for Config Delivery RBAC)          |
| `YOUR_CONNECTION`         | Cloud Build 2nd-gen Git repository connection name in `us-central1`                |
| `YOUR_REPOSITORY`         | Linked repository resource name inside `YOUR_CONNECTION`                           |
| `YOUR_PUBLISHER_SA_NAME`  | Service account name used by Config Delivery / Cloud Build to package bundles      |
| `YOUR_WORKLOAD_SA_NAME`   | Workload service account name granted scoped Cloud Storage adapter prefix access   |
| `YOUR_GCS_BUCKET`         | Cloud Storage bucket storing round-0 template and federated LoRA adapter artifacts |
| `YOUR_AR_REPO`            | Artifact Registry Docker repository in `us-central1` for trainer/superlink images  |
| `YOUR_STORE_1_CLUSTER`    | Fleet membership name of Distributed Cloud software only edge cluster 1            |
| `YOUR_STORE_2_CLUSTER`    | Fleet membership name of Distributed Cloud software only edge cluster 2            |
| `YOUR_AGGREGATOR_CLUSTER` | Fleet membership name of the central GKE aggregator cluster                        |

<!-- mdformat on -->

- **Flower `run-config` (`gcs-bucket`):** `apps/fed-lora/pyproject.toml` sets
  `gcs-bucket = "gs://YOUR_GCS_BUCKET"`, which can also be overridden at runtime
  via
  `flwr run . <federation> --run-config 'gcs-bucket="gs://YOUR_GCS_BUCKET"'`.
  Both `serverapp.py` and `clientapp.py` resolve the canonical Round-0 PEFT
  template (`gs://<bucket>/checkpoints/round-0/`) and round checkpoint prefixes
  from `gcs-bucket`.

📌 **NOTE:** Sample manifests use RFC 1918 private VIPs on `10.200.0.0/24`
(`10.200.0.50` for the central SuperLink internal LoadBalancer, `10.200.0.131`
and `10.200.0.163` for Store 1 and Store 2 `vLLM` LoadBalancers), and
`base/gpu-time-slicing/` configures 2x GPU time-slicing on single-GPU store
nodes so `vLLM` and `flwr-trainer` can share one GPU. Adjust those settings in
`base/` and `overlays/` if your environment uses dedicated GPUs or a different
VPC CIDR.

## Deploy

1. **Build and push container images** (`flwr-trainer:v2.1.6` and
   `flwr-superlink:v2.1.6`) into your Artifact Registry repository:

   ```bash
   gcloud builds submit --project="YOUR_PROJECT_ID" \
     --config=software-only/bare-metal/fed-lora/docker/cloudbuild-images.yaml \
     --substitutions=_AR_REPOSITORY="YOUR_AR_REPO",_IMAGE_TAG="v2.1.6" \
     software-only/bare-metal/fed-lora
   ```

2. **Apply one-time cluster prerequisites:**
   - Substitute `YOUR_PROJECT_NUMBER` in
     `fleet-package/configdelivery-rbac.yaml` and apply it on all three clusters
     so the Config Delivery service agent has namespace-scoped `RootSync`
     permissions in `config-management-system`.
   - Bootstrap `hf-token-secret` and `ar-pull-secret` on the edge clusters with
     `./scripts/apply_cluster_secrets.sh`, and initialize the Cloud Storage
     bucket with `./scripts/stage_gcs_data.sh`.

3. **Render and roll out FleetPackage bundles:** Because Google Cloud Config
   Delivery does not substitute `YOUR_*` placeholders automatically, substitute
   your values in `base/` and `overlays/` inside a private GitOps repository (or
   into rendered temporary bundles for `ResourceBundle` upload), regenerate
   `fleet-package/environments/*/manifests.yaml` via
   `./fleet-package/render.sh`, push an immutable release tag (`v1.0.0`), and
   apply `fleet-package/fleetpackage-central.yaml` and
   `fleet-package/fleetpackage-edge.yaml`:

   ```bash
   ./fleet-package/render.sh
   ./scripts/render_fleet_manifests.sh --check
   gcloud container fleet packages create fed-lora-central-package \
     --source=fleet-package/fleetpackage-central.yaml --location=us-central1
   gcloud container fleet packages create fed-lora-edge-package \
     --source=fleet-package/fleetpackage-edge.yaml --location=us-central1
   ```

4. **Verify offline unit tests and cluster readiness:**

   ```bash
   python3 apps/fed-lora/test_flower_hardening.py -v
   ./scripts/verify_demo_setup.sh --dry-run
   ```

## Clean up

Delete the `FleetPackage` resources (`deletionPropagationPolicy: FOREGROUND`
removes the managed `RootSync` and packaged Kubernetes resources cleanly), then
remove one-time RBAC and bootstrap secrets:

```bash
gcloud container fleet packages delete fed-lora-edge-package --location=us-central1
gcloud container fleet packages delete fed-lora-central-package --location=us-central1
kubectl delete -f fleet-package/configdelivery-rbac.yaml
```

## Validated versions

- Distributed Cloud software only for bare metal: `1.36.0-gke.532`
- Flower framework (`flwr`, `flwr/supernode`, `flwr/superlink`): `1.36.0`
- Base serving image:
  `us-docker.pkg.dev/vertex-ai/vertex-vision-model-garden-dockers/pytorch-vllm-serve:gemma4`
  (`sha256:3fbc0e08c46e7736145c9effbcc8839682c80b15b413335146f4428fc3523c8a`)
- Open-weight model: `google/gemma-4-E2B-it`
