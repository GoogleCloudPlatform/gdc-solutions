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

# SFT model deployment using Fleet Packages on Distributed Cloud software only user guide

## Overview

This Solution User Guide (SUG) builds on the
[Solution Reference Implementation (SRI)](reference-implementation.md) to
demonstrate automated day-2 MLOps operations for supervised fine-tuned (SFT)
open-weight models on
[Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
bare-metal clusters. Starting from a deployed `v1.0.0` baseline, **Application
Operators** and **Platform Administrators** interactively validate the served
model through [Gradio](https://github.com/gradio-app/gradio), inspect
application (`PodMonitoring`) and GPU (`dcgm-gmp` for
[NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter); see
[Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics))
telemetry in
[Google Cloud Managed Service for Prometheus](https://docs.cloud.google.com/monitoring/kubernetes-engine/prometheus),
[Cloud Monitoring](https://docs.cloud.google.com/monitoring/docs/monitoring-overview),
and [Cloud Logging](https://docs.cloud.google.com/logging/docs/overview),
promote a new checkpoint (`v2`) via release `v2.0.0`, and roll back to
checkpoint `v1` via immutable forward release `v2.0.1`.

Every change uses the same GitOps lifecycle whether your repository was
initialized from scratch as a standalone GitOps repository
(`SOLUTION_SUBDIR="."`) or forked from `GoogleCloudPlatform/gdc-solutions`
(`SOLUTION_SUBDIR="software-only/bare-metal/sft-model-serving"`), with
`resourceBundleSelector.cloudBuildRepository.path` selecting the environment
subfolder while Config Delivery enforces bare three-part SemVer tags (`vX.Y.Z`):
update the DRY [Kustomize](https://github.com/kubernetes-sigs/kustomize)
sources, render the WET bundle, merge through a pull request, push a bare SemVer
tag, and point the
[Config Delivery `FleetPackage`](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/concepts/fleet-packages)
to the tag for
[Config Sync](https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/overview)
reconciliation.

<!-- prettier-ignore -->
> [!NOTE]
> In the worked lab example, the `v1` and `v2` [Cloud
> Storage](https://docs.cloud.google.com/storage/docs/introduction) prefixes
> hold byte-identical Llama 3.1 8B SFT weights fine-tuned via [**Gemini
> Enterprise Agent Platform** open-model
> tuning](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tuning/open-model-tuning)
> (formerly Vertex AI; see the worked [Llama 3 / open-model SFT Jupyter
> notebook](https://github.com/GoogleCloudPlatform/generative-ai/blob/main/open-models/fine-tuning/get_started_with_oss_tuning_on_vertexai.ipynb))
> on MetaMathQA math word problems. The upgrade and rollback exercises
> demonstrate end-to-end GitOps mechanics—version labels, keyless [Fleet
> Workload
> Identity](https://docs.cloud.google.com/kubernetes-engine/fleet-management/docs/use-workload-identity)
> Cloud Storage download and cache pruning,
> [vLLM](https://github.com/vllm-project/vllm) served-model aliases, and UI
> version display—rather than a change in model outputs. With your own
> fine-tuning runs (`<MODEL_NAME>`), `v2` holds the checkpoint from a new tuning
> job.

![High-level architecture of SFT model serving with Fleet Packages on Distributed Cloud software only](images/sft-model-serving-architecture.png)

### Features and benefits

- **Release-pinned model lifecycle:** Each bare SemVer Git tag atomically binds
  Kubernetes manifests, serving parameters, and the Cloud Storage checkpoint URI
  so **Platform Administrators** promote or roll back fleet deployments by
  updating a single `FleetPackage` `tag` field.
- **Auditable plain-KRM pull requests:** Rendering WET manifests locally ensures
  reviewers see exact Kubernetes resource diffs before any release reaches edge
  clusters.
- **Full-stack application and GPU telemetry:** **Application Operators** and
  **Platform Administrators** correlate vLLM serving metrics (`PodMonitoring`),
  GPU hardware utilization and VRAM occupancy (NVIDIA DCGM Exporter), and
  container logs in Cloud Monitoring and Cloud Logging.
- **Zero cluster secrets and private network boundaries:** Checkpoints sync via
  keyless Fleet Workload Identity while Gradio and vLLM remain strictly inside
  cluster-internal `ClusterIP` Services accessed through `kubectl port-forward`.

### Use cases

- **Domain-specialized edge assistant:** An organization fine-tunes an
  open-weight model in **Gemini Enterprise Agent Platform** on domain workflows
  (illustrated here with math word-problem solving) and promotes updated
  checkpoints across bare-metal sites term by term.
- **Progressive fleet promotion and rapid rollback:** A platform team rolls out
  a newly fine-tuned checkpoint across edge sites one membership at a time
  (`maxConcurrent: 1`) and rolls back cleanly via a forward release tag if
  domain validation detects quality regressions.

## Before you begin

- The [Solution Reference Implementation (SRI)](reference-implementation.md) is
  deployed and verified at release `v1.0.0`, and
  `${HOME}/gdcso-solutions/sft-model-serving/.env` exists on your workstation
  (defining `GITOPS_OWNER`, `GITOPS_REPO`, `SOLUTION_SUBDIR`, `GITOPS_DIR`,
  `REGION`, `PROJECT_ID`, `BUCKET`, `FLEET_PACKAGE`, `NAMESPACE`, and
  `DCGM_NAMESPACE`).
- Your local GitOps clone (`GITOPS_DIR`) has a clean, up-to-date `main` branch.
- In the worked Llama 3.1 8B SFT example, the checkpoint is specialized for
  mathematical reasoning: test with math word problems rather than open
  chit-chat prompts.

### Identity and Access Management

- **Application Operator:** namespace RBAC from the SRI (`get` and `list` pods
  and Services, read pod logs, `pods/portforward`, and `pods/exec`) plus write
  access to `${GITOPS_OWNER}/${GITOPS_REPO}` to open pull requests and push
  release tags.
- **Platform Administrator:** permissions to update `FleetPackage` resources in
  `REGION`.
- **Observability:** Monitoring Viewer (`roles/monitoring.viewer`) and Logs
  Viewer (`roles/logging.viewer`) on `PROJECT_ID` to inspect metrics and logs in
  the Google Cloud console.

### Workstation

- [Workstation] Load the SRI `.env` variables and append the day-2 upgrade and
  rollback variables.

```bash
export SOLUTION_HOME="${HOME}/gdcso-solutions/sft-model-serving"
set -a; source "${SOLUTION_HOME}/.env"; set +a
cat << 'EOF' > "${SOLUTION_HOME}/sug.env" && echo "Successfully created." || echo "Failed to create!"
NEW_RELEASE_TAG="v2.0.0"
NEW_MODEL_VERSION="v2"
NEW_CHECKPOINT_SOURCE_URI="NEW_CHECKPOINT_SOURCE_URI"
ROLLBACK_RELEASE_TAG="v2.0.1"
ROLLBACK_MODEL_VERSION="v1"
EOF
set -a; source "${SOLUTION_HOME}/sug.env"; set +a
```

Replace the following:

- `NEW_CHECKPOINT_SOURCE_URI`: Cloud Storage folder URI holding the new merged
  SFT checkpoint, without a trailing slash (for lab testing with identical
  weights, use `gs://${BUCKET}/sft-model-serving/checkpoints/v1`).

## Implementation

### Access the model through Gradio

- [Workstation] Open a local port-forward tunnel to the Gradio `ClusterIP`
  `Service` (`8080` → container port `7860`).

```bash
kubectl -n "${NAMESPACE}" port-forward svc/gradio-llama-sft-service 8080:8080
```

- [Workstation] Open `http://localhost:8080` in a browser, verify that the page
  header reads `Llama 3.1 8B SFT Chat (v1.0.0)`, and submit a math word problem
  such as
  `"Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May?"`.
  Confirm that the response ends cleanly with `The answer is: 72`.

<!-- prettier-ignore -->
> [!NOTE]
> Gradio passes release alias `llama-3.1-8b-sft-v1.0.0` in its chat request so
> operators can verify both visually and at the API layer which release answers.
> Gradio has no built-in user authentication; keep it strictly behind
> RBAC-controlled port forwarding.

### Monitor the model

Workload metrics (`PodMonitoring/vllm-llama-sft-pod-monitoring`), GPU hardware
metrics (`PodMonitoring/dcgm-gmp` scraping NVIDIA DCGM Exporter per
[Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics)),
and container logs integrate with Cloud Monitoring and Cloud Logging once
application logging and Managed Service for Prometheus collection are enabled;
see
[Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring).

- [Workstation] Check that the `PodMonitoring` resource reconciled cleanly.

```bash
kubectl -n "${NAMESPACE}" get podmonitoring vllm-llama-sft-pod-monitoring \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

The output is similar to the following:

```text
ConfigurationCreateSuccess=True
```

- [Workstation] Query vLLM's local Prometheus `/metrics` endpoint directly to
  verify active serving counters.

```bash
kubectl -n "${NAMESPACE}" port-forward svc/vllm-llama-sft-service 8000:8000 >/dev/null &
PF_PID=$!
sleep 5
curl -s http://localhost:8000/metrics | grep -E '^vllm:(num_requests_running|generation_tokens_total)'
kill "${PF_PID}"
```

The returned series carry label `model_name="llama-3.1-8b-sft"`.

- [Console] In Google Cloud Monitoring **Metrics Explorer**, switch to
  **PromQL** to inspect vLLM token generation rate alongside GPU utilization and
  framebuffer memory occupancy exported by DCGM Exporter:

```text
rate(vllm:generation_tokens_total{model_name="llama-3.1-8b-sft"}[1m])
DCGM_FI_DEV_GPU_UTIL{cluster="CLUSTER_NAME", namespace="DCGM_NAMESPACE"}
DCGM_FI_DEV_FB_USED{cluster="CLUSTER_NAME", namespace="DCGM_NAMESPACE"}
```

Replace the following:

- `CLUSTER_NAME`: the bare-metal cluster name label reported in Google Cloud
  Managed Service for Prometheus (typically matching `MEMBERSHIP`).
- `DCGM_NAMESPACE`: the namespace running `nvidia-dcgm-exporter` where
  `PodMonitoring/dcgm-gmp` was applied in the SRI (for example
  `nvidia-gpu-operator`).

- [Workstation] Inspect container logs locally and in Cloud Logging.

```bash
kubectl -n "${NAMESPACE}" logs deploy/vllm-llama-sft-deployment -c vllm-container --tail=50
gcloud logging read \
    "resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"${NAMESPACE}\" AND resource.labels.container_name=\"vllm-container\"" \
    --project="${PROJECT_ID}" --limit=20 --format="table(timestamp, textPayload)"
```

<!-- prettier-ignore -->
> [!WARNING]
> Because `--enable-log-requests` is set on the worked-example vLLM deployment,
> prompt details appear in container logs and Cloud Logging. Remove
> `--enable-log-requests` through a GitOps release before serving sensitive or
> regulated prompts.

### Upgrade the model from v1.0.0 to v2.0.0

- [Workstation] Upload the new checkpoint into version prefix `v2` in Cloud
  Storage while keeping `v1` intact for rollback.

```bash
gcloud storage cp -r "${NEW_CHECKPOINT_SOURCE_URI%/}/*" "gs://${BUCKET}/sft-model-serving/checkpoints/${NEW_MODEL_VERSION}/"
```

- [Workstation] Create release branch `sft-model-serving-v2.0.0` in your GitOps
  repository.

```bash
cd "${GITOPS_DIR}" && git checkout main && git pull origin main
git checkout -b sft-model-serving-v2.0.0
```

- [Workstation] Review the fields updated under
  `${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/`:

<!-- mdformat off -->

| File                                        | Field                                                             | `v1.0.0` value                                                                         | `v2.0.0` value                                                                         |
| :------------------------------------------ | :---------------------------------------------------------------- | :------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------- |
| `src/base/vllm-llama-sft-deployment.yaml`   | `ai.gke.io/model-version` label (Deployment and pod template)     | `v1`                                                                                   | `v2`                                                                                   |
| `src/base/vllm-llama-sft-deployment.yaml`   | `MODEL_VERSION` env (`gcs-model-downloader` and `vllm-container`) | `v1`                                                                                   | `v2`                                                                                   |
| `src/base/vllm-llama-sft-deployment.yaml`   | `MODEL_GCS_URI` env (`gcs-model-downloader`)                      | `gs://BUCKET/sft-model-serving/checkpoints/v1`                                         | `gs://BUCKET/sft-model-serving/checkpoints/v2`                                         |
| `src/base/vllm-llama-sft-deployment.yaml`   | `--served-model-name` aliases                                     | `llama-3.1-8b-sft`, `llama-3.1-8b-sft-v1.0.0`, `llama-3.1-8b-sft-v1`                   | `llama-3.1-8b-sft`, `llama-3.1-8b-sft-v2.0.0`, `llama-3.1-8b-sft-v2`                   |
| `src/base/gradio-llama-sft-deployment.yaml` | `MODEL_ID`, `TITLE`, `MODEL_NAME` env                             | `llama-3.1-8b-sft-v1.0.0`, `Llama 3.1 8B SFT Chat (v1.0.0)`, `Llama-3.1-8B-SFT-v1.0.0` | `llama-3.1-8b-sft-v2.0.0`, `Llama 3.1 8B SFT Chat (v2.0.0)`, `Llama-3.1-8B-SFT-v2.0.0` |
| `fleetpackage.yaml`                         | `tag`                                                             | `v1.0.0`                                                                               | `v2.0.0`                                                                               |

<!-- mdformat on -->

The stable stream alias (`llama-3.1-8b-sft`, or `<MODEL_NAME>`) remains
unchanged so in-cluster clients continue calling the service without client
reconfiguration across upgrades.

- [Workstation] Apply the version updates across the DRY manifests and
  `fleetpackage.yaml`, verify that no `v1` references remain, and re-render the
  WET bundle.

```bash
cd "${GITOPS_DIR}"
FP_DIR="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package"
sed -i \
    -e "s/v1\.0\.0/${NEW_RELEASE_TAG}/g" \
    -e "s|checkpoints/v1\$|checkpoints/${NEW_MODEL_VERSION}|" \
    -e "s/model-version: v1\$/model-version: ${NEW_MODEL_VERSION}/" \
    -e "s/value: v1\$/value: ${NEW_MODEL_VERSION}/" \
    -e "s/sft-v1\$/sft-${NEW_MODEL_VERSION}/" \
    "${FP_DIR}/src/base/vllm-llama-sft-deployment.yaml" \
    "${FP_DIR}/src/base/gradio-llama-sft-deployment.yaml" \
    "${FP_DIR}/fleetpackage.yaml"
rc=0
grep -rnE 'v1\.0\.0|checkpoints/v1|(value|model-version): v1$|sft-v1$' \
    "${FP_DIR}/src" "${FP_DIR}/fleetpackage.yaml" || rc=$?
if [ "${rc}" -eq 1 ]; then
  echo "No v1 values left."
else
  echo "ERROR: unexpected v1 values or missing files (grep rc=${rc})" >&2
  false
fi
"${FP_DIR}/render.sh"
git diff --stat
```

The output is similar to the following:

```text
No v1 values left.
Rendered .../fleet-package/src/overlays/default to .../fleet-package/environments/default/manifests.yaml
Format .../fleet-package/environments/default/manifests.yaml with prettier before you commit it.
```

- [Workstation] Commit DRY and WET files together, merge through a pull request,
  and push SemVer tag `v2.0.0`.

```bash
cd "${GITOPS_DIR}"
git add "${SOLUTION_SUBDIR}"
git commit -m "sft-model-serving: upgrade to model v2 (release v2.0.0)"
git push origin sft-model-serving-v2.0.0
gh pr create --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --base main \
    --head sft-model-serving-v2.0.0 --fill
gh pr merge sft-model-serving-v2.0.0 --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --merge
git checkout main && git pull origin main
git tag "${NEW_RELEASE_TAG}"
git push origin "${NEW_RELEASE_TAG}"
```

- [Workstation] Update the `FleetPackage` to roll out `v2.0.0`.

```bash
gcloud container fleet packages update "${FLEET_PACKAGE}" \
    --source="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/fleetpackage.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"
```

### Roll back the model from v2 to v1 with a forward release

Rolling back via a forward SemVer tag (`v2.0.1`) preserves a strictly linear,
auditable Git release history without moving or deleting existing tags.

- [Workstation] Create branch `sft-model-serving-v2.0.1`, revert checkpoint
  fields to `v1` under release tag `v2.0.1`, verify that no stale `v2` values
  remain, and re-render the WET bundle.

```bash
cd "${GITOPS_DIR}" && git checkout main && git pull origin main
git checkout -b sft-model-serving-v2.0.1
FP_DIR="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package"
NEW_RELEASE_TAG_ESCAPED=$(printf '%s' "${NEW_RELEASE_TAG}" | sed 's/\./\\./g')
sed -i \
    -e "s/${NEW_RELEASE_TAG_ESCAPED}/${ROLLBACK_RELEASE_TAG}/g" \
    -e "s|checkpoints/${NEW_MODEL_VERSION}\$|checkpoints/${ROLLBACK_MODEL_VERSION}|" \
    -e "s/model-version: ${NEW_MODEL_VERSION}\$/model-version: ${ROLLBACK_MODEL_VERSION}/" \
    -e "s/value: ${NEW_MODEL_VERSION}\$/value: ${ROLLBACK_MODEL_VERSION}/" \
    -e "s/sft-${NEW_MODEL_VERSION}\$/sft-${ROLLBACK_MODEL_VERSION}/" \
    "${FP_DIR}/src/base/vllm-llama-sft-deployment.yaml" \
    "${FP_DIR}/src/base/gradio-llama-sft-deployment.yaml" \
    "${FP_DIR}/fleetpackage.yaml"
rc=0
grep -rnE 'v2\.0\.0|checkpoints/v2|(value|model-version): v2$|sft-v2$' \
    "${FP_DIR}/src" "${FP_DIR}/fleetpackage.yaml" || rc=$?
if [ "${rc}" -eq 1 ]; then
  echo "No v2 values left."
else
  echo "ERROR: unexpected v2 values or missing files (grep rc=${rc})" >&2
  false
fi
"${FP_DIR}/render.sh"
git diff --stat
```

The output is similar to the following:

```text
No v2 values left.
Rendered .../fleet-package/src/overlays/default to .../fleet-package/environments/default/manifests.yaml
Format .../fleet-package/environments/default/manifests.yaml with prettier before you commit it.
```

- [Workstation] Commit, merge through a pull request, push tag `v2.0.1`, and
  update the `FleetPackage`.

```bash
cd "${GITOPS_DIR}"
git add "${SOLUTION_SUBDIR}"
git commit -m "sft-model-serving: roll back to model v1 (release v2.0.1)"
git push origin sft-model-serving-v2.0.1
gh pr create --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --base main \
    --head sft-model-serving-v2.0.1 --fill
gh pr merge sft-model-serving-v2.0.1 --repo "${GITOPS_OWNER}/${GITOPS_REPO}" --merge
git checkout main && git pull origin main
git tag "${ROLLBACK_RELEASE_TAG}"
git push origin "${ROLLBACK_RELEASE_TAG}"
gcloud container fleet packages update "${FLEET_PACKAGE}" \
    --source="${GITOPS_DIR}/${SOLUTION_SUBDIR}/fleet-package/fleetpackage.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"
```

Measured rollback behavior on the validation cluster (measured on the earlier
lab source before the vLLM image update; timings vary with network bandwidth and
GPU node storage):

- Managed Cloud Build OCI packaging completed in roughly `2` minutes before
  cluster rollout began.
- Total time from `FleetPackage` update to ready vLLM pod was `5` minutes `21`
  seconds, with roughly `3` minutes without serving under `strategy: Recreate`
  (largely the `120`-second readiness initial delay).
- Because `v2.0.0` pruned `v1` from the local PVC cache, the `initContainer`
  re-downloaded `~15 GiB` at `781.9 MiB/s` average and pruned `v2` in `24`
  seconds total.

<!-- prettier-ignore -->
> [!NOTE]
> Re-pointing `FleetPackage` directly back to `tag: v1.0.0` also redeploys
> checkpoint `v1` while `gs://BUCKET/sft-model-serving/checkpoints/v1` exists;
> forward releases are preferred so the active deployment always matches `HEAD`
> on `main`.

## Verification

- [Workstation] Wait for the newest rollout to report `COMPLETED` and confirm
  the replacement pod is `Running` and `Ready`.

```bash
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}"
kubectl -n "${NAMESPACE}" get pods -l app=vllm-llama-sft
```

- [Workstation] Inspect `gcs-model-downloader` logs to verify keyless download
  and cache pruning (`v1` pruned on upgrade; `v2` pruned on rollback).

```bash
kubectl -n "${NAMESPACE}" logs deploy/vllm-llama-sft-deployment -c gcs-model-downloader
```

The output after upgrading to `v2.0.0` is similar to the following:

```text
Checking the cache for model version 'v2'...
Active account: GSA_NAME@PROJECT_ID.iam.gserviceaccount.com
Downloading gs://BUCKET/sft-model-serving/checkpoints/v2 with fleet Workload Identity credentials...
Checking the required files for model version 'v2'...
Deleting other model versions from the cache...
Removing /model-cache/llama-3.1-8b-sft/v1
Model version 'v2' sync and cache maintenance complete.
```

- [Workstation] Check the active model aliases on `/v1/models` and run the math
  smoke test.

```bash
kubectl -n "${NAMESPACE}" port-forward svc/vllm-llama-sft-service 8000:8000 >/dev/null &
PF_PID=$!
sleep 5
curl -s http://localhost:8000/v1/models | jq -r '.data[].id'
curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-3.1-8b-sft", "max_tokens": 512, "temperature": 0,
         "messages": [{"role": "user", "content": "Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May?"}]}' \
    | jq -r '.choices[0].message.content' | tail -n 1
kill "${PF_PID}"
```

After upgrading to `v2.0.0`, the output is similar to the following (after
rolling back via `v2.0.1`, the versioned aliases read `llama-3.1-8b-sft-v2.0.1`
and `llama-3.1-8b-sft-v1`):

```text
llama-3.1-8b-sft
llama-3.1-8b-sft-v2.0.0
llama-3.1-8b-sft-v2
The answer is: 72
```

- [Workstation] Re-open Gradio (see
  [Access the model through Gradio](#access-the-model-through-gradio)) and
  verify that the title matches the active release tag.

## Operations

- **Subsequent model promotions:** Repeat the upgrade workflow (`v3` / tag
  `v3.0.0`) while retaining prior checkpoint prefixes in Cloud Storage for
  rollback safety.
- **Container runtime updates:** Bump pinned image versions (for example
  `vllm/vllm-openai`) in `src/base/`, render, merge, and tag—never deploy
  mutable `:latest` tags.
- **Serving pause window:** Schedule releases inside maintenance windows because
  single-GPU `strategy: Recreate` pauses inference while pods swap.
- **Canary fleet wave:** With `maxConcurrent: 1`, verify inference health on the
  first updated membership before the wave advances across remaining clusters.
- **Aborting a stalled rollout:** If a rollout stalls, remediate the root cause
  first, then abort the stalled rollout so Config Delivery unblocks subsequent
  releases:

```bash
gcloud container fleet packages rollouts abort ROLLOUT_ID \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}"
```

Replace the following:

- `ROLLOUT_ID`: identifier of the stalled rollout returned by
  `gcloud container fleet packages rollouts list`.

## Troubleshooting

<!-- mdformat off -->

| Symptom                                                    | Cause                                                                                                                               | Resolution                                                                                                                                                                                                                                                                                                                                                      |
| :--------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New release rollout doesn't start                          | SemVer tag wasn't pushed to `origin`, or `FleetPackage` wasn't updated                                                              | Verify `git ls-remote --tags origin` and re-run `gcloud container fleet packages update`                                                                                                                                                                                                                                                                        |
| Rollout enters `STALLED` state                             | Cluster RBAC or reconciliation failure on the active cluster                                                                        | Fix the underlying error, then run `rollouts abort` (see [Operations](#operations))                                                                                                                                                                                                                                                                             |
| Rollback `initContainer` fails on missing checkpoint files | Prior version prefix (`checkpoints/v1`) was deleted from Cloud Storage                                                              | Restore the checkpoint files in Cloud Storage or roll forward to an intact checkpoint prefix                                                                                                                                                                                                                                                                    |
| `kubectl port-forward` disconnects during rollout          | `strategy: Recreate` terminated the previous pod                                                                                    | Restart `kubectl port-forward` once the replacement pod reaches `1/1 Running`                                                                                                                                                                                                                                                                                   |
| Gradio displays prior version title                        | Browser cache or pending Gradio pod rollout                                                                                         | Refresh browser cache and check `kubectl -n "${NAMESPACE}" get pods`                                                                                                                                                                                                                                                                                            |
| Non-math prompts produce math derivations                  | Worked-example checkpoint is fine-tuned on MetaMathQA                                                                               | Validate the worked example with math word problems                                                                                                                                                                                                                                                                                                             |
| Missing vLLM or GPU metrics in Cloud Monitoring            | `enableGMPForApplications`, `PodMonitoring/vllm-llama-sft-pod-monitoring`, `PodMonitoring/dcgm-gmp`, or DCGM Exporter isn't enabled | Verify `PodMonitoring` conditions and see [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring) and [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics) |
| Missing container logs in Cloud Logging                    | Cluster application log forwarding isn't enabled                                                                                    | Enable application logging per [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)                                                                                                                                                             |

<!-- mdformat on -->

## Clean up

This user guide creates checkpoint prefix `v2`, two merged branches, two release
tags, and `${SOLUTION_HOME}/sug.env`. To tear down the entire cluster deployment
and Google Cloud resources afterward, run the
[Clean up](reference-implementation.md#clean-up) section of the Solution
Reference Implementation (SRI).

- [Workstation] Verify that `FleetPackage` points to `v2.0.1` (model `v1`), then
  remove checkpoint prefix `v2` if you no longer need to redeploy `v2.0.0`.

```bash
gcloud container fleet packages describe "${FLEET_PACKAGE}" \
    --location="${REGION}" --project="${PROJECT_ID}" \
    --format="value(resourceBundleSelector.cloudBuildRepository.tag)"
gcloud storage rm -r "gs://${BUCKET}/sft-model-serving/checkpoints/${NEW_MODEL_VERSION}/"
```

- [Workstation] Delete the merged feature branches and local `sug.env` while
  preserving immutable Git tags as your release audit trail.

```bash
cd "${GITOPS_DIR}" && git checkout main
git push origin --delete sft-model-serving-v2.0.0 sft-model-serving-v2.0.1
git branch -D sft-model-serving-v2.0.0 sft-model-serving-v2.0.1
rm -f "${SOLUTION_HOME}/sug.env"
```

## What's next

- [Solution Reference Architecture (SRA)](../README.md)
- [Solution Reference Implementation (SRI)](reference-implementation.md)
