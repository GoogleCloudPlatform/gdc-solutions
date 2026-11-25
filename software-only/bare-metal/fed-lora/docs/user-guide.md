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

# Federated Learning for Edge AI on Distributed Cloud software only user guide

## Overview

This user guide builds on the platform baseline deployed by the
[Solution Reference Implementation (SRI)](reference-implementation.md). It
covers building and staging the Flower App Bundle (`.fab`), running Stage-2
local SFT warm-start, seeding the Round-0 PEFT template, and executing single-
and multi-round federated training. It also covers canary consensus promotion,
four-quadrant monitoring, `.fab` and `FleetPackage` upgrades, per-store data
refreshes, store onboarding, and GPU cost control. While validated with
`google/gemma-4-E2B-it` text question answering, these workflows apply to
open-weight LoRA workloads of any modality. For topology, GPU memory sizing,
security boundaries, and design trade-offs, see **Architecture and design** in
the
[Solution Reference Architecture (SRA)](../README.md#architecture-and-design).

## Before you begin

- Complete and verify the platform exit gate in
  [Verification](reference-implementation.md#verification) of the SRI. Keep
  `${SOLUTION_HOME}/.env` on your workstation.
- Confirm your private GitHub repository copy
  (`${SOLUTION_HOME}/${GITHUB_REPO}`) is linked in `us-central1` and reconciled
  by active `FleetPackage` releases (`${PACKAGE_RELEASE}`).
- Install `gcloud`, `kubectl`, `flwr` (`1.36.0`), `python3`, `jq`, and `git` on
  your workstation.

### Identity and Access Management

- **Application Operator (MLOps):** Kubernetes `edit` permissions in
  `fed-lora-poc` and `fed-lora-aggregator`, `roles/gkehub.gatewayEditor` for
  Connect Gateway access, and `roles/storage.objectUser` on
  `gs://${GCS_BUCKET}`.
- **Platform Administrator:** `roles/configdelivery.admin`,
  `roles/gkehub.editor`, and `roles/compute.instanceAdmin.v1` to update
  `FleetPackage` tags, label store memberships, and stop or start edge host
  nodes.
- **Observability Operator:** `roles/monitoring.dashboardEditor` to create or
  update the Cloud Monitoring dashboard, plus `roles/monitoring.viewer` and
  `roles/logging.viewer` for PromQL and log queries.

### Workstation

- [Workstation] Load `${SOLUTION_HOME}/.env` from
  [Set up workstation tools and reference configuration](reference-implementation.md#set-up-workstation-tools-and-reference-configuration)
  in the SRI. Create `${SOLUTION_HOME}/sug.env` with example defaults and source
  it.

```bash
SOLUTION_HOME="${SOLUTION_HOME:-$HOME/fed-lora-work}"
set -a
source "${SOLUTION_HOME}/.env"
set +a

cat << 'EOF' > "${SOLUTION_HOME}/sug.env"
# Inherited SRI baseline defaults (preserved when already set in .env)
PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-b}"
STORE_1_MEMBERSHIP="${STORE_1_MEMBERSHIP:-${STORE1_CLUSTER_NAME:-edge-store-1}}"
STORE_2_MEMBERSHIP="${STORE_2_MEMBERSHIP:-${STORE2_CLUSTER_NAME:-edge-store-2}}"
CENTRAL_CLUSTER_NAME="${CENTRAL_CLUSTER_NAME:-${GKE_CLUSTER_NAME:-central-fl-aggregator}}"
CENTRAL_MEMBERSHIP="${CENTRAL_MEMBERSHIP:-${CENTRAL_CLUSTER_NAME}}"
EDGE_NAMESPACE="${EDGE_NAMESPACE:-fed-lora-poc}"
CENTRAL_NAMESPACE="${CENTRAL_NAMESPACE:-fed-lora-aggregator}"
GCS_BUCKET="${GCS_BUCKET:-YOUR_GCS_BUCKET}"
GCS_BUCKET_URI="${GCS_BUCKET_URI:-gs://${GCS_BUCKET}}"
SUPERLINK_ILB_IP="${SUPERLINK_ILB_IP:-${FLWR_SERVER_INTERNAL_LB_IP:-10.100.0.50}}"
STORE_CIDR="${STORE_CIDR:-${SUBNET_CIDR:-10.100.0.0/24}}"
STORE1_VLLM_LB_IP="${STORE1_VLLM_LB_IP:-10.100.0.131}"
STORE2_VLLM_LB_IP="${STORE2_VLLM_LB_IP:-10.100.0.163}"
BASE_MODEL_ID="${BASE_MODEL_ID:-google/gemma-4-E2B-it}"
GITHUB_REPO="${GITHUB_REPO:-fed-lora-gitops}"
SEED_SUBDIR="${SEED_SUBDIR:-software-only/bare-metal/fed-lora}"
CB_CONNECTION="${CB_CONNECTION:-fed-lora-github-conn}"
CB_REPOSITORY="${CB_REPOSITORY:-${CB_REPO_LINK:-fed-lora-gitops-link}}"
PUBLISHER_SA_NAME="${PUBLISHER_SA_NAME:-${FLEET_PACKAGE_PUBLISHER_SA:-fl-pkg-publisher}}"
PACKAGE_RELEASE="${PACKAGE_RELEASE:-YOUR_BASE_RELEASE_TAG}"

# Helper-script environment bridge (config/fed_lora_env.sh)
STORE1_CONTEXT="store-1-ctx"
STORE2_CONTEXT="store-2-ctx"
GKE_CONTEXT="central-ctx"
GKE_CLUSTER_NAME="${CENTRAL_CLUSTER_NAME}"
VPC_NAME="${VPC_NAME:-default}"
SUBNET_NAME="${SUBNET_NAME:-default}"

# Example Day-2 operational defaults (lab-validated; tune for your dataset and fleet)
NUM_ROUNDS="3"
LOCAL_EPOCHS="2"
FLEET_PACKAGE_EDGE="${FLEET_PACKAGE_EDGE:-fed-lora-edge-package}"
FLEET_PACKAGE_CENTRAL="${FLEET_PACKAGE_CENTRAL:-fed-lora-central-package}"
NEW_RELEASE_TAG="YOUR_NEW_RELEASE_TAG"
ROLLBACK_RELEASE_TAG="YOUR_ROLLBACK_RELEASE_TAG"
NEW_STORE_ID="3"
NEW_STORE_MEMBERSHIP="edge-store-3"
NEW_STORE_VLLM_IP="10.100.0.195"
EOF

set -a
source "${SOLUTION_HOME}/sug.env"
set +a
if [[ -d "${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}" ]]; then
  GITOPS_REPO_DIR="${SOLUTION_HOME}/${GITHUB_REPO}/${SEED_SUBDIR}"
else
  GITOPS_REPO_DIR="${SOLUTION_HOME}/${GITHUB_REPO}"
fi
if [[ -d "${GITOPS_REPO_DIR}/config" ]]; then
  cat "${SOLUTION_HOME}/.env" "${SOLUTION_HOME}/sug.env" > "${GITOPS_REPO_DIR}/config/.env"
  chmod 600 "${GITOPS_REPO_DIR}/config/.env"
fi
```

Replace the following if they are not already set in `${SOLUTION_HOME}/.env`:

- `PROJECT_ID`: Google Cloud project ID hosting Fleet memberships, Cloud
  Storage, and the GKE aggregator.
- `GCS_BUCKET`: Regional Cloud Storage bucket name storing federated round
  checkpoints, canary receipts, and promoted adapters.
- `STORE1_VLLM_LB_IP`: Internal MetalLB IP address exposing `vllm-service`
  (`:8000`) on store 1.
- `STORE2_VLLM_LB_IP`: Internal MetalLB IP address exposing `vllm-service`
  (`:8000`) on store 2.
- `SUPERLINK_ILB_IP`: Internal LoadBalancer IP address exposing
  `flwr-superlink-service` (`:9092`) on the central GKE cluster.
- `PACKAGE_RELEASE`: Active SemVer Git tag currently deployed by the SRI
  `FleetPackage` (for example, `vX.Y.Z`).
- `NEW_RELEASE_TAG`: Next SemVer Git tag published for a manifest upgrade (for
  example, `vX.Y.(Z+1)`).
- `ROLLBACK_RELEASE_TAG`: Forward SemVer Git tag published to revert a manifest
  change while keeping tag history linear (for example, `vX.Y.(Z+2)`).
- `NEW_STORE_MEMBERSHIP`: Global Fleet membership name when onboarding an
  additional edge store cluster.
- `NEW_STORE_VLLM_IP`: Reserved MetalLB service IP address for `vllm-service` on
  the new store cluster.

- [Workstation] Acquire and verify kubeconfig contexts (`store-1-ctx`,
  `store-2-ctx`, and `central-ctx`) for both stores and the central aggregator.

```bash
gcloud container fleet memberships get-credentials "${STORE_1_MEMBERSHIP}" \
    --project="${PROJECT_ID}" --location=global
kubectl config rename-context "connectgateway_${PROJECT_ID}_global_${STORE_1_MEMBERSHIP}" store-1-ctx 2>/dev/null || true

gcloud container fleet memberships get-credentials "${STORE_2_MEMBERSHIP}" \
    --project="${PROJECT_ID}" --location=global
kubectl config rename-context "connectgateway_${PROJECT_ID}_global_${STORE_2_MEMBERSHIP}" store-2-ctx 2>/dev/null || true

gcloud container clusters get-credentials "${CENTRAL_CLUSTER_NAME}" \
    --project="${PROJECT_ID}" --zone="${ZONE}"
kubectl config rename-context "gke_${PROJECT_ID}_${ZONE}_${CENTRAL_CLUSTER_NAME}" central-ctx 2>/dev/null || true
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [GKE Fleet](https://console.cloud.google.com/kubernetes/fleet): Both store
  clusters and the central aggregator cluster show `READY` memberships.
- [Config Sync](https://console.cloud.google.com/kubernetes/config_management/packages):
  Both `FleetPackage` deployments show `SYNCED` status with `0` errors.

## Implementation

### Example Flower app and algorithm parameters

The Flower application (`apps/fed-lora`) ships with lab-validated example
defaults that you may tune for your data. For vLLM, pod sizing, and GPU
time-slicing defaults, see
[Example platform runtime parameters](reference-implementation.md#example-platform-runtime-parameters)
in the SRI.

<!-- mdformat off -->

| Area                                 | Package file(s)                                                                                         | Example values (lab-validated defaults, tune for your data)                                                                                                                                                                                                                                                                                                                                                                                                      | Role                                                                                              |
| :----------------------------------- | :------------------------------------------------------------------------------------------------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| **Frozen-A LoRA (`FFA-LoRA`)**       | `apps/fed-lora/pyproject.toml`, `apps/fed-lora/clientapp.py`                                            | `seed=42` (`lora_A` frozen), `lora-r=16`, `lora-alpha=64`, `lora-dropout=0.1` on `o_proj` and `down_proj` (`~6.6 MB` `lora_B` upload/round)                                                                                                                                                                                                                                                                                                                      | Shared Round-0 projection basis and trainable `lora_B` rank/scaling on `google/gemma-4-E2B-it`    |
| **Siloed local SFT warm-start**      | `apps/fed-lora/run_config_local_sft.toml`                                                               | `mode="local-sft"`, `min-clients=2`, `local-epochs=6`, `learning-rate=0.001`, `weight-decay=0.01`, `kl-coef=0.1`, `kl-alpha=0.0`, `kl-temperature=2.0`, `proximal-mu=0.0`, `target-loss=0.05`                                                                                                                                                                                                                                                                    | Per-store warm-start fine-tuning on local `train.jsonl` with zero off-cluster parameter transfer  |
| **Federated round & subspace merge** | `apps/fed-lora/run_config_federated.toml`; multi-round overrides in `scripts/run_multiround_fl_demo.sh` | `mode="federated"`, `min-clients=2` (`pyproject.toml`), `num-server-rounds=1` (`3` in multi-round script), `local-epochs=4` (`2` in multi-round script), `learning-rate=0.0002`, `kl-coef=0.2`, `kl-alpha=0.5`, `kl-temperature=2.0`, `proximal-mu=0.1` (`0.35` in multi-round script), `aggregation-mode="subspace_resid"` (`"ties"` built-in default in `pyproject.toml`), `residual-gamma=0.85`, `round2-gamma=0.56`, `trim-quantile=0.2`, `ties-density=0.8` | KL-proximal local anchoring plus TIES pruning and SVD cross-subspace residual projection          |
| **Canary consensus gate**            | `apps/fed-lora/pyproject.toml`, `apps/fed-lora/clientapp.py`                                            | `canary-gate=true`, `canary-fact-min=1.0`, `canary-safety-min=1.0`, `require-global-consensus=true` (for example, `14` evaluation probes across categories C1–C6 per store in the sample suite)                                                                                                                                                                                                                                                                  | Store-local base-model judge thresholds required across all participating stores before `PROMOTE` |

<!-- mdformat on -->

### Build and stage the Flower App Bundle

Flower decouples application code (`ServerApp` in `serverapp.py` and `ClientApp`
in `clientapp.py` under `apps/fed-lora`) from container images through a signed
Flower App Bundle (`.fab`). Stage `apps/fed-lora` outside the Git tree so `.fab`
build outputs never dirty GitOps commits.

- [Workstation] Build the `.fab` bundle, open a local port-forward to
  `flwr-superlink-service:9093` (`ControlAPI`), configure `~/.flwr/config.toml`,
  and confirm both store `SuperNode` daemons are online.

```bash
FAB_STAGE_DIR="${SOLUTION_HOME}/fab-stage"
rm -rf "${FAB_STAGE_DIR}"
mkdir -p "${FAB_STAGE_DIR}"
cp -R "${GITOPS_REPO_DIR}/apps/fed-lora" "${FAB_STAGE_DIR}/fed-lora"

(
  cd "${FAB_STAGE_DIR}/fed-lora"
  flwr build
  FAB_FILE="$(find . -maxdepth 1 -name '*.fab' | head -n 1)"
  sha256sum "${FAB_FILE}"
)

if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/19093" 2>/dev/null; then
  kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
      port-forward svc/flwr-superlink-service 19093:9093 \
      >"${SOLUTION_HOME}/superlink-pf.log" 2>&1 &
  echo $! > "${SOLUTION_HOME}/superlink-pf.pid"
  sleep 3
fi

mkdir -p "${HOME}/.flwr"
cat <<'EOF' > "${HOME}/.flwr/config.toml"
[superlink]
default = "gke-superlink"

[superlink.gke-superlink]
address = "127.0.0.1:19093"
insecure = true
EOF

flwr config list
flwr supernode list gke-superlink
flwr ls gke-superlink
```

Confirm `flwr build` emits a `.fab` archive with a SHA-256 digest. Verify
`flwr supernode list gke-superlink` lists both store `SuperNode` entries as
`online` and `flwr ls gke-superlink` queries `127.0.0.1:19093` without errors.

<!-- prettier-ignore -->
> [!NOTE]
> Idle `kubectl port-forward` tunnels time out after ~20 minutes with a
> port-forward timeout error; re-run the port-forward check above whenever
> `127.0.0.1:19093` closes between runs.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [GKE Workloads](https://console.cloud.google.com/kubernetes/workload/overview):
  Confirm `flwr-superlink` in `fed-lora-aggregator` and `vllm-gemma4`,
  `flwr-supernode`, and `flwr-trainer` in `fed-lora-poc` show `OK`.

### Warm-start store adapters and stage the Round-0 PEFT template

Cold-starting federation from zeroed `lora_B` tensors over a short budget (for
example, `use-pretrained-local=false` with `local-epochs=2`) does not converge
to clear the canary gate. Because `FedLoRAClient` uses lazy initialization
(`lazy_model_init=True`),
`/mnt/models/round0-seed-cache/{adapter_model.safetensors,adapter_config.json}`
is materialized on the store PVC during the first `fit()` call.

Dispatch siloed local SFT via `run_config_local_sft.toml`
(`NoOpAggregationStrategy`, zero off-cluster parameter transfer) using the
example defaults in
[Example Flower app and algorithm parameters](#example-flower-app-and-algorithm-parameters).
This trains `/mnt/models/store{1,2}-local-adapter` and populates
`/mnt/models/round0-seed-cache/`. Next, copy the deterministic Round-0 template
(example `seed=42`, `lora-r=16`, `lora-alpha=64` on `o_proj` and `down_proj`)
once (~`44 s`) from store 1 to `gs://${GCS_BUCKET}/checkpoints/round-0/`.

<!-- prettier-ignore -->
> [!NOTE]
> Flower `1.36.0` accepts either a `.toml` file or inline `key=value` pairs on
> `--run-config` (never both); adjust the example `min-clients` value in
> `run_config_local_sft.toml` to match your online store count before running.

<!-- prettier-ignore -->
> [!CAUTION]
> Warm-start convergence is sensitive to `learning-rate` on small store
> datasets; nearby rates missed a probe or failed local canaries in lab
> calibration. Re-tune `local-epochs` and `learning-rate` for new datasets. Keep
> `kl-coef` at `0.1` or higher, and avoid `target-loss` at `0.30` or higher with
> long schedules because early stopping can truncate training.

- [Workstation] Run the Stage-2 local SFT warm-start and upload the materialized
  Round-0 PEFT template to Cloud Storage.

```bash
(
  cd "${SOLUTION_HOME}/fab-stage/fed-lora"
  flwr run . gke-superlink --run-config run_config_local_sft.toml --stream
)

TRAINER_POD="$(kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" get pods \
    -l app=flwr-trainer --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')"

mkdir -p "${SOLUTION_HOME}/round0-seed"
for seed_file in adapter_model.safetensors adapter_config.json; do
  kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" cp \
      "${TRAINER_POD}:/mnt/models/round0-seed-cache/${seed_file}" \
      "${SOLUTION_HOME}/round0-seed/${seed_file}" \
      -c flwr-trainer
  gcloud storage cp "${SOLUTION_HOME}/round0-seed/${seed_file}" \
      "gs://${GCS_BUCKET}/checkpoints/round-0/${seed_file}" \
      --project="${PROJECT_ID}"
done

gcloud storage ls -l \
    "gs://${GCS_BUCKET}/checkpoints/round-0/adapter_model.safetensors" \
    "gs://${GCS_BUCKET}/checkpoints/round-0/adapter_config.json" \
    --project="${PROJECT_ID}"
```

Confirm the local SFT warm-start (~~`72 s` lab example) logs `canary_pass=1` on
both stores with `store1-local-adapter` and `store2-local-adapter` loaded on
`/v1/models`. Confirm `gcloud storage ls -l` lists `adapter_model.safetensors`
(~~`32.5 MiB`) and `adapter_config.json` under
`gs://${GCS_BUCKET}/checkpoints/round-0/`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Storage Buckets](https://console.cloud.google.com/storage/browser):
  Open `${GCS_BUCKET}` and verify
  `checkpoints/round-0/adapter_model.safetensors` and
  `checkpoints/round-0/adapter_config.json` exist with zero `.jsonl` files.

### Execute the first federated round and verify the verdict

Dispatch a single-round federated run warm-started from the store adapters. Tune
the example `--run-config` values in
[Example Flower app and algorithm parameters](#example-flower-app-and-algorithm-parameters)
for your dataset and fleet.

- [Workstation] Stream a single-round federated fine-tuning run from
  `${SOLUTION_HOME}/fab-stage/fed-lora`.

```bash
(
  cd "${SOLUTION_HOME}/fab-stage/fed-lora"
  flwr run . gke-superlink \
      --run-config "mode=\"federated\" gcs-bucket=\"${GCS_BUCKET_URI}\" global-adapter-gcs-prefix=\"gs://${GCS_BUCKET}/adapters/global/v1.0-federated\" num-server-rounds=1 local-epochs=2 aggregation-mode=\"subspace_resid\" residual-gamma=0.85 canary-gate=true use-pretrained-local=true" \
      --stream
)
```

Verify the expected federated verdict across all three planes:

1. **Zero-eviction GPU sleep-wake arbitration:** During `ClientApp.fit()`,
   `vllm-gemma4` enters Level-1 sleep while `flwr-trainer` runs 4-bit NF4 QLoRA
   (`KLProxTrainer`), then wakes with zero restarts.
2. **Subspace merge and canary promotion:** `ServerApp` merges `lora_B` via
   `SubspaceLoRAStrategy` (example `residual-gamma=0.85`), confirms all canary
   probes pass on every store, and writes `PROMOTE` to `checkpoints/round-1/`
   and `checkpoints/promoted/`.
3. **Runtime LoRA hot-swap:** Both store `vllm-gemma4` servers register the
   promoted federated adapter on `/v1/models` without restarting.

- [Workstation] Verify Cloud Storage checkpoint promotion, zero `vllm-gemma4`
  restarts, and live adapter registration on both stores.

```bash
gcloud storage ls \
    "gs://${GCS_BUCKET}/checkpoints/round-1/" \
    "gs://${GCS_BUCKET}/adapters/global/v1.0-federated/" \
    --project="${PROJECT_ID}"

for ctx in store-1-ctx store-2-ctx; do
  restarts="$(kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" get pods \
      -l app=vllm-serving --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"
  echo "${ctx} vllm-gemma4 restarts=${restarts}"
  test "${restarts}" = "0"
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
      curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/models" \
      | jq -r '.data[].id'
done
```

Confirm `checkpoints/round-1/` and `adapters/global/v1.0-federated/` contain
`adapter_model.safetensors` and `consensus_verdict.json`. Verify `restarts=0` on
both stores and `/v1/models` lists `google/gemma-4-E2B-it`, the store-local
adapter, and `store-fed-lora-promoted`. In lab calibration after a fresh-install
two-store warm-start, all canary probes passed on both stores (`PROMOTE`).

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Storage Buckets](https://console.cloud.google.com/storage/browser):
  Open `${GCS_BUCKET}` and verify `checkpoints/round-1/`,
  `checkpoints/promoted/`, and `adapters/global/v1.0-federated/` hold
  `adapter_model.safetensors` and `consensus_verdict.json`.
- [GKE Workloads](https://console.cloud.google.com/kubernetes/workload/overview):
  Confirm `vllm-gemma4` remains `OK` with `0` restarts on both store clusters.

### Run a multi-round federation and read the verdict

Multi-round training keeps raw store records on each node's local
`ReadWriteOnce` volume (`PersistentVolumeClaim/shared-model-pvc`). All
hyperparameters below are lab-validated example defaults listed in
[Example Flower app and algorithm parameters](#example-flower-app-and-algorithm-parameters):

- **Zero-GPU seed and sleep-wake handoff:** Round 0 seeds zeroed `lora_B` and
  frozen `lora_A` (example `lora-r=16`, `lora-alpha=64`) in under `1 ms`.
  `vllm-gemma4` sleeps in ~`3.1 s` during `KLProxTrainer` QLoRA (example
  `proximal-mu=0.35`, `kl-temperature=2.0`, `kl-alpha=0.5`) and wakes in
  ~`0.4 s`.
- **Subspace residual merge:** Stores upload only trainable `lora_B` tensors
  (~`6.57 MB` per store at `lora-r=16`). Round 1 runs thin-SVD projection
  (`subspace_resid`, example `residual-gamma=0.85`); Rounds 2+ merge per-round
  deltas (example `round2-gamma=0.56`).
- **Canary consensus gate:** Every store evaluates the candidate adapter against
  its local canary regression and abstention suite. `ServerApp` then records
  `PROMOTE` or `REJECT` in `consensus_verdict.json`.

<!-- prettier-ignore -->
> [!IMPORTANT]
> Complete [Warm-start store adapters and stage the Round-0 PEFT
> template](#warm-start-store-adapters-and-stage-the-round-0-peft-template)
> before multi-round federation. The guard below re-runs
> `run_config_local_sft.toml` only if `/mnt/models/store{1,2}-local-adapter` was
> purged (`flwr run` accepts either a `.toml` file or inline `key=value` pairs,
> never both).

- [Workstation] Confirm online `SuperNode` instances via
  `flwr supernode list gke-superlink` and run the example 3-round federation
  (~`2.6 minutes` `ServerApp` runtime; or run
  `${GITOPS_REPO_DIR}/scripts/run_multiround_fl_demo.sh --rounds 3`).

```bash
flwr supernode list gke-superlink

FAB_STAGE_DIR="${SOLUTION_HOME}/fab-stage"
rm -rf "${FAB_STAGE_DIR}"
mkdir -p "${FAB_STAGE_DIR}"
cp -R "${GITOPS_REPO_DIR}/apps/fed-lora" "${FAB_STAGE_DIR}/fed-lora"

# Re-run Stage-2 local-sft warm start only if store-local adapters were purged
if ! kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    test -f /mnt/models/store1-local-adapter/adapter_model.safetensors || \
   ! kubectl --context=store-2-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    test -f /mnt/models/store2-local-adapter/adapter_model.safetensors; then
  (
    cd "${FAB_STAGE_DIR}/fed-lora"
    flwr run . gke-superlink --run-config run_config_local_sft.toml --stream
  )
fi

# Example lab-validated defaults (tune hyperparameters and min-clients for your data and fleet)
RUN_CONFIG="mode=\"federated\" use-pretrained-local=true num-server-rounds=${NUM_ROUNDS} local-epochs=${LOCAL_EPOCHS} aggregation-mode=\"subspace_resid\" residual-gamma=0.85 round2-gamma=0.56 proximal-mu=0.35 kl-temperature=2.0 kl-alpha=0.5 gcs-bucket=\"${GCS_BUCKET_URI}\" global-adapter-gcs-prefix=\"${GCS_BUCKET_URI}/adapters/global/v1.0-federated\""

(
  cd "${FAB_STAGE_DIR}/fed-lora"
  flwr build
  rm -f ./*.fab
  flwr run . gke-superlink --run-config "${RUN_CONFIG}" --stream
)
```

- [Workstation] Inspect `consensus_verdict.json` and per-round `metadata.json`
  in Cloud Storage to confirm unanimous promotion and convergence.

```bash
gcloud storage cat "${GCS_BUCKET_URI}/checkpoints/round-${NUM_ROUNDS}/consensus_verdict.json" \
    --project="${PROJECT_ID}" \
    | jq '{flwr_run_id, round, verdict, all_passed, stores_passed, stores_rejected}'

for r in $(seq 1 "${NUM_ROUNDS}"); do
  gcloud storage cat "${GCS_BUCKET_URI}/checkpoints/round-${r}/metadata.json" \
      --project="${PROJECT_ID}" \
      | jq -c '{round, status, canary_verdict, weighted_train_loss, merged_frobenius_norm}'
done
```

In lab calibration, the documented 3-round path achieved reproducible `PROMOTE`
verdicts across every round on both stores. Round 1 reports `ce_only` warm-start
loss (`0.471645`), while Rounds 2–3 report monotonically decreasing
`kl_prox_total` loss (`3.864664 -> 3.824579`) with `||B_merged||_F` near `20.0`.
Example output from a validated 3-round run (`2476646420506729564`, ~`195 s`,
all canary probes passed on both stores):

```text
{
  "flwr_run_id": "2476646420506729564",
  "round": 3,
  "verdict": "PROMOTE",
  "all_passed": true,
  "stores_passed": ["1", "2"],
  "stores_rejected": []
}
{"round":1,"status":"promoted","canary_verdict":"PROMOTE","weighted_train_loss":0.471645,"merged_frobenius_norm":20.012242309809753}
{"round":2,"status":"promoted","canary_verdict":"PROMOTE","weighted_train_loss":3.864664,"merged_frobenius_norm":20.007251594001144}
{"round":3,"status":"promoted","canary_verdict":"PROMOTE","weighted_train_loss":3.824579,"merged_frobenius_norm":20.002887157345505}
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Storage Buckets](https://console.cloud.google.com/storage/browser):
  Open `${GCS_BUCKET}/checkpoints/` and confirm `round-1/` through `round-3/`
  each contain `consensus_verdict.json` and `metadata.json`.

### Monitor federated rounds and GPU sleep-wake cycles

Google Cloud Managed Service for Prometheus scrapes four `PodMonitoring` targets
deployed by the SRI: `vllm-gemma4` (`:8000`), NVIDIA DCGM Exporter (`:9400`),
`flwr-trainer` (`:9100`), and `flwr-superlink` (`:9100`).

- [Workstation] Verify or update the four-quadrant Cloud Monitoring dashboard
  from `config/monitoring/fed-lora-demo-dashboard.json` and confirm active
  `PodMonitoring` resources.

```bash
"${GITOPS_REPO_DIR}/scripts/deploy_demo_dashboard.sh" --project="${PROJECT_ID}"
kubectl --context=store-1-ctx get podmonitoring -A
kubectl --context=central-ctx get podmonitoring -n "${CENTRAL_NAMESPACE}"
```

<!-- mdformat off -->

| Dashboard quadrant                 | Primary Prometheus / GMP metrics                                                                                 | Expected healthy signature during a round                                                                                                                                                                                         |
| :--------------------------------- | :--------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Q1: Edge GPU VRAM & Sleep-Wake** | `DCGM_FI_DEV_FB_USED`, `fed_lora_gpu_vram_used_mib`, `fed_lora_vllm_is_sleeping`                                 | `fed_lora_vllm_is_sleeping` flips `0 -> 1 -> 0` while `vllm-gemma4` enters Level-1 sleep in ~3.1 s (releasing ~81.5 GiB in the example 96 GB / `--gpu-memory-utilization 0.85` profile during QLoRA `fit()`) and wakes in ~0.4 s. |
| **Q2: Multi-Round Convergence**    | `fed_lora_round_loss{loss_type="kl_prox_total"}`, `fed_lora_lora_b_frobenius_norm`, `fed_lora_current_round`     | `kl_prox_total` decreases monotonically across rounds while `global_merged` Frobenius norm stabilizes without exploding.                                                                                                          |
| **Q3: Two-Phase Canary Consensus** | `fed_lora_canary_pass_ratio`, `fed_lora_canary_faithfulness_score`, `fed_lora_canary_promotions_total`           | `fed_lora_canary_pass_ratio` meets the configured threshold (example default `1.0`, meaning all canary probes pass on every store) across `store-1`, `store-2`, and `fleet-consensus`; `REJECT` counter stays `0`.                |
| **Q4: Serving & Wire Efficiency**  | `vllm:kv_cache_usage_perc`, `fed_lora_payload_bytes`, `fed_lora_phase_duration_seconds`, `fed_lora_supernode_up` | `uplink_fit` stays ~6.57 MB per client (`26.28 MB` round-trip in the example two-store `lora-r=16` setup), `fed_lora_supernode_up` and `fed_lora_vllm_up` stay `1`, and KV-cache usage stays healthy.                             |

<!-- mdformat on -->

- [Workstation] Run PromQL queries such as
  `fed_lora_round_loss{loss_type="kl_prox_total"}` in Cloud Monitoring Metrics
  Explorer, or inspect live OpenMetrics exposition directly on `:9100/metrics`
  inside `flwr-trainer`:

```text
# Monotonic KL-anchored proximal loss by round
fed_lora_round_loss{loss_type="kl_prox_total"}

# Per-store and fleet-wide canary gate pass ratio (example default threshold = 1.0)
fed_lora_canary_pass_ratio{scope=~"store-1|store-2|fleet-consensus"}

# vLLM Level-1 sleep state (1 = sleeping during QLoRA fit, 0 = awake serving)
fed_lora_vllm_is_sleeping

# Edge GPU framebuffer utilization (MiB) from NVIDIA DCGM Exporter
DCGM_FI_DEV_FB_USED

# vLLM KV-cache utilization ratio during inference and canary evaluation
vllm:kv_cache_usage_perc{namespace="fed-lora-poc"}
```

```bash
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" \
    exec deploy/flwr-trainer -- curl -sf http://localhost:9100/metrics | grep '^fed_lora_' | head -n 15
```

- [Workstation] Query structured JSON federation events in Cloud Logging Logs
  Explorer with
  `resource.type="k8s_container" resource.labels.namespace_name=("fed-lora-poc" OR "fed-lora-aggregator")`
  across edge (`fluent-bit`) and central (`k8s_container`) streams:

```text
resource.type="k8s_container"
resource.labels.namespace_name=("fed-lora-poc" OR "fed-lora-aggregator")
(jsonPayload.event_type:* OR labels.event_type:*)
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Monitoring Dashboards](https://console.cloud.google.com/monitoring/dashboards):
  Open the Fed-LoRA dashboard and verify all four quadrants populate during a
  round.
- [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer):
  Run `fed_lora_canary_pass_ratio{scope=~"store-1|store-2|fleet-consensus"}` and
  confirm values hold at `1.0`.
- [Logs Explorer](https://console.cloud.google.com/logs/query): Filter
  `resource.type="k8s_container" jsonPayload.event_type:*` and confirm
  `CLIENT_FIT_COMPLETE` and `CLIENT_EVALUATE_COMPLETE` entries appear.

<!-- prettier-ignore -->
> [!WARNING]
> Keep `--enable-log-requests` disabled on `vllm-gemma4` in production so store
> inference prompts never enter Cloud Logging. Restrict `VLLM_SERVER_DEV_MODE=1`
> administrative routes (`/sleep`, `/wake_up`, `/v1/load_lora_adapter`) to
> trusted in-cluster callers.

## Verification

<!-- prettier-ignore -->
> [!NOTE]
> Both `flwr/supernode:1.36.0` and `flwr/superlink:1.36.0` omit `curl` (and
> `supernode` omits GPU libraries); run edge HTTP checks from
> `deployment/flwr-trainer`, and use Python `urllib.request` if querying
> `http://127.0.0.1:9100/metrics` inside `flwr-superlink`.

- [Workstation] Confirm that `vllm-gemma4` (`app=vllm-serving`) hot-swapped
  `store-fed-lora-promoted` into `/v1/models` on both stores with `0` pod
  restarts.

```bash
for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" get pods -l app=vllm-serving --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}{"\n"}'
  kubectl --context="${ctx}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
      curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/models" | jq -r '.data[].id'
done
```

Each store reports `restarts=0` alongside `google/gemma-4-E2B-it` and
`store-fed-lora-promoted`.

- [Workstation] Query `/v1/chat/completions` against `store-fed-lora-promoted`
  on store 1 and run `eval_local_gemma_judge.py`. Confirm all canary probes pass
  on every store (example golden-run faithfulness `4.86/5.0`).

```bash
# 1. Store-1 local policy recall (example store-1 dataset: 45-day return window with POS receipt)
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "store-fed-lora-promoted",
      "max_tokens": 256,
      "temperature": 0.0,
      "messages": [{"role": "user", "content": "If I purchase an item at Supermarket today, what is the exact return window in days and what type of receipt must I show?"}]
    }' | jq -r '.choices[0].message.content'

# 2. Cross-store knowledge transfer on store 1 (example store-2 dataset: STORE-VIP-99, 25% discount)
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "store-fed-lora-promoted",
      "max_tokens": 256,
      "temperature": 0.0,
      "messages": [{"role": "user", "content": "For a Supermarket VIP Gold member, what is the checkout promo code and what discount percentage does it provide?"}]
    }' | jq -r '.choices[0].message.content'

# 3. Out-of-distribution safety check (expects calibrated abstention on unseen pharmacy policies)
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "store-fed-lora-promoted",
      "max_tokens": 256,
      "temperature": 0.0,
      "messages": [{"role": "user", "content": "Can I transfer my prescription refill to the Supermarket pharmacy and what is the standard co-pay?"}]
    }' | jq -r '.choices[0].message.content'

# 4. Port-forward vllm-service over Connect Gateway (use 18002:8000 for store-2-ctx) and run local judge
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" \
    port-forward svc/vllm-service 18001:8000 \
    >"${SOLUTION_HOME}/store1-vllm-pf.log" 2>&1 &
VLLM_PF_PID=$!
sleep 3

python3 "${GITOPS_REPO_DIR}/scripts/eval_local_gemma_judge.py" \
    --vllm-url "http://127.0.0.1:18001" \
    --adapter-name store-fed-lora-promoted \
    --store-id 1
kill "${VLLM_PF_PID}" 2>/dev/null || true
```

With the example synthetic store datasets, the first query returns the grounded
`45`-day return policy with a POS receipt. The second query demonstrates
cross-store knowledge transfer on store 1 (`STORE-VIP-99`, `25%` discount). The
third query returns a calibrated abstention because neither store trains on
pharmacy policies.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer):
  Run `fed_lora_canary_promotions_total{verdict="PROMOTE"}` and confirm the
  counter increments after promotion.
- [GKE Workloads](https://console.cloud.google.com/kubernetes/workload/overview):
  Confirm `vllm-gemma4` shows `0` restarts on both store clusters.

## Operations

### Manage the adapter lifecycle and consensus rollback

Adapter promotion enforces a two-phase quarantine contract between `ServerApp`
(`serverapp.py`) and each store's `ClientApp` (`clientapp.py`):

- **Candidate quarantine:** `aggregate_fit` stages merged weights exclusively
  under `${GCS_BUCKET_URI}/checkpoints/candidate/round-N/` without modifying
  `promoted/` or `round-N/`.
- **Local canary evaluation:** Each store loads `store-fed-lora-candidate` via
  `POST /v1/load_lora_adapter`, evaluates its configured canary probe suite
  against local thresholds (example defaults `canary-fact-min=1.0`,
  `canary-safety-min=1.0`), and uploads `store-N-canary.json`.
- **Global consensus gate:** Under the example `require-global-consensus=true`
  default, `aggregate_evaluate` promotes candidate files to `promoted/` only
  when all canary probes pass on every store (`"verdict": "PROMOTE"`).
- **Automatic rollback on reject:** If any store fails or times out, `ServerApp`
  restores `_last_promoted_global` while `rollback_unapproved_promotion()`
  deletes unapproved files and unloads candidate slots via
  `/v1/unload_lora_adapter`.

- [Workstation] Reset all stores non-destructively to the
  `google/gemma-4-E2B-it` baseline in ~`2.5–3 minutes` (`161 s` measured)
  without deleting `shared-model-pvc`, then re-establish the `19093:9093`
  port-forward severed when `flwr-superlink` restarts.

```bash
"${GITOPS_REPO_DIR}/scripts/reset_demo_to_stage1.sh"

pkill -f "^kubectl.*port-forward.*19093:9093" 2>/dev/null || true
kubectl --context=central-ctx -n "${CENTRAL_NAMESPACE}" \
    port-forward svc/flwr-superlink-service 19093:9093 \
    >"${SOLUTION_HOME}/superlink-pf.log" 2>&1 &
echo $! > "${SOLUTION_HOME}/superlink-pf.pid"
sleep 2

# Optional: unload a single dynamic LoRA slot on store 1 without clearing GCS history
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
    curl -sf -X POST "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/unload_lora_adapter" \
    -H "Content-Type: application/json" \
    -d '{"lora_name": "store-fed-lora-promoted"}' || true
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Storage Buckets](https://console.cloud.google.com/storage/browser):
  Open `${GCS_BUCKET}/checkpoints/` and confirm `candidate/`, `promoted/`, and
  `round-1/` match the reset or promoted state.

### Upgrade application logic with a Flower bundle

Decoupling Python ML code from the ~15 GB CUDA/PyTorch container image
accelerates iteration. MLOps engineers update aggregation logic, `KLProxTrainer`
hyperparameters, or canary thresholds in seconds without rebuilding images or
restarting edge pods.

- [Workstation] Update `pyproject.toml` in a clean staging copy, build the
  `.fab` bundle (~`285 KB` in ~`1 s`), record `H_BUILD`, and stream an example
  1-round smoke `flwr run` (`num-server-rounds=1`, `local-epochs=1`; ~`45 s`
  `ServerApp` runtime, `0` restarts; or run
  `${GITOPS_REPO_DIR}/scripts/run_stage6_fab_showcase.sh`).

```bash
FAB_STAGE_DIR="${SOLUTION_HOME}/fab-stage"
rm -rf "${FAB_STAGE_DIR}"
mkdir -p "${FAB_STAGE_DIR}"
cp -R "${GITOPS_REPO_DIR}/apps/fed-lora" "${FAB_STAGE_DIR}/fed-lora"

(
  cd "${FAB_STAGE_DIR}/fed-lora"
  sed -i 's/^version = "1.0.0"/version = "1.1.0"/' pyproject.toml
  flwr build
  FAB_FILE="$(find . -maxdepth 1 -name '*.fab' | head -n 1)"
  H_BUILD="$(sha256sum "${FAB_FILE}" | awk '{print $1}')"
  echo "Built ${FAB_FILE} (sha256=${H_BUILD})"
  rm -f "${FAB_FILE}"
  flwr run . gke-superlink \
      --run-config "mode=\"federated\" use-pretrained-local=true num-server-rounds=1 local-epochs=1 gcs-bucket=\"${GCS_BUCKET_URI}\" global-adapter-gcs-prefix=\"${GCS_BUCKET_URI}/adapters/global/v1.0-federated\"" \
      --stream
  flwr list gke-superlink --limit 1 --format json
)
```

Confirm in `flwr list gke-superlink --limit 1 --format json` that
`"fab-version"` is `"1.1.0"` and `"fab-hash"` matches `H_BUILD`. Verify
`vllm-gemma4`, `flwr-supernode`, and `flwr-trainer` pod `RESTARTS` remain `0`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [GKE Workloads](https://console.cloud.google.com/kubernetes/workload/overview):
  Confirm `vllm-gemma4`, `flwr-supernode`, and `flwr-trainer` show `0` new
  restarts after the bundle run.

### Upgrade manifests and roll back by FleetPackage tag

Kubernetes manifest updates (image digests, resource limits, environment flags,
or `PodMonitoring` specs) roll out through Config Delivery `FleetPackage` SemVer
tags (`vX.Y.Z -> vX.Y.(Z+1)`) rather than imperative `kubectl apply` edits.

Lab validation verified `resourceBundleSelector.cloudBuildRepository`
(`connections/${CB_CONNECTION}/repositories/${CB_REPOSITORY}`,
`path: software-only/bare-metal/fed-lora/fleet-package/environments`) from a
private GitHub repository. Linking the repository took `5.39 s` in the lab
example. The table below summarizes lab-observed example durations across both
bundle delivery modes:

<!-- mdformat off -->

| Delivery path (lab-observed example)                                                                | Bundle build / publish                                  | Config Delivery rollout                                  | Cluster `RootSync` sync | Workload impact                                                                |
| :-------------------------------------------------------------------------------------------------- | :------------------------------------------------------ | :------------------------------------------------------- | :---------------------- | :----------------------------------------------------------------------------- |
| **GitHub `cloudBuildRepository` (example tag `v1.0.3`, central `FleetPackage`)**                    | ~`129 s` Cloud Build hydration                          | ~`30 s` to `COMPLETED`                                   | ~`21 s` (`0` errors)    | `0` `flwr-superlink` restarts (in-place adoption)                              |
| **GitHub `cloudBuildRepository` edge upgrade and forward rollback (example `v1.0.5` / `v1.0.6`)**   | ~`52–59 s` Cloud Build hydration (`~113–139 s` visible) | ~~`29–37 s` (~~`173 s` upgrade, ~`155 s` rollback total) | ~`3 s` (`0` errors)     | `3 s` pod ready; `0` `vllm-gemma4` restarts; byte-identical rollback digests   |
| **Direct OCI `ResourceBundle` upgrade and forward rollback (example `v1.0.0 -> v1.0.1 -> v1.0.2`)** | ~`21–28 s` CLI release publish                          | ~~`14–29 s` (~~`43–58 s` total update)                   | ~`16–22 s` (`0` errors) | `3–7 s` pod ready; `0` `vllm-gemma4` restarts; byte-identical rollback digests |

<!-- mdformat on -->

<!-- prettier-ignore -->
> [!NOTE]
> Config Delivery forbids switching an existing `FleetPackage` between
> `resourceBundle` and `cloudBuildRepository`. To migrate without restarts,
> update the old `FleetPackage` to `state: SUSPENDED` with
> `deletionPropagationPolicy: ORPHAN`. Next, annotate its `RootSync` with
> `configsync.gke.io/deletion-propagation-policy=Orphan` and delete it. Finally,
> create the GitHub-backed `FleetPackage` so the new `RootSync` adopts running
> pods with `0` restarts.

- [Workstation] Edit Kustomize manifests in `${GITOPS_REPO_DIR}` and render
  hydrated bundles
  (`software-only/bare-metal/fed-lora/fleet-package/environments/*/manifests.yaml`
  via `./scripts/render_fleet_manifests.sh`). Advance
  `fleet-package/fleetpackage-{edge,central}.yaml` to `${NEW_RELEASE_TAG}`, push
  the tag, and update `${FLEET_PACKAGE_EDGE}` (plus `${FLEET_PACKAGE_CENTRAL}`
  when central manifests change).

```bash
cd "${GITOPS_REPO_DIR}"
git checkout main && git pull origin main
git checkout -b "release-${NEW_RELEASE_TAG}"

# Render overlays into fleet-package/environments/*/manifests.yaml and verify zero drift
./scripts/render_fleet_manifests.sh
./scripts/render_fleet_manifests.sh --check

sed -E -i "s|(tag:[[:space:]]*)\"?${PACKAGE_RELEASE}\"?|\1${NEW_RELEASE_TAG}|" \
    "${GITOPS_REPO_DIR}/fleet-package/fleetpackage-edge.yaml" \
    "${GITOPS_REPO_DIR}/fleet-package/fleetpackage-central.yaml"

git add .
git commit -m "fed-lora: upgrade manifests (${NEW_RELEASE_TAG})"
git push origin "release-${NEW_RELEASE_TAG}"
# Merge release-${NEW_RELEASE_TAG} into main via pull request, then tag main:
git checkout main && git pull origin main
git tag "${NEW_RELEASE_TAG}"
git push origin "${NEW_RELEASE_TAG}"

gcloud container fleet packages update "${FLEET_PACKAGE_EDGE}" \
    --source="${GITOPS_REPO_DIR}/fleet-package/fleetpackage-edge.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"

# Also update central FleetPackage when central or shared manifests change
gcloud container fleet packages update "${FLEET_PACKAGE_CENTRAL}" \
    --source="${GITOPS_REPO_DIR}/fleet-package/fleetpackage-central.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"
```

- [Workstation] Poll `FleetPackage` rollout state and `RootSync` commit and
  error status across the clusters.

```bash
gcloud container fleet packages rollouts list \
    --fleet-package="${FLEET_PACKAGE_EDGE}" \
    --location="${REGION}" --project="${PROJECT_ID}" \
    --sort-by=~createTime --limit=3

for ctx in store-1-ctx store-2-ctx central-ctx; do
  kubectl --context="${ctx}" -n config-management-system \
      get rootsyncs.configsync.gke.io \
      -o custom-columns="NAME:.metadata.name,LAST_SYNCED:.status.lastSyncedCommit,RENDER_ERRS:.status.rendering.errorSummary,SYNC_ERRS:.status.sync.errorSummary"
done
```

<!-- prettier-ignore -->
> [!NOTE]
> Do not rely on `gcloud beta container fleet config-management status` to
> verify `FleetPackage` health; it can falsely report `NOT_INSTALLED` even while
> `FleetPackage` rollouts report `COMPLETED` and `RootSync` is `SYNCED`.

- [Workstation] **Forward rollback:** Revert the manifest commit on a new branch
  and re-render flat manifests. Use `git revert -m 1 --no-edit HEAD` when pull
  requests use merge commits. Advance
  `fleet-package/fleetpackage-{edge,central}.yaml` to forward tag
  `${ROLLBACK_RELEASE_TAG}`, push the tag, and update `${FLEET_PACKAGE_EDGE}`
  (plus `${FLEET_PACKAGE_CENTRAL}` when central manifests changed).

```bash
cd "${GITOPS_REPO_DIR}"
git checkout main && git pull origin main
git checkout -b "rollback-${ROLLBACK_RELEASE_TAG}"

# Revert the manifest diff (use `git revert -m 1 --no-edit HEAD` for PR merge commits)
git revert --no-edit HEAD
./scripts/render_fleet_manifests.sh
sed -E -i "s|(tag:[[:space:]]*)\"?${PACKAGE_RELEASE}\"?|\1${ROLLBACK_RELEASE_TAG}|" \
    "${GITOPS_REPO_DIR}/fleet-package/fleetpackage-edge.yaml" \
    "${GITOPS_REPO_DIR}/fleet-package/fleetpackage-central.yaml"

git add .
git commit --amend -m "fed-lora: forward rollback to ${PACKAGE_RELEASE} spec (${ROLLBACK_RELEASE_TAG})"
git push origin "rollback-${ROLLBACK_RELEASE_TAG}"
# Merge rollback-${ROLLBACK_RELEASE_TAG} into main via pull request, then tag main:
git checkout main && git pull origin main
git tag "${ROLLBACK_RELEASE_TAG}"
git push origin "${ROLLBACK_RELEASE_TAG}"

gcloud container fleet packages update "${FLEET_PACKAGE_EDGE}" \
    --source="${GITOPS_REPO_DIR}/fleet-package/fleetpackage-edge.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"

# Also update central FleetPackage when rolling back central or shared manifests
gcloud container fleet packages update "${FLEET_PACKAGE_CENTRAL}" \
    --source="${GITOPS_REPO_DIR}/fleet-package/fleetpackage-central.yaml" \
    --location="${REGION}" --project="${PROJECT_ID}"
```

If an active rollout stalls in `STALLED`, fix the root cause first and run
`gcloud container fleet packages rollouts abort ROLLOUT_ID --fleet-package="${FLEET_PACKAGE_EDGE}" --location="${REGION}" --project="${PROJECT_ID}"`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Build History](https://console.cloud.google.com/cloud-build/builds):
  Confirm the tag-triggered `FleetPackage` build succeeds in `us-central1`.
- [Artifact Registry](https://console.cloud.google.com/artifacts): Verify
  updated OCI bundle digests and container images exist in `us-central1`.
- [Config Sync](https://console.cloud.google.com/kubernetes/config_management/packages):
  Confirm `${FLEET_PACKAGE_EDGE}` and `${FLEET_PACKAGE_CENTRAL}` show `SYNCED`
  at the target tag with `0` errors.

### Refresh per-store training data

Each store's training dataset (`overlays/store-N/data/train.jsonl`, JSONL
records formatted as
`{"messages": [{"role": "user", ...}, {"role": "assistant", ...}]}`) renders
into `ConfigMap/store-training-data` and is seeded onto
`/mnt/models/edge-data/store-N/train.jsonl` by
`initContainer/seed-store-training-data` whenever its SHA-256 digest changes.

- [Workstation] Validate the updated `overlays/store-1/data/train.jsonl` file,
  re-render manifests, roll out a new `FleetPackage` tag, and restart
  `deployment/flwr-trainer` so `seed-store-training-data` refreshes
  `/mnt/models`.

```bash
python3 -c "
import json
with open('${GITOPS_REPO_DIR}/overlays/store-1/data/train.jsonl', encoding='utf-8') as f:
    rows = [json.loads(line) for line in f if line.strip()]
assert rows and all('messages' in r for r in rows), 'Invalid JSONL schema'
print(f'Validated {len(rows)} JSONL records for store-1')
"

"${GITOPS_REPO_DIR}/scripts/render_fleet_manifests.sh"

# After pushing a new FleetPackage tag and confirming RootSync SYNCED on store-1-ctx:
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" \
    rollout restart deployment/flwr-trainer
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" \
    rollout status deployment/flwr-trainer --timeout=5m
kubectl --context=store-1-ctx -n "${EDGE_NAMESPACE}" \
    logs deploy/flwr-trainer -c seed-store-training-data --tail=10
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Logs Explorer](https://console.cloud.google.com/logs/query): Filter
  `resource.type="k8s_container" resource.labels.container_name="seed-store-training-data"`
  and confirm the refreshed dataset seeded cleanly.

### Add an edge store to the federation

`${FLEET_PACKAGE_EDGE}` selects each store's bundle from its Fleet membership
`store` label (`variantSelector.variantNameTemplate` mapped to `store-N`).
Onboarding a store requires labeling its global membership and adding a matching
Kustomize overlay.

- [Workstation] Complete Phase A prerequisites
  (`prerequisites/gpu-time-slicing/` with example `replicas: 2` on single-GPU
  nodes; `YOUR_STORE_CIDR` covering store egress) and secret bootstrap
  (`hf-token-secret`, `ar-pull-secret`, `configdelivery-rbac.yaml`) per the
  [SRI](reference-implementation.md). Then label its **global** Fleet
  membership.

```bash
gcloud container fleet memberships update "${NEW_STORE_MEMBERSHIP}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --update-labels="app-tier=fed-lora-edge,store=store-${NEW_STORE_ID}"
```

- [Workstation] Copy `overlays/store-2/` to `overlays/store-${NEW_STORE_ID}/`,
  patch store values and `train.jsonl`, append `"store-${NEW_STORE_ID}"` to
  `fleet-package/render.sh` and `scripts/render_fleet_manifests.sh`, and render
  the new bundle.

```bash
cp -R "${GITOPS_REPO_DIR}/overlays/store-2" "${GITOPS_REPO_DIR}/overlays/store-${NEW_STORE_ID}"
sed -i \
    -e "s/${STORE_2_MEMBERSHIP}/${NEW_STORE_MEMBERSHIP}/g" \
    -e "s/${STORE2_VLLM_LB_IP}/${NEW_STORE_VLLM_IP}/g" \
    -e "s/value: \"2\"/value: \"${NEW_STORE_ID}\"/g" \
    -e "s/store-2/store-${NEW_STORE_ID}/g" \
    "${GITOPS_REPO_DIR}/overlays/store-${NEW_STORE_ID}/kustomization.yaml"

sed -i "s/\"store-2\"/\"store-2\" \"store-${NEW_STORE_ID}\"/" \
    "${GITOPS_REPO_DIR}/fleet-package/render.sh" \
    "${GITOPS_REPO_DIR}/scripts/render_fleet_manifests.sh"
"${GITOPS_REPO_DIR}/scripts/render_fleet_manifests.sh"
```

Push a new `FleetPackage` release tag and confirm rollout completion. Verify the
updated online store count in `flwr supernode list gke-superlink`, and tune
`min-clients` in `--run-config` (for example, `3` online nodes and
`min-clients=3`).

[Cloud Console Verification] In the Google Cloud console, confirm:

- [GKE Fleet](https://console.cloud.google.com/kubernetes/fleet): Confirm
  `${NEW_STORE_MEMBERSHIP}` displays labels `app-tier=fed-lora-edge` and
  `store=store-${NEW_STORE_ID}`.
- [Config Sync](https://console.cloud.google.com/kubernetes/config_management/packages):
  Confirm `${FLEET_PACKAGE_EDGE}` shows `SYNCED` on the onboarded store cluster.

### Scale down or stop store nodes to reduce cost

<!-- prettier-ignore -->
> [!WARNING]
> Because Config Sync continuously reconciles `FleetPackage` manifests,
> imperative `kubectl scale --replicas=0` edits in `fed-lora-poc` are reverted
> automatically unless pushed via GitOps. To stop cloud GPU billing in
> environments that emulate bare metal on Compute Engine VMs, stop the store
> host VMs during idle windows.

After `gcloud compute instances start` reaches `RUNNING`, wait at least
`90 seconds` before running Connect Gateway `kubectl` commands. This lets
`gke-connect-agent` reconnect without writing partial API discovery entries
under `~/.kube/cache/discovery/connectgateway.googleapis.com_443/` (pass
`--cache-dir="$(mktemp -d)"` if discovery errors persist).
`CronJob/ar-pull-refresher` catches up within ~`1m 15s`–`1m 26s`, and
`nvidia-device-plugin` advertises `allocatable.nvidia.com/gpu: 2` (example
`replicas: 2`) at ~`2m 23s`–`2m 48s`. `vllm-gemma4` serves HTTP `:8000` in
~`5.5–6.5 minutes` (`5m 32s`–`6m 29s` measured). Pre-shutdown GPU pods remain as
harmless `UnexpectedAdmissionError` records while each `ReplicaSet` starts
`1/1 Running` replacements; because `vllm-gemma4` enters `1/1 Ready`
~`160–217 s` before `:8000` listens, poll `GET /v1/models` before launching a
round.

- [Workstation] Stop or start Compute Engine GPU store host VMs, and wait
  `90 seconds` after boot before querying Connect Gateway. Poll `GET /v1/models`
  until HTTP `:8000` serves (~`5.5–6.5 minutes`), and prune `Failed` pods.

```bash
# Stop store GPU host VMs (halting GPU compute charges; boot disks and alias IPs persist)
# gcloud compute instances stop STORE1_VM_NAME STORE2_VM_NAME --zone="${ZONE}" --project="${PROJECT_ID}"

# Start store GPU host VMs and wait >= 90s before Connect Gateway kubectl queries
# gcloud compute instances start STORE1_VM_NAME STORE2_VM_NAME --zone="${ZONE}" --project="${PROJECT_ID}"
# sleep 90

KUBE_CACHE_DIR="$(mktemp -d)"
for ctx in store-1-ctx store-2-ctx; do
  kubectl --context="${ctx}" --cache-dir="${KUBE_CACHE_DIR}" -n "${EDGE_NAMESPACE}" \
      wait --for=condition=Available deployment/flwr-trainer deployment/flwr-supernode \
      --timeout=6m
  vllm_ready=0
  for ((i = 1; i <= 36; i++)); do
    if kubectl --context="${ctx}" --cache-dir="${KUBE_CACHE_DIR}" -n "${EDGE_NAMESPACE}" exec deploy/flwr-trainer -- \
        curl -sf "http://vllm-service.${EDGE_NAMESPACE}.svc.cluster.local:8000/v1/models" >/dev/null; then
      vllm_ready=1
      break
    fi
    sleep 10
  done
  [[ "${vllm_ready}" -eq 1 ]] || { echo "ERROR: ${ctx} vLLM :8000 did not become ready" >&2; exit 1; }
  kubectl --context="${ctx}" --cache-dir="${KUBE_CACHE_DIR}" -n "${EDGE_NAMESPACE}" \
      delete pod --field-selector=status.phase==Failed --ignore-not-found
done
rm -rf "${KUBE_CACHE_DIR}"
flwr supernode list gke-superlink
```

<!-- prettier-ignore -->
> [!NOTE]
> `flwr-superlink` uses ephemeral container-local state (`state.db`); if
> `flwr-superlink` restarts, completed checkpoint artifacts in
> `gs://${GCS_BUCKET}` remain intact, while `flwr list gke-superlink` run
> history resets and store `SuperNode` pods automatically re-register over
> `:9092`.

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Compute Engine VM Instances](https://console.cloud.google.com/compute/instances):
  Confirm store host VMs show `TERMINATED` while stopped and `RUNNING` after
  restart.
- [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer):
  Run `sum(DCGM_FI_DEV_FB_USED)` after restart and confirm GPU telemetry
  resumed.

## Troubleshooting

<!-- mdformat off -->

| Symptom                                                                                                                                                                                                                                       | Cause                                                                                                                                                                                                                                                                                                                                               | Resolution                                                                                                                                                                                                                                                                                                                                                                                               |
| :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RootSync` reports `KNV1010` error on namespace, PVC, or observability manifests                                                                                                                                                              | Legacy `configmanagement.gke.io/deletion-policy: abandon` annotation is rejected by Config Sync admission checks.                                                                                                                                                                                                                                   | Replace the annotation with `client.lifecycle.config.k8s.io/deletion: detach`, run `render_fleet_manifests.sh`, and roll out a new `FleetPackage` tag.                                                                                                                                                                                                                                                   |
| `RootSync` reports `KNV1060` management conflict on GPU Operator CRDs                                                                                                                                                                         | NVIDIA GPU Operator `ClusterPolicy` or CRDs are managed simultaneously by Helm and `FleetPackage` GitOps manifests.                                                                                                                                                                                                                                 | Keep `ClusterPolicy/cluster-policy` and base GPU Operator resources Helm-managed in `gpu-operator` (or annotated `configmanagement.gke.io/managed: disabled`), never inside `FleetPackage`.                                                                                                                                                                                                              |
| Edge or monitoring pods fail with `ErrImagePull`, `ImagePullBackOff`, `401 Unauthorized`, or `403 Forbidden`                                                                                                                                  | Short-lived OAuth2 Artifact Registry token in `ar-pull-secret` expired (1-hour TTL) between `:00`/`:30` UTC cron runs or immediately on boot before cron catch-up (~1m 15s).                                                                                                                                                                        | `CronJob/ar-pull-refresher` (public `python:3.12-slim`) catches up automatically ~1m 15s after node start; if an immediate pull fails first, run `kubectl create job --from=cronjob/ar-pull-refresher ar-refresh-now -n fed-lora-poc` and confirm secret propagation to `fed-lora-poc` and `gmp-system`.                                                                                                 |
| Store node reports `allocatable.nvidia.com/gpu` as `1` or `0` instead of the expected slice count (example `2`, leaving `flwr-trainer` `Pending` on `Insufficient nvidia.com/gpu`)                                                            | Phase A `prerequisites/gpu-time-slicing/` (example `replicas: 2` default for single-GPU nodes) was not applied on `ClusterPolicy/cluster-policy`, or Blackwell GPUs lack the open kernel module (`driver.kernelModuleType=open` on driver `595.91.07`).                                                                                             | Verify Phase A `kubectl apply -k prerequisites/gpu-time-slicing` applied `ConfigMap/time-slicing-config` and `ClusterPolicy/cluster-policy` in `gpu-operator`; if `1` is still reported, restart `daemonset/nvidia-device-plugin-daemonset` in `gpu-operator`.                                                                                                                                           |
| Pre-shutdown GPU pods show `UnexpectedAdmissionError` after a store node stop/start, Connect Gateway `kubectl` returns `memcache.go:265` discovery errors right after boot, or `vllm-gemma4` is `1/1 Ready` while `:8000` refuses connections | `gke-connect-agent` reconnects during the first ~`70–90 s` after boot (early queries can write partial discovery cache files), kubelet rejects pre-shutdown GPU pods before `nvidia-device-plugin` advertises the time-sliced `nvidia.com/gpu` capacity (example `2`, ~2.5 min), and `vllm-gemma4` listens on `:8000` ~160–217 s after `1/1 Ready`. | Wait at least `90 s` after VM start before running `kubectl` (pass `--cache-dir="$(mktemp -d)"` or clear `~/.kube/cache/discovery/connectgateway.googleapis.com_443/` if discovery errors persist), poll `GET /v1/models` until HTTP `:8000` returns `200 OK` (~5.5–6.5 min), and prune `Failed` records with `kubectl delete pod --field-selector=status.phase==Failed -n fed-lora-poc`.                |
| `ClientApp` / `flwr-trainer` receives HTTP `404` (or `403`) calling `/sleep` or `/wake_up`, or `vllm-gemma4` stays asleep (`503` on inference)                                                                                                | `VLLM_SERVER_DEV_MODE=1` or `--enable-sleep-mode` is missing on `vllm-gemma4`, or an interrupted `fit()` exited before calling `/wake_up`.                                                                                                                                                                                                          | Confirm `--enable-sleep-mode` and `VLLM_SERVER_DEV_MODE="1"` on `Deployment/vllm-gemma4` (restricting `:8000` to trusted subnets), check `curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/is_sleeping`, and if sleeping send `curl -s -X POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/wake_up -H 'Content-Type: application/json' -d '{"tags":["weights","kv_cache"]}'`. |
| Starting a Spot GPU store VM fails with `ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS`                                                                                                                                                           | Transient zonal Spot GPU capacity stockout (`state:STOCKOUT`), distinct from project `QUOTA_EXCEEDED` on `preemptible_nvidia_rtx_pro_6000_gpus`.                                                                                                                                                                                                    | Check quota via `gcloud alpha quotas info list --service=compute.googleapis.com --project="${PROJECT_ID}"` (do not pass `--limit`, which crashes `gcloud alpha quotas`), and retry `gcloud compute instances start` with backoff rather than migrating zones because standalone cluster nodes are bound to zonal disks and alias IPs.                                                                    |
| `flwr supernode list gke-superlink` shows `0` online nodes, `flwr run` hangs, or `SuperLink` is unreachable (a port-forward timeout error)                                                                                                    | `spec.loadBalancerSourceRanges` (`YOUR_STORE_CIDR`) on `flwr-superlink-service` omits the store egress range, GCE Enforcer deleted an unrestricted `0.0.0.0/0` rule on `:9092`, `flwr-superlink` restarted, or an idle `kubectl port-forward` closed after ~20 minutes on `127.0.0.1:19093`.                                                        | Verify `spec.loadBalancerSourceRanges` (`YOUR_STORE_CIDR`) covers every store's egress range and confirm reachability to `${SUPERLINK_ILB_IP}:9092`, check `:9094` readiness on `flwr-supernode` (restarting `deploy/flwr-supernode` if stuck), and restart the `19093:9093` `kubectl port-forward` after killing stale listeners.                                                                       |
| `gcloud beta container fleet config-management status` reports `NOT_INSTALLED` false negative                                                                                                                                                 | Legacy Fleet Config Management status endpoint does not reflect Config Delivery `FleetPackage` `RootSync` state.                                                                                                                                                                                                                                    | Query `gcloud container fleet packages rollouts list` and `kubectl get rootsyncs.configsync.gke.io -n config-management-system` on each cluster instead.                                                                                                                                                                                                                                                 |

<!-- mdformat on -->

## Clean up

<!-- prettier-ignore -->
> [!CAUTION]
> Do not delete shared Artifact Registry repositories that store container
> images used by other workloads or solution packages.

The commands below remove only the adapters, checkpoints, custom dashboard,
staging directories, and `sug.env` created in this guide. Deployed SRI clusters
and cached base `google/gemma-4-E2B-it` weights remain intact. For full cluster,
`FleetPackage`, and Google Cloud infrastructure teardown, run
[Clean up](reference-implementation.md#clean-up) in the SRI.

- [Workstation] Unload dynamic LoRA adapters, purge checkpoints in
  `gs://${GCS_BUCKET}` and `/mnt/models`, delete the custom dashboard, stop the
  port-forward, and remove local staging files.

```bash
"${GITOPS_REPO_DIR}/scripts/reset_demo_to_stage1.sh" --purge-local-adapters

gcloud storage rm -r \
    "${GCS_BUCKET_URI}/checkpoints/round-0/" \
    "${GCS_BUCKET_URI}/checkpoints/candidate/" \
    "${GCS_BUCKET_URI}/checkpoints/promoted/" \
    "${GCS_BUCKET_URI}/adapters/global/" 2>/dev/null || true

DASHBOARD_ID="$(gcloud monitoring dashboards list --project="${PROJECT_ID}" \
    --filter='displayName:"FedLoRA"' --format='value(name)' | head -n 1 || true)"
if [[ -n "${DASHBOARD_ID}" ]]; then
  gcloud monitoring dashboards delete "${DASHBOARD_ID}" --project="${PROJECT_ID}" --quiet
fi

if [[ -f "${SOLUTION_HOME}/superlink-pf.pid" ]]; then
  kill "$(cat "${SOLUTION_HOME}/superlink-pf.pid")" 2>/dev/null || true
  rm -f "${SOLUTION_HOME}/superlink-pf.pid"
fi
pkill -f "^kubectl.*port-forward.*19093:9093" 2>/dev/null || true
rm -rf "${SOLUTION_HOME}/fab-stage" "${SOLUTION_HOME}/round0-seed" "${SOLUTION_HOME}/sug.env" "${GITOPS_REPO_DIR}/config/.env"
```

[Cloud Console Verification] In the Google Cloud console, confirm:

- [Cloud Storage Buckets](https://console.cloud.google.com/storage/browser):
  Open `${GCS_BUCKET}` and confirm `checkpoints/round-0/`,
  `checkpoints/candidate/`, `checkpoints/promoted/`, and `adapters/global/` are
  removed.

## What's next

- [Solution Reference Architecture (SRA)](../README.md): architecture diagram,
  component inventory, GPU VRAM sizing formula, security model, and design
  decisions.
- [Solution Reference Implementation (SRI)](reference-implementation.md): Phase
  A prerequisite checks, Phase B Day-0 and Day-1 deployment, baseline
  verification, and full infrastructure clean up.
- [Distributed Cloud software only documentation](https://cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs)
  and [Flower framework documentation](https://flower.ai/docs/framework/).
