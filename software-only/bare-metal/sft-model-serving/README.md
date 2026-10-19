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

<!-- cspell:words vllm gradio kustomize jinja safetensors fleetpackage gkehub cloudsdktool metamathqa podmonitoring rootsync cuda configdelivery kustomization serviceaccount mdformat rollouts -->

# SFT model serving with Fleet Packages on Distributed Cloud software only

This solution deploys a supervised fine-tuned (SFT) open model to Google
Distributed Cloud software only for bare metal clusters through GitOps. Config
Delivery (Fleet Packages) rolls out a versioned Kubernetes bundle from your fork
of this repository to every fleet cluster that carries a label, and Config Sync
applies it. Each cluster serves the model locally with vLLM on one NVIDIA GPU,
with a Gradio chat UI for validation and Google Cloud Managed Service for
Prometheus for metrics. It is for platform administrators and application
operators who fine-tune open models in Google Cloud and serve them at the edge.

The worked example is a Llama 3.1 8B base model fully fine-tuned on MetaMathQA
math word problems with Vertex AI managed open model tuning. You bring your own
fine-tuned checkpoint.

## Disclaimer

This is not an officially supported Google product. This project is provided
for reference and educational purposes only, on a best-effort basis, with no
official support and no service level agreement (SLA). It is not eligible for
the
[Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

This solution does not include model weights. You must obtain the model you
deploy yourself and comply with its license, for example the
[Llama 3.1 Community License](https://www.llama.com/llama3_1/license/) and the
[Llama 3.1 Acceptable Use Policy](https://www.llama.com/llama3_1/use-policy/).
A model fine-tuned from Llama 3.1 is a derivative of Llama 3.1 and remains
subject to that license.

## Architecture

```text
Fork of gdc-solutions (tag vX.Y.Z)
  -> Cloud Build repository connection
  -> FleetPackage (Config Delivery) -> RootSync (Config Sync) on each cluster
  -> Namespace sft-model-serving:
       initContainer: Cloud Storage checkpoint -> PVC /model-cache/<model>/<MODEL_VERSION>
       vLLM Deployment (1 GPU) <- ConfigMap vllm-llama-sft-config (chat template, generation config)
       Gradio Deployment -> vLLM Service :8000
       PodMonitoring -> Google Cloud Managed Service for Prometheus
```

- Git carries only manifests. The model weights stay in your Cloud Storage
  bucket, one prefix per model version.
- `MODEL_VERSION` and `MODEL_GCS_URI` in the vLLM `Deployment` select the
  checkpoint, so one release tag pins the code, the configuration and the model
  version.
- The model-download initContainer reads Cloud Storage with fleet Workload
  Identity Federation. No service account key and no node credentials are used.
- vLLM runs the upstream `vllm/vllm-openai` image with its default
  OpenAI-compatible server, which serves `/v1/chat/completions`, `/v1/models`,
  `/health` and `/metrics`.
- The chat template and the generation config come from a `ConfigMap`, so the
  prompt format is reviewed in Git. The example checkpoint was tuned in the
  Llama 3 header format (`<|start_header_id|>`, `<|end_header_id|>`,
  `<|eot_id|>`), and its tokenizer has no chat template.

📝 **TODO:** Link the published reference architecture and implementation guide
when they are available.

## Prerequisites

- A Distributed Cloud software only for bare metal cluster, version 1.35 or
  later, registered to a fleet in your Google Cloud project.
- One NVIDIA GPU dedicated to the model on the target cluster (reference: NVIDIA
  RTX PRO 6000 Blackwell, 96 GB). The NVIDIA GPU Operator is installed and
  provides the `nvidia` RuntimeClass and the `nvidia.com/gpu` resource.
- An NVIDIA driver that supports CUDA 13.0 (driver branch 580 or later). The
  `vllm/vllm-openai:v0.32.0` image declares `cuda>=13.0`.
- Config Sync on the target clusters.
- A StorageClass named `local-shared`, or change `storageClassName` in
  `fleet-package/src/base/sft-model-cache-pvc.yaml`. The node needs about 250
  GiB of local disk for the 100 GiB cache, the images and system reservations.
- Outbound HTTPS (443) from the cluster to Google Cloud APIs, Cloud Storage,
  `gcr.io`, `us-docker.pkg.dev` and Docker Hub, or mirrors of the images in your
  own registry.
- 💡 **TIP:** The vLLM image comes from Docker Hub, which rate-limits anonymous
  pulls, and is several GB. For production fleets, mirror the pinned images to
  your own Artifact Registry and change the `image` fields.
- Google Cloud APIs: Config Delivery, Cloud Build, Secret Manager, GKE Hub
  (fleet) and Cloud Storage.
- A fine-tuned merged checkpoint (`config.json`, tokenizer files,
  `model.safetensors.index.json` and the safetensors shards) in your bucket
  under one prefix per version.
- Tools: `gcloud`, `kubectl` with Kustomize v5 or later, and `git`.

### Identities and roles

- **Workload Google service account** (`YOUR_GSA_NAME`):
  `roles/storage.objectViewer` on the checkpoint bucket, and
  `roles/iam.workloadIdentityUser` on the service account granted to
  `serviceAccount:YOUR_PROJECT_ID.svc.id.goog[sft-model-serving/vllm-llama-sft-sa]`.
- **Publisher service account** (`YOUR_PUBLISHER_SA_NAME`, one per solution):
  `roles/configdelivery.resourceBundlePublisher` and `roles/logging.logWriter`.
- **Cloud Build GitHub connection:** authorized by a dedicated machine-user
  account with read access to your fork. Don't use a personal access token.
- **Config Delivery service agent and Config Sync reconciler:** see
  [Security notes](#security-notes).

## Repository layout

```text
sft-model-serving/
├── README.md
└── fleet-package/
    ├── fleetpackage.yaml                  # FleetPackage specification
    ├── render.sh                          # Renders src/ into environments/
    ├── environments/
    │   └── default/
    │       └── manifests.yaml             # Rendered (WET) bundle, packaged by Config Delivery
    └── src/
        ├── base/                          # DRY Kustomize sources
        │   ├── kustomization.yaml
        │   ├── namespace.yaml
        │   ├── vllm-llama-sft-serviceaccount.yaml
        │   ├── gcs-credential-config.yaml
        │   ├── vllm-llama-sft-config.yaml
        │   ├── sft-model-cache-pvc.yaml
        │   ├── vllm-llama-sft-deployment.yaml
        │   ├── vllm-llama-sft-service.yaml
        │   ├── vllm-llama-sft-podmonitoring.yaml
        │   ├── gradio-llama-sft-deployment.yaml
        │   └── gradio-llama-sft-service.yaml
        └── overlays/
            └── default/
                └── kustomization.yaml
```

Config Delivery packages the variant folder as is, without running Kustomize, so
`environments/default/` holds plain manifests and no `kustomization.yaml`.

## Configuration

Config Sync and Fleet Packages apply manifests as they are and don't substitute
variables. Replace these placeholders in your fork, in the files listed, before
you render and deploy:

<!-- mdformat off -->

| Placeholder              | Description                                                                                                    | Files                                                                                                                     |
| :----------------------- | :------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------ |
| `YOUR_PROJECT_ID`        | Fleet host project ID; also the fleet Workload Identity pool `YOUR_PROJECT_ID.svc.id.goog`                     | `vllm-llama-sft-serviceaccount.yaml`, `gcs-credential-config.yaml`, `vllm-llama-sft-deployment.yaml`, `fleetpackage.yaml` |
| `YOUR_MEMBERSHIP`        | Fleet membership name of the target cluster (part of its identity provider)                                    | `gcs-credential-config.yaml`                                                                                              |
| `YOUR_GSA_NAME`          | Google service account that reads the checkpoint bucket                                                        | `vllm-llama-sft-serviceaccount.yaml`, `gcs-credential-config.yaml`                                                        |
| `YOUR_BUCKET`            | Cloud Storage bucket with the checkpoints; adjust the `sft-model-serving/checkpoints/v1` prefix to your layout | `vllm-llama-sft-deployment.yaml`                                                                                          |
| `YOUR_CONNECTION`        | Cloud Build 2nd gen repository connection in `us-central1`                                                     | `fleetpackage.yaml`                                                                                                       |
| `YOUR_REPOSITORY`        | Cloud Build repository that points to your fork                                                                | `fleetpackage.yaml`                                                                                                       |
| `YOUR_PUBLISHER_SA_NAME` | Publisher service account of the FleetPackage                                                                  | `fleetpackage.yaml`                                                                                                       |

<!-- mdformat on -->

Other values to review:

- `MODEL_VERSION` (`v1`) and `MODEL_GCS_URI` in the initContainer, the
  `MODEL_VERSION` of the vLLM container, and the `ai.gke.io/model-version`
  labels.
- The served model aliases (`llama-3.1-8b-sft`, `llama-3.1-8b-sft-v1.0.0`,
  `llama-3.1-8b-sft-v1`) and the Gradio `MODEL_ID`, `TITLE` and `MODEL_NAME`.
- The membership label `app-tier: sft-model-serving` in `fleetpackage.yaml`.
- The chat template and `generation_config.json` in
  `vllm-llama-sft-config.yaml` if your checkpoint uses another prompt format.
  vLLM reads them at startup, so restart the vLLM pod after a change.

## Deploy

1.  Fork this repository and clone your fork.
2.  Replace the placeholders in `fleet-package/src/base/` and
    `fleet-package/fleetpackage.yaml`.
3.  Render the bundle and review the diff:

    ```bash
    PRETTIER="npx --prefix .devcontainer/dependencies prettier" \
        software-only/bare-metal/sft-model-serving/fleet-package/render.sh
    git diff
    ```

4.  Commit the DRY and rendered files in one pull request to your fork. After
    the merge, create the release tag (`cloudBuildRepository.path` isolates the
    solution subfolder, while Config Delivery requires bare `vX.Y.Z` tags in
    your fork):

    ```bash
    git tag v1.0.0
    git push origin v1.0.0
    ```

5.  Create the Cloud Build repository connection to your fork, the publisher
    service account and the workload Google service account with the roles in
    [Identities and roles](#identities-and-roles).
6.  Label the target membership:

    ```bash
    gcloud container fleet memberships update YOUR_MEMBERSHIP \
        --location=global --update-labels=app-tier=sft-model-serving
    ```

7.  Create the FleetPackage:

    ```bash
    gcloud container fleet packages create sft-model-serving \
        --source=software-only/bare-metal/sft-model-serving/fleet-package/fleetpackage.yaml \
        --location=us-central1
    ```

8.  Check the rollout and the workload:

    ```bash
    gcloud container fleet packages rollouts list \
        --fleet-package=sft-model-serving --location=us-central1
    kubectl -n sft-model-serving get pods
    kubectl -n sft-model-serving logs deploy/vllm-llama-sft-deployment -c gcs-model-downloader
    ```

9.  Send a math word problem, the domain of the example model:

    ```bash
    kubectl -n sft-model-serving port-forward svc/vllm-llama-sft-service 8000:8000
    curl -s http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model": "llama-3.1-8b-sft", "max_tokens": 512, "temperature": 0,
             "messages": [{"role": "user", "content": "Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May?"}]}'
    ```

    The example model ends its answer with `The answer is: 72`.

10. Open the Gradio UI with
    `kubectl -n sft-model-serving port-forward svc/gradio-llama-sft-service 8080:8080`
    and browse to `http://localhost:8080`.

To release a new model version, upload the checkpoint to a new prefix, change
`MODEL_VERSION`, `MODEL_GCS_URI`, the labels and the aliases, render, merge,
tag `vX.Y.Z` (for example `v2.0.0`), and set the FleetPackage `tag` to it. To
roll back, cut a forward release tag (for example `v2.0.1`) that restores the
earlier `MODEL_VERSION` and `MODEL_GCS_URI`, or set the `tag` to the earlier
release (`v1.0.0`); the initContainer downloads the earlier checkpoint again,
so keep its prefix in Cloud Storage.

## Security notes

- 🛑 **CAUTION:** Don't bind the Config Delivery service agent or the Config
  Sync reconciler to `cluster-admin`. Grant the service agent a `ClusterRole`
  limited to `RootSync` objects in `config-management-system`, and limit the
  reconciler to the kinds in this bundle: `Namespace`, `ServiceAccount`,
  `ConfigMap`, `PersistentVolumeClaim`, `Deployment`, `Service` and
  `PodMonitoring`.
- 📝 **TODO:** Add a validated least-privilege RBAC example for the Config
  Delivery service agent and the Config Sync reconciler, and confirm whether
  Config Delivery exposes `RootSync` role overrides.
- Both Services are `ClusterIP`. vLLM has no API key; don't expose it outside the
  cluster without an authenticating gateway. Gradio has no authentication and is
  a validation tool only.
- `--enable-log-requests` writes request details to container logs, which can
  reach Cloud Logging. Remove it where prompts can contain personal data.
- The pods don't mount a Kubernetes API token. The initContainer gets only a
  projected token with the Workload Identity audience.
- Scan the pinned images and consider mirroring them to your own Artifact
  Registry.

## Limitations

- One replica on one GPU per cluster; tensor parallelism across GPUs isn't
  covered. The `Recreate` strategy stops serving during each release.
- The `local-shared` cache ties the vLLM pod to the node that holds the volume,
  and the cache keeps only the current model version.
- The fleet Workload Identity credential configuration names one membership. 📝
  **TODO:** Document the pattern for a fleet with several target clusters, for
  example one variant per membership.
- The example model is a math specialist. It answers math word problems well but
  turns open prompts into math-style derivations.
- 📝 **TODO:** Verify the fleet Workload Identity credential configuration and
  the Config Sync enablement on a Distributed Cloud software only bare metal
  cluster.

## Clean up

1.  Delete the FleetPackage:

    ```bash
    gcloud container fleet packages delete sft-model-serving --location=us-central1
    ```

2.  Remove the label from the membership:

    ```bash
    gcloud container fleet memberships update YOUR_MEMBERSHIP \
        --location=global --remove-labels=app-tier
    ```

3.  📝 **TODO:** Confirm whether deleting the FleetPackage prunes the objects.
    If they remain, delete the namespace, which also deletes the cached
    weights:

    ```bash
    kubectl delete namespace sft-model-serving
    ```

4.  Delete the Cloud Build repository connection, the service accounts and
    their IAM bindings, and the checkpoint prefixes you no longer need.

## Validated versions

The rendered bundle was applied with `kubectl` to a test cluster: Kubernetes
`v1.35.2-gke.300`, one NVIDIA RTX PRO 6000 Blackwell GPU, NVIDIA driver
`580.126.20` (CUDA 13.0). These checks passed: the model download, vLLM
readiness, the three served model aliases in `/v1/models`, the GSM8K problem
from [Deploy](#deploy) through `/v1/chat/completions` (answer
`The answer is: 72`, generation stopped on `<|eot_id|>`, token 128009), the
Gradio UI calling the vLLM Service, and the `PodMonitoring` resource.

- `vllm/vllm-openai:v0.32.0` (latest vLLM GA release on 2026-10-18).
- `us-docker.pkg.dev/google-samples/containers/gke/gradio-app:v1.0.4`.
- `gcr.io/google.com/cloudsdktool/cloud-sdk:589.0.0-slim`.

📝 **TODO:** Validate delivery through the FleetPackage and Config Sync
(including the least-privilege RBAC), vLLM
metrics arriving in Cloud Monitoring, the explicit
`gcloud auth login --cred-file` step of the initContainer in the full bundle,
and the bundle on a physical bare-metal server.
