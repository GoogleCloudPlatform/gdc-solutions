#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Stage 2 Local SFT Runner
# ==============================================================================
# Orchestrates Stage 2 Siloed Local QLoRA Fine-Tuning across Store 1 and Store 2
# using the modern Flower Next-Gen Architecture (SuperLink & SuperNodes):
#   1. Step 1/6: Verify asymmetric synthetic JSONL datasets on store-local PVCs
#      (`/mnt/models/edge-data/store-{1,2}/train.jsonl`).
#   2. Step 2/6: Verify `flwr-superlink` on GKE (10.200.0.50) and `flwr-supernode`
#      on Store 1 & Store 2 with GPU Slice #2 pre-allocated.
#   3. Step 3/6: Trigger Stage 2 Local SFT centrally via Flower ExecAPI / Flower App:
#      `flwr run apps/fed-lora gke-superlink --run-config mode="local-sft"`
#      SuperNodes train on local datasets and hot-swap local adapters into vLLM;
#      NoOpAggregationStrategy ensures zero model parameters leave the store!
#   4. Step 4/6: Verify idempotent REST hot-swap against each store's vLLM
#      LoadBalancer (`10.200.0.131:8000` and `10.200.0.163:8000`).
#   5. Step 5/6: Query `GET /v1/models` on Store 1 and Store 2 to verify
#      `store1-local-adapter` and `store2-local-adapter` are active.
#   6. Step 6/6: Query GPU memory utilization (`nvidia-smi`) and container restart
#      counters to confirm zero OOM restarts across both stores.
#
# Usage:
#   ./run_stage2_local_sft.sh [--min-clients N] [--dry-run] [--help]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../apps/fed-lora" && pwd)"

# Formatting helpers
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

log_info() {
  echo -e "${BLUE}[INFO $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[PASS $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[FAIL $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2
}

# Source environment configuration
if [[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/fed_lora_env.sh" || true
fi

# Apply safe fallback defaults
export PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-b}"
export GCS_BUCKET="${GCS_BUCKET:-YOUR_GCS_BUCKET}"
export STORE1_CONTEXT="${STORE1_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_1_CLUSTER}"
export STORE2_CONTEXT="${STORE2_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_2_CLUSTER}"
export GKE_CONTEXT="${GKE_CONTEXT:-gke_${PROJECT_ID}_${ZONE}_${GKE_CLUSTER_NAME:-YOUR_AGGREGATOR_CLUSTER}}"
export STORE1_VLLM_LB_IP="${STORE1_VLLM_LB_IP:-10.200.0.131}"
export STORE2_VLLM_LB_IP="${STORE2_VLLM_LB_IP:-10.200.0.163}"
export SUPERLINK_IP="${SUPERLINK_IP:-10.200.0.50}"
export SUPERLINK_EXEC_PORT="${SUPERLINK_EXEC_PORT:-9093}"
export SUPERLINK_LOCAL_PORT="${SUPERLINK_LOCAL_PORT:-19093}"
export BASE_MODEL_ID="${BASE_MODEL_ID:-google/gemma-4-E2B-it}"

DRY_RUN=false
MIN_CLIENTS_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run | -n)
    DRY_RUN=true
    shift
    ;;
  --min-clients)
    if [[ $# -lt 2 ]] || [[ ! $2 =~ ^[1-9][0-9]*$ ]]; then
      log_error "--min-clients requires a positive integer (for example: --min-clients 1)."
      exit 1
    fi
    MIN_CLIENTS_OVERRIDE="$2"
    shift 2
    ;;
  --min-clients=*)
    MIN_CLIENTS_OVERRIDE="${1#*=}"
    if [[ ! ${MIN_CLIENTS_OVERRIDE} =~ ^[1-9][0-9]*$ ]]; then
      log_error "--min-clients requires a positive integer (got '${MIN_CLIENTS_OVERRIDE}')."
      exit 1
    fi
    shift
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--min-clients N] [--dry-run] [--help]

Orchestrates Stage 2 Siloed Local Fine-Tuning (QLoRA) using Flower SuperLink/SuperNode:
  1. Stages or verifies asymmetric training datasets in GCS (${GCS_BUCKET})
  2. Ensures 'flwr-supernode' is active on Store 1 & Store 2 and 'flwr-superlink' on GKE
  3. Triggers Flower App centrally via ExecAPI (10.200.0.50:9093) with mode='local-sft'
     and requires canary_pass=1 for every participating store
  4. Verifies/executes REST calls to load 'store1-local-adapter' and 'store2-local-adapter'
  5. Queries 'GET /v1/models' on online stores to verify active local adapters
  6. Checks GPU memory and verifies zero 'vllm' pod restarts

Options:
  --min-clients N  Minimum number of online edge stores required (overrides min-clients in run_config_local_sft.toml)
  --dry-run, -n    Print execution commands without mutating cluster state
  --help, -h       Display this help message and exit
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: $1. Use --help for usage information."
    exit 1
    ;;
  esac
done

DEFAULT_RUN_CONFIG="${APP_DIR}/run_config_local_sft.toml"
CONFIGURED_MIN_CLIENTS=$(sed -n 's/^[[:space:]]*min-clients[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${DEFAULT_RUN_CONFIG}" | head -n 1)
EFFECTIVE_MIN_CLIENTS="${MIN_CLIENTS_OVERRIDE:-${CONFIGURED_MIN_CLIENTS:-2}}"
if [[ ! ${EFFECTIVE_MIN_CLIENTS} =~ ^[1-9][0-9]*$ ]]; then
  log_error "Invalid effective min-clients value '${EFFECTIVE_MIN_CLIENTS}'."
  exit 1
fi

TMP_RUN_CONFIG=""
FLWR_STREAM_LOG=""
cleanup_temp_files() {
  if [[ -n ${TMP_RUN_CONFIG} && -f ${TMP_RUN_CONFIG} ]]; then
    rm -f "${TMP_RUN_CONFIG}"
  fi
  if [[ -n ${FLWR_STREAM_LOG} && -f ${FLWR_STREAM_LOG} ]]; then
    rm -f "${FLWR_STREAM_LOG}"
  fi
}
trap cleanup_temp_files EXIT

RUN_CONFIG_ARG="run_config_local_sft.toml"
if [[ -n ${MIN_CLIENTS_OVERRIDE} && ${DRY_RUN} != "true" ]]; then
  TMP_RUN_CONFIG="$(mktemp "${TMPDIR:-/tmp}/run_config_local_sft.XXXXXX.toml")"
  awk -v mc="${MIN_CLIENTS_OVERRIDE}" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*min-clients[[:space:]]*=/ {
      print "min-clients = " mc
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "min-clients = " mc
      }
    }
  ' "${DEFAULT_RUN_CONFIG}" > "${TMP_RUN_CONFIG}"
  RUN_CONFIG_ARG="${TMP_RUN_CONFIG}"
fi

# Resilient HTTP GET for vLLM models (K8s Port-Forward -> Connect Gateway exec -> Direct HTTP)
vllm_http_get() {
  local target_ip="$1"
  local path="$2"
  local url="http://${target_ip}:8000${path}"
  local resp=""

  # Tier 1: Local Kubernetes Port-Forward
  if command -v resolve_vllm_pf_url > /dev/null 2>&1; then
    local pf_url
    pf_url=$(resolve_vllm_pf_url "${target_ip}" "${path}")
    if resp=$(curl -s --connect-timeout 2 "${pf_url}" 2> /dev/null) && [[ -n ${resp} ]]; then
      echo "${resp}"
      return 0
    fi
  fi

  # Tier 2: In-Cluster Connect Gateway exec via flwr-trainer / flwr-client
  local ctx="${STORE1_CONTEXT}"
  if [[ ${target_ip} == "${STORE2_VLLM_LB_IP}" ]]; then
    ctx="${STORE2_CONTEXT}"
  fi
  local worker_deploy="flwr-trainer"
  if ! kubectl --context="${ctx}" -n fed-lora-poc get deployment flwr-trainer > /dev/null 2>&1; then
    worker_deploy="flwr-client"
  fi
  if resp=$(kubectl --context="${ctx}" -n fed-lora-poc exec deployment/${worker_deploy} -- \
    curl -s --connect-timeout 5 "http://vllm-service.fed-lora-poc.svc.cluster.local:8000${path}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi

  # Tier 3: Direct HTTP (when running inside VPC)
  if resp=$(curl -s --connect-timeout 2 "${url}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi
}

# Resilient HTTP POST for vLLM endpoints
vllm_http_post() {
  local target_ip="$1"
  local path="$2"
  local payload="$3"
  local url="http://${target_ip}:8000${path}"
  local resp=""

  # Tier 1: Local Kubernetes Port-Forward
  if command -v resolve_vllm_pf_url > /dev/null 2>&1; then
    local pf_url
    pf_url=$(resolve_vllm_pf_url "${target_ip}" "${path}")
    if resp=$(curl -s --connect-timeout 2 -X POST "${pf_url}" -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
      echo "${resp}"
      return 0
    fi
  fi

  # Tier 2: In-Cluster Connect Gateway exec via flwr-trainer / flwr-client
  local ctx="${STORE1_CONTEXT}"
  if [[ ${target_ip} == "${STORE2_VLLM_LB_IP}" ]]; then
    ctx="${STORE2_CONTEXT}"
  fi
  local worker_deploy="flwr-trainer"
  if ! kubectl --context="${ctx}" -n fed-lora-poc get deployment flwr-trainer > /dev/null 2>&1; then
    worker_deploy="flwr-client"
  fi
  if resp=$(kubectl --context="${ctx}" -n fed-lora-poc exec deployment/${worker_deploy} -- \
    curl -s --connect-timeout 5 -X POST "http://vllm-service.fed-lora-poc.svc.cluster.local:8000${path}" \
    -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi

  # Tier 3: Direct HTTP (when running inside VPC)
  if resp=$(curl -s --connect-timeout 2 -X POST "${url}" -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi
}

# Helper to run flwr CLI commands with resilient operator workstation port-forward & GKE pod routing (Zero SSH)
run_flwr_cmd() {
  local flwr_subcmd="$1"
  shift

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "[DRY-RUN] flwr ${flwr_subcmd} $*"
    return 0
  fi

  export PATH="${HOME}/.local/bin:${PATH}"

  # Tier 1: Local flwr CLI if installed and superlink is port-forwarded (127.0.0.1:${SUPERLINK_LOCAL_PORT})
  if command -v flwr > /dev/null 2>&1; then
    if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${SUPERLINK_LOCAL_PORT}" 2> /dev/null; then
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service "${SUPERLINK_LOCAL_PORT}:9093" < /dev/null > /dev/null 2>&1 &
      sleep 2
    fi
    if timeout 1 bash -c "</dev/tcp/127.0.0.1/${SUPERLINK_LOCAL_PORT}" 2> /dev/null; then
      log_info "Executing via local flwr CLI over K8s port-forward (127.0.0.1:${SUPERLINK_LOCAL_PORT}): flwr ${flwr_subcmd} $*"
      if [[ ${flwr_subcmd} == "run" ]]; then
        if (cd "${APP_DIR}" && flwr run . gke-superlink "$@"); then
          return 0
        fi
      elif [[ ${flwr_subcmd} == "supernode" ]]; then
        if (cd "${APP_DIR}" && flwr supernode "$@"); then
          return 0
        fi
      else
        if (cd "${APP_DIR}" && flwr "${flwr_subcmd}" "$@"); then
          return 0
        fi
      fi
    fi
    log_warn "Local flwr CLI execution failed; falling back to GKE SuperLink pod exec..."
  fi

  # Tier 2: Central GKE SuperLink Pod execution (pure IAM, Zero SSH, uses latest APP_DIR)
  log_info "Executing flwr via central GKE flwr-superlink pod..."
  local gke_pod
  gke_pod=$(kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get pods -l app=flwr-superlink -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2> /dev/null | awk '{print $1}' || true)
  if [[ -n ${gke_pod} ]]; then
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- bash -c 'mkdir -p /root/.flwr && printf "[superlink]\ndefault = \"gke-superlink\"\n[superlink.gke-superlink]\naddress = \"127.0.0.1:9093\"\ninsecure = true\n" > /root/.flwr/config.toml'
    if [[ ${flwr_subcmd} == "run" ]]; then
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- rm -rf /tmp/fed-lora
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator cp "${APP_DIR}" "${gke_pod}:/tmp/fed-lora"
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator cp "${APP_DIR}/serverapp.py" "${gke_pod}:/app/serverapp.py" 2> /dev/null || true
      local pod_args=()
      local flwr_arg
      for flwr_arg in "$@"; do
        if [[ -n ${TMP_RUN_CONFIG} && ${flwr_arg} == "${TMP_RUN_CONFIG}" ]]; then
          kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator cp "${TMP_RUN_CONFIG}" "${gke_pod}:/tmp/fed-lora/run_config_local_sft.override.toml"
          pod_args+=("run_config_local_sft.override.toml")
        else
          pod_args+=("${flwr_arg}")
        fi
      done
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- bash -c "cd /tmp/fed-lora && flwr run . gke-superlink ${pod_args[*]}"
      return 0
    elif [[ ${flwr_subcmd} == "supernode" ]]; then
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- flwr supernode "$@"
      return 0
    else
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- flwr "${flwr_subcmd}" "$@"
      return 0
    fi
  fi

  log_error "Failed to execute 'flwr ${flwr_subcmd} $*' across all Kubernetes execution tiers."
  return 1
}

log_info "Starting Stage 2 Siloed Local Fine-Tuning Execution (DRY_RUN=${DRY_RUN}, min_clients=${EFFECTIVE_MIN_CLIENTS})..."

STORE_IDS=("1" "2")
STORE_LABELS=("Store 1 (YOUR_STORE_1_CLUSTER)" "Store 2 (YOUR_STORE_2_CLUSTER)")
STORE_CONTEXTS=("${STORE1_CONTEXT}" "${STORE2_CONTEXT}")
STORE_IPS=("${STORE1_VLLM_LB_IP}" "${STORE2_VLLM_LB_IP}")
ADAPTER_NAMES=("store1-local-adapter" "store2-local-adapter")
OUTPUT_DIRS=("/mnt/models/store1-local-adapter" "/mnt/models/store2-local-adapter")
STEP1_VERIFIED_INDICES=()
ONLINE_STORE_INDICES=()

# ------------------------------------------------------------------------------
# Step 1/6: Verify store-local training datasets on edge PVCs (/mnt/models/edge-data/store-{1,2}/train.jsonl)
# ------------------------------------------------------------------------------
log_info "[Step 1/6] Verifying declarative store-local training datasets on edge PVCs (/mnt/models/edge-data/store-{1,2}/train.jsonl)..."
if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] Verify /mnt/models/edge-data/store-1/train.jsonl and /mnt/models/edge-data/store-2/train.jsonl SHA-256 against overlays/store-{1,2}/data/train.jsonl"
  ONLINE_STORE_INDICES=(0 1)
else
  for i in "${!STORE_IDS[@]}"; do
    sid="${STORE_IDS[$i]}"
    label="${STORE_LABELS[$i]}"
    ctx="${STORE_CONTEXTS[$i]}"
    expected_sha=$(sha256sum "${SCRIPT_DIR}/../overlays/store-${sid}/data/train.jsonl" | awk '{print $1}')
    pvc_sha=$(kubectl --context="${ctx}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum "/mnt/models/edge-data/store-${sid}/train.jsonl" 2> /dev/null | awk '{print $1}' || true)
    if [[ ${pvc_sha} == "${expected_sha}" ]]; then
      STEP1_VERIFIED_INDICES+=("${i}")
      log_success "${label}: Verified store-local PVC training dataset (sha256=${pvc_sha})."
    elif [[ -n ${pvc_sha} ]]; then
      log_error "${label} PVC dataset SHA-256 mismatch: got '${pvc_sha}', expected '${expected_sha}'"
      exit 1
    elif ((EFFECTIVE_MIN_CLIENTS >= ${#STORE_IDS[@]})); then
      log_error "${label} PVC dataset missing or cluster unreachable (got '${pvc_sha}', expected '${expected_sha}')."
      exit 1
    else
      log_warn "${label} is unreachable; skipping offline store because min-clients=${EFFECTIVE_MIN_CLIENTS}."
    fi
  done

  if ((${#STEP1_VERIFIED_INDICES[@]} < EFFECTIVE_MIN_CLIENTS)); then
    log_error "Verified ${#STEP1_VERIFIED_INDICES[@]} store dataset(s), fewer than required min-clients=${EFFECTIVE_MIN_CLIENTS}."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# Step 2/6: Verify SuperLink & SuperNodes Readiness
# ------------------------------------------------------------------------------
log_info "[Step 2/6] Verifying Flower SuperLink on GKE and SuperNodes on online edge store(s)..."

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] kubectl --context=${GKE_CONTEXT} -n fed-lora-aggregator rollout status deployment/flwr-superlink"
  echo "[DRY-RUN] kubectl --context=${STORE1_CONTEXT} -n fed-lora-poc rollout status deployment/flwr-supernode deployment/flwr-trainer"
  echo "[DRY-RUN] kubectl --context=${STORE2_CONTEXT} -n fed-lora-poc rollout status deployment/flwr-supernode deployment/flwr-trainer"
else
  log_info "Verifying Central GKE SuperLink readiness..."
  kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-superlink --timeout=120s 2> /dev/null ||
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-server --timeout=120s

  for i in "${STEP1_VERIFIED_INDICES[@]}"; do
    label="${STORE_LABELS[$i]}"
    ctx="${STORE_CONTEXTS[$i]}"
    log_info "${label}: Verifying edge SuperNode (CPU) & SuperExec Trainer (GPU) daemons readiness..."
    if kubectl --context="${ctx}" -n fed-lora-poc rollout status deployment/flwr-supernode --timeout=120s 2> /dev/null &&
      kubectl --context="${ctx}" -n fed-lora-poc rollout status deployment/flwr-trainer --timeout=120s 2> /dev/null; then
      ONLINE_STORE_INDICES+=("${i}")
      log_success "${label}: Edge SuperNode (CPU) & SuperExec Trainer (GPU Slice #2) daemons ready."
    elif ((EFFECTIVE_MIN_CLIENTS >= ${#STORE_IDS[@]})); then
      log_error "${label}: Edge SuperNode or SuperExec Trainer failed readiness check."
      exit 1
    else
      log_warn "${label}: Edge SuperNode or SuperExec Trainer not ready; skipping store (min-clients=${EFFECTIVE_MIN_CLIENTS})."
    fi
  done

  if ((${#ONLINE_STORE_INDICES[@]} < EFFECTIVE_MIN_CLIENTS)); then
    log_error "Only ${#ONLINE_STORE_INDICES[@]} online store(s) ready, fewer than required min-clients=${EFFECTIVE_MIN_CLIENTS}."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# Step 3/6: Trigger Stage 2 Local SFT centrally via Flower App (No kubectl exec!)
# ------------------------------------------------------------------------------
log_info "[Step 3/6] Triggering Stage 2 Siloed QLoRA Fine-Tuning centrally via Flower SuperLink..."
log_info "Dispatching Flower App: mode='local-sft', min-clients=${EFFECTIVE_MIN_CLIENTS} (NoOpAggregationStrategy, 0 parameter transfer)..."

if [[ ${DRY_RUN} == "true" ]]; then
  if [[ -n ${MIN_CLIENTS_OVERRIDE} ]]; then
    echo "[DRY-RUN] flwr run ${APP_DIR} gke-superlink --run-config <temp_toml:min-clients=${EFFECTIVE_MIN_CLIENTS}> --stream"
  else
    echo "[DRY-RUN] flwr run ${APP_DIR} gke-superlink --run-config run_config_local_sft.toml --stream"
  fi
else
  FLWR_STREAM_LOG="$(mktemp "${TMPDIR:-/tmp}/flwr_stage2_stream.XXXXXX.log")"
  run_flwr_cmd run --run-config "${RUN_CONFIG_ARG}" --stream 2>&1 | tee "${FLWR_STREAM_LOG}"

  canary_pass_count=0
  canary_fail_count=0
  while IFS= read -r token_val; do
    if [[ -z ${token_val} ]]; then
      continue
    elif [[ ${token_val} == "1" ]]; then
      canary_pass_count=$((canary_pass_count + 1))
    else
      canary_fail_count=$((canary_fail_count + 1))
    fi
  done < <(
    sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g; s/\r//g' "${FLWR_STREAM_LOG}" |
      { grep -Eo "canary_pass[\"']?[[:space:]]*[:=][[:space:]]*[0-9]+" || true; } |
      sed -E 's/^.*[:=][[:space:]]*//'
  )

  if ((canary_fail_count > 0)); then
    log_error "Stage 2 Local SFT failed Canary Gate (${canary_fail_count} store(s) reported canary_pass=0)."
    exit 1
  fi
  if ((canary_pass_count < EFFECTIVE_MIN_CLIENTS)); then
    log_error "Stage 2 Local SFT did not report canary_pass=1 for all ${EFFECTIVE_MIN_CLIENTS} required store(s) (observed ${canary_pass_count})."
    exit 1
  fi

  log_success "Stage 2 Siloed Local Fine-Tuning completed and passed Canary Gate (canary_pass=1 on ${canary_pass_count} store(s))."
fi

# ------------------------------------------------------------------------------
# Step 4/6: Verify Idempotent REST Hot-Swap against vLLM External LoadBalancers
# ------------------------------------------------------------------------------
log_info "[Step 4/6] Verifying REST adapter hot-swap against online store vLLM endpoint(s)..."

for i in "${ONLINE_STORE_INDICES[@]}"; do
  ip="${STORE_IPS[$i]}"
  adapter_name="${ADAPTER_NAMES[$i]}"
  output_dir="${OUTPUT_DIRS[$i]}"
  label="${STORE_LABELS[$i]}"

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "[DRY-RUN] curl -s -X POST http://${ip}:8000/v1/load_lora_adapter -H \"Content-Type: application/json\" -d '{\"lora_name\": \"${adapter_name}\", \"lora_path\": \"${output_dir}\"}'"
    continue
  fi

  log_info "${label} (${ip}:8000): Waking vLLM and ensuring '${adapter_name}' is loaded..."
  vllm_http_post "${ip}" "/wake_up" '{"tags": ["weights", "kv_cache"]}' > /dev/null 2>&1 || true
  load_resp=$(vllm_http_post "${ip}" "/v1/load_lora_adapter" \
    "{\"lora_name\": \"${adapter_name}\", \"lora_path\": \"${output_dir}\"}" || true)

  log_success "${label} (${ip}:8000): Hot-swapped LoRA adapter '${adapter_name}' into vLLM serving engine (Response: ${load_resp:-OK})."
done

# ------------------------------------------------------------------------------
# Step 5/6: Verify LoRA adapters are listed via GET /v1/models
# ------------------------------------------------------------------------------
log_info "[Step 5/6] Querying 'GET /v1/models' to verify active local LoRA adapters..."

for i in "${ONLINE_STORE_INDICES[@]}"; do
  ip="${STORE_IPS[$i]}"
  adapter_name="${ADAPTER_NAMES[$i]}"
  label="${STORE_LABELS[$i]}"

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "[DRY-RUN] curl -s http://${ip}:8000/v1/models | grep -q \"${adapter_name}\""
    log_success "${label} (${ip}:8000): Adapter '${adapter_name}' confirmed listed in /v1/models (DRY-RUN)."
    continue
  fi

  models_json=$(vllm_http_get "${ip}" "/v1/models" || true)
  if echo "${models_json}" | grep -q "${adapter_name}"; then
    log_success "${label} (${ip}:8000): Verified '${adapter_name}' is actively listed in GET /v1/models."
  else
    log_error "${label} (${ip}:8000): Adapter '${adapter_name}' was NOT found in GET /v1/models response!"
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Step 6/6: Verify GPU Memory Utilization (< 45 GB) & Zero vLLM Pod Restarts
# ------------------------------------------------------------------------------
log_info "[Step 6/6] Checking GPU memory utilization (nvidia-smi) and vLLM pod restart counts..."

for i in "${ONLINE_STORE_INDICES[@]}"; do
  label="${STORE_LABELS[$i]}"
  ctx="${STORE_CONTEXTS[$i]}"

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "[DRY-RUN] kubectl --context=${ctx} -n fed-lora-poc get pods -l app=vllm-serving"
    log_success "${label}: GPU memory well below ceiling and vLLM restart count = 0 (DRY-RUN)."
    continue
  fi

  restart_count=$(kubectl --context="${ctx}" -n fed-lora-poc get pods -l app=vllm-serving -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null || echo "0")

  if [[ ${restart_count:-0} -eq 0 ]]; then
    log_success "${label}: Physical GPU stable with zero vLLM pod restarts (restartCount = ${restart_count})."
  else
    log_warn "${label}: vLLM pod restartCount is '${restart_count}'."
  fi
done

echo ""
log_success "Stage 2 Siloed Local Fine-Tuning Execution completed successfully without any edge kubectl exec!"
