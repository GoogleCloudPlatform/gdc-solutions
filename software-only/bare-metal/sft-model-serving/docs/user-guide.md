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

This Solution User Guide (SUG) demonstrates day-2 MLOps operations on a cluster
deployed with the
[Solution Reference Implementation (SRI)](reference-implementation.md):
interactive [Gradio](https://github.com/gradio-app/gradio) release validation,
[Cloud Monitoring](https://docs.cloud.google.com/monitoring/docs/monitoring-overview)
and [Cloud Logging](https://docs.cloud.google.com/logging/docs/overview)
inspection, upgrading from `v1.0.0` (model `v1`) to `v2.0.0` (model `v2`), and
forward rollback via `v2.0.1`. For the system architecture diagram, GitOps
pipeline design, and component boundaries, see
[Architecture and design](../README.md#architecture-and-design) in the Solution
Reference Architecture (SRA). For the detailed, step-by-step implementation of
the solution on a validation and testing environment, which this guide builds
on, see the SRI.

<!-- prettier-ignore -->
> [!NOTE]
> In the worked example, `v1` and `v2` hold identical Llama 3.1 8B SFT math
> weights so the upgrade and rollback exercises isolate GitOps release tagging,
> keyless [Cloud
> Storage](https://docs.cloud.google.com/storage/docs/introduction) sync, cache
> pruning, served-model aliases, and UI banner updates rather than model output
> changes. In your own `<MODEL_NAME>` workflow, `v2` should point to a newly
> fine-tuned checkpoint.

## Before you begin

- Release `v1.0.0` from the Solution Reference Implementation (SRI) is deployed
  and verified (see [Verification](reference-implementation.md#verification) in
  the SRI), `${HOME}/gdcso-solutions/sft-model-serving/.env` exists on your
  workstation, and `GITOPS_DIR` is clean on `main`.
- Your workstation meets
  [Client workstation prerequisites](reference-implementation.md#client-workstation-prerequisites)
  in the SRI, including
  [Connect gateway](https://docs.cloud.google.com/kubernetes-engine/enterprise/multicluster-management/gateway)
  access to the target cluster. Every `kubectl` command in this guide reaches
  the cluster through the Connect gateway.

### Identity and Access Management

- **Application Operator:** Connect gateway access (`roles/gkehub.gatewayEditor`
  and `roles/gkehub.viewer` on `PROJECT_ID`), namespace RBAC from
  [Identities and roles](reference-implementation.md#identities-and-roles) in
  the SRI (`get` and `list` pods and Services, read pod logs,
  `pods/portforward`, and `pods/exec`), and write access to
  `${GITOPS_OWNER}/${GITOPS_REPO}` to open pull requests and push release tags.
- **Platform Administrator:** permissions to update `FleetPackage` resources in
  `REGION` (`roles/configdelivery.admin`).
- **Both personas:** Monitoring Viewer (`roles/monitoring.viewer`) and Logs
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

<!-- mdformat off -->

| Placeholder                 | Value to set                                                                                                                                                                              |
| :-------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NEW_CHECKPOINT_SOURCE_URI` | Cloud Storage folder URI holding the new merged SFT checkpoint, without a trailing slash (for lab testing with identical weights, use `gs://${BUCKET}/sft-model-serving/checkpoints/v1`). |

<!-- mdformat on -->

- [Workstation] Fetch the cluster credentials through the Connect gateway and
  confirm that `kubectl` targets the solution cluster before you run any
  `kubectl` command in this guide.

```bash
gcloud container fleet memberships get-credentials "${MEMBERSHIP}" --project="${PROJECT_ID}"
kubectl config current-context
kubectl -n "${NAMESPACE}" get pods
```

The output is similar to the following:

```text
connectgateway_PROJECT_ID_global_MEMBERSHIP
NAME                                           READY   STATUS    RESTARTS   AGE
gradio-llama-sft-deployment-6c9f7b8d5d-x2k4p   1/1     Running   0          6m
vllm-llama-sft-deployment-7d8b9c6f4b-q7m2n     1/1     Running   0          6m
```

## Implementation

### Access the model through Gradio

- [Workstation] Open a local port-forward tunnel to the Gradio `ClusterIP`
  `Service` (`8080` → container port `7860`).

```bash
kubectl -n "${NAMESPACE}" port-forward svc/gradio-llama-sft-service 8080:8080
```

- [Workstation] Open `http://localhost:8080` in a browser and verify that the
  page banner reads `You are chatting with: llama-3.1-8b-sft-v1.0.0`.
- [Workstation] Submit the math word problem
  `"Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May?"`
  and confirm that the response ends cleanly with `The answer is: 72`.

<!-- prettier-ignore -->
> [!NOTE]
> Gradio passes release alias `llama-3.1-8b-sft-v1.0.0` in its chat request so
> operators can verify both visually and at the API layer which release answers.
> Gradio has no built-in user authentication; keep it strictly behind
> RBAC-controlled port forwarding.

### Monitor the model

- [Workstation] Confirm that `PodMonitoring/vllm-llama-sft-pod-monitoring`
  reports `ConfigurationCreateSuccess=True`:

```bash
kubectl -n "${NAMESPACE}" get podmonitoring vllm-llama-sft-pod-monitoring \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
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

The returned series carry label `model_name="llama-3.1-8b-sft"` (alongside
`vllm:kv_cache_usage_perc` and request latency histograms).

- [Console] In Cloud Monitoring
  [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer),
  switch to **PromQL** to inspect vLLM token generation rate alongside GPU
  utilization and framebuffer memory occupancy exported by DCGM Exporter:

```text
rate(vllm:generation_tokens_total{model_name="llama-3.1-8b-sft"}[1m])
DCGM_FI_DEV_GPU_UTIL{cluster="CLUSTER_NAME", namespace="DCGM_NAMESPACE"}
DCGM_FI_DEV_FB_USED{cluster="CLUSTER_NAME", namespace="DCGM_NAMESPACE"}
```

Replace the following:

<!-- mdformat off -->

| Placeholder      | Value to set                                                                                                                                |
| :--------------- | :------------------------------------------------------------------------------------------------------------------------------------------ |
| `CLUSTER_NAME`   | Cluster name reported in Managed Service for Prometheus and Cloud Logging (typically `MEMBERSHIP`).                                         |
| `DCGM_NAMESPACE` | Namespace where `PodMonitoring/dcgm-gmp` runs: the `DCGM_NAMESPACE` value in the SRI `.env` file (`gpu-operator` or `nvidia-gpu-operator`). |

<!-- mdformat on -->

- [Workstation] Inspect the vLLM container logs with `kubectl`, and query the
  same logs in Cloud Logging with `gcloud`.

```bash
kubectl -n "${NAMESPACE}" logs deploy/vllm-llama-sft-deployment -c vllm-container --tail=50
gcloud logging read \
    "resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"${NAMESPACE}\" AND resource.labels.container_name=\"vllm-container\"" \
    --project="${PROJECT_ID}" --limit=20 --format="table(timestamp, jsonPayload.log)"
```

- [Console] In the Google Cloud console, open
  [Logs Explorer](https://console.cloud.google.com/logs/query) in project
  `PROJECT_ID`, paste the following query into the query editor, and click **Run
  query**. To see the checkpoint download and cache pruning logs instead, set
  `container_name` to `gcs-model-downloader`.

```text
resource.type="k8s_container"
resource.labels.cluster_name="CLUSTER_NAME"
resource.labels.namespace_name="sft-model-serving"
resource.labels.container_name="vllm-container"
```

You can build the same filter without typing a query: click **Resource**, select
**Kubernetes Container**, then your cluster and the `sft-model-serving`
namespace, and click **Add** and then **Run query**; see
[Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring).

<!-- prettier-ignore -->
> [!WARNING]
> Because `--enable-log-requests` is set on the worked-example vLLM deployment,
> HTTP request metadata appears in container stdout and Cloud Logging at default
> `INFO` level, and full prompt and completion payloads appear if
> `VLLM_LOGGING_LEVEL=DEBUG` is enabled. Remove `--enable-log-requests` through
> a GitOps release before serving sensitive or regulated prompts.

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

| File                                        | Field                                                             | `v1.0.0` value                                                       | `v2.0.0` value                                                       |
| :------------------------------------------ | :---------------------------------------------------------------- | :------------------------------------------------------------------- | :------------------------------------------------------------------- |
| `src/base/vllm-llama-sft-deployment.yaml`   | `ai.gke.io/model-version` label (Deployment and pod template)     | `v1`                                                                 | `v2`                                                                 |
| `src/base/vllm-llama-sft-deployment.yaml`   | `MODEL_VERSION` env (`gcs-model-downloader` and `vllm-container`) | `v1`                                                                 | `v2`                                                                 |
| `src/base/vllm-llama-sft-deployment.yaml`   | `MODEL_GCS_URI` env (`gcs-model-downloader`)                      | `gs://BUCKET/sft-model-serving/checkpoints/v1`                       | `gs://BUCKET/sft-model-serving/checkpoints/v2`                       |
| `src/base/vllm-llama-sft-deployment.yaml`   | `--served-model-name` aliases                                     | `llama-3.1-8b-sft`, `llama-3.1-8b-sft-v1.0.0`, `llama-3.1-8b-sft-v1` | `llama-3.1-8b-sft`, `llama-3.1-8b-sft-v2.0.0`, `llama-3.1-8b-sft-v2` |
| `src/base/gradio-llama-sft-deployment.yaml` | `MODEL_ID` env                                                    | `llama-3.1-8b-sft-v1.0.0`                                            | `llama-3.1-8b-sft-v2.0.0`                                            |
| `fleetpackage.yaml`                         | `tag`                                                             | `v1.0.0`                                                             | `v2.0.0`                                                             |

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

Confirm that the script prints `No v1 values left.` and writes
`environments/default/manifests.yaml`.

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

### Verify the upgrade to v2.0.0

Verify the upgrade before you roll back. Measured upgrade and rollback behavior
on the validation cluster running `vllm/vllm-openai:v0.32.0` (timings vary with
network bandwidth and GPU node storage):

- Managed Cloud Build OCI packaging completed in roughly 2 minutes (`115–127`
  seconds) with zero serving downtime while cluster traffic continued normally.
- Total time from `FleetPackage` update to a serving `/v1/models` HTTP `200`
  response was 5 minutes `47–49` seconds (`7` minutes `39` seconds to
  `Rollout COMPLETED`), with `3` minutes `11–13` seconds without serving under
  `strategy: Recreate` (dominated by `vllm:v0.32.0` V1 engine and CUDA graph
  initialization inside the `120`-second readiness initial delay).
- The `initContainer` downloaded `14.97 GiB` via keyless Fleet Workload Identity
  at `922–952 MiB/s` and pruned the superseded cache directory in 21 seconds
  total.

- [Workstation] Wait until the newest rollout, for release `v2-0-0`, reports
  state `COMPLETED`.

```bash
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}" \
    --sort-by=~createTime --limit=2
```

- [Workstation] Confirm that the replacement vLLM pod is `Running` and `Ready`
  and runs model version `v2`.

```bash
kubectl -n "${NAMESPACE}" get pods -l app=vllm-llama-sft -L ai.gke.io/model-version
```

The pod shows `1/1` in the `READY` column and `v2` in the `MODEL-VERSION`
column.

- [Workstation] Inspect the `gcs-model-downloader` logs to confirm that the pod
  downloaded checkpoint `v2` with keyless credentials and pruned `v1` from the
  cache.

```bash
kubectl -n "${NAMESPACE}" logs deploy/vllm-llama-sft-deployment -c gcs-model-downloader
```

The output is similar to the following:

```text
Checking the cache for model version 'v2'...
Active account: GSA_NAME@PROJECT_ID.iam.gserviceaccount.com
Downloading gs://BUCKET/sft-model-serving/checkpoints/v2 with fleet Workload Identity credentials...
Checking the required files for model version 'v2'...
Deleting other model versions from the cache...
Removing /model-cache/llama-3.1-8b-sft/v1
Model version 'v2' sync and cache maintenance complete.
```

- [Workstation] Confirm that `/v1/models` lists the `v2.0.0` aliases, and run
  the math smoke test.

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

The output is similar to the following:

```text
llama-3.1-8b-sft
llama-3.1-8b-sft-v2.0.0
llama-3.1-8b-sft-v2
The answer is: 72
```

- [Workstation] Restart the Gradio port-forward (see
  [Access the model through Gradio](#access-the-model-through-gradio)), reload
  `http://localhost:8080`, and verify that the banner reads
  `You are chatting with: llama-3.1-8b-sft-v2.0.0`.

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

Confirm that the script prints `No v2 values left.` and writes
`environments/default/manifests.yaml`.

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

<!-- prettier-ignore -->
> [!NOTE]
> Re-pointing `FleetPackage` directly back to `tag: v1.0.0` also redeploys
> checkpoint `v1` while `gs://BUCKET/sft-model-serving/checkpoints/v1` exists;
> forward releases are preferred so the active deployment always matches `HEAD`
> on `main`.

### Verify the rollback to v2.0.1

The rollback takes about as long as the upgrade (5 minutes `49` seconds to a
serving `/v1/models` response on the validation cluster): because `v2.0.0`
pruned `v1` from the local PVC cache, the `initContainer` downloads checkpoint
`v1` again.

- [Workstation] Wait until the newest rollout, for release `v2-0-1`, reports
  state `COMPLETED`.

```bash
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}" \
    --sort-by=~createTime --limit=2
```

- [Workstation] Confirm that the replacement vLLM pod is `Running` and `Ready`
  and runs model version `v1` again.

```bash
kubectl -n "${NAMESPACE}" get pods -l app=vllm-llama-sft -L ai.gke.io/model-version
```

The pod shows `1/1` in the `READY` column and `v1` in the `MODEL-VERSION`
column.

- [Workstation] Inspect the `gcs-model-downloader` logs to confirm that the pod
  downloaded checkpoint `v1` again and pruned `v2` from the cache.

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
Removing /model-cache/llama-3.1-8b-sft/v2
Model version 'v1' sync and cache maintenance complete.
```

- [Workstation] Confirm that `/v1/models` lists the `v2.0.1` aliases, and run
  the math smoke test.

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

The output is similar to the following:

```text
llama-3.1-8b-sft
llama-3.1-8b-sft-v2.0.1
llama-3.1-8b-sft-v1
The answer is: 72
```

- [Workstation] Restart the Gradio port-forward (see
  [Access the model through Gradio](#access-the-model-through-gradio)), reload
  `http://localhost:8080`, and verify that the banner reads
  `You are chatting with: llama-3.1-8b-sft-v2.0.1`.

## Operations

- **Subsequent promotions and image updates:** Advance model checkpoints (`v3` /
  `v3.0.0`) or pinned container tags in `src/base/` inside maintenance windows
  (`strategy: Recreate`), retaining prior Cloud Storage checkpoint prefixes for
  rollback and validating the first cluster wave (`maxConcurrent: 1`).
- **Aborting a stalled rollout:** If a rollout stalls, remediate the root cause
  first, then abort the stalled rollout so Config Delivery unblocks subsequent
  releases:

```bash
gcloud container fleet packages rollouts abort ROLLOUT_ID \
    --fleet-package="${FLEET_PACKAGE}" --location="${REGION}" --project="${PROJECT_ID}"
```

Replace the following:

<!-- mdformat off -->

| Placeholder  | Value to set                                                                                   |
| :----------- | :--------------------------------------------------------------------------------------------- |
| `ROLLOUT_ID` | Identifier of the stalled rollout returned by `gcloud container fleet packages rollouts list`. |

<!-- mdformat on -->

## Troubleshooting

<!-- mdformat off -->

| Symptom                                                    | Cause                                                                                                                               | Resolution                                                                                                                                                                                                                                                                                                                                                      |
| :--------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New release rollout doesn't start                          | SemVer tag wasn't pushed to `origin`, or `FleetPackage` wasn't updated                                                              | Verify `git ls-remote --tags origin` and re-run `gcloud container fleet packages update`                                                                                                                                                                                                                                                                        |
| Rollout enters `STALLED` state                             | Cluster RBAC or reconciliation failure on the active cluster                                                                        | Fix the underlying error, then run `rollouts abort` (see [Operations](#operations))                                                                                                                                                                                                                                                                             |
| Rollback `initContainer` fails on missing checkpoint files | Prior version prefix (`checkpoints/v1`) was deleted from Cloud Storage                                                              | Restore the checkpoint files in Cloud Storage or roll forward to an intact checkpoint prefix                                                                                                                                                                                                                                                                    |
| `kubectl port-forward` disconnects during rollout          | `strategy: Recreate` terminated the previous pod                                                                                    | Restart `kubectl port-forward` once the replacement pod reaches `1/1 Running`                                                                                                                                                                                                                                                                                   |
| Gradio banner displays prior `MODEL_ID` version            | Browser cache or pending Gradio pod rollout                                                                                         | Refresh browser cache and check `kubectl -n "${NAMESPACE}" get pods`                                                                                                                                                                                                                                                                                            |
| Non-math prompts produce math derivations                  | Worked-example checkpoint is fine-tuned on MetaMathQA                                                                               | Validate the worked example with math word problems                                                                                                                                                                                                                                                                                                             |
| Missing vLLM or GPU metrics in Cloud Monitoring            | `enableGMPForApplications`, `PodMonitoring/vllm-llama-sft-pod-monitoring`, `PodMonitoring/dcgm-gmp`, or DCGM Exporter isn't enabled | Verify `PodMonitoring` conditions and see [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring) and [Send GPU metrics to Cloud Monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/gpu-metrics) |
| Missing container logs in Cloud Logging                    | Cluster application log forwarding isn't enabled                                                                                    | Enable application logging per [Enable application logging and monitoring](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/how-to/application-logging-monitoring)                                                                                                                                                             |

<!-- mdformat on -->

## Clean up

To tear down the entire cluster deployment and Google Cloud resources after
removing the day-2 artifacts below, run
[Clean up](reference-implementation.md#clean-up) in the SRI.

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

- [Solution Reference Architecture (SRA)](../README.md): architecture, sizing,
  and design decisions
- [Solution Reference Implementation (SRI)](reference-implementation.md):
  step-by-step deployment, verification, and clean up of release `v1.0.0`
