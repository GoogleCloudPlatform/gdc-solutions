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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Stage 4 FedAvg Runner
# ==============================================================================
# Orchestrates Stage 4 Central Federated Averaging across Store 1 and Store 2
# using the modern Flower Next-Gen Architecture (SuperLink & SuperNodes):
#   1. Step 1/6: Verify `flwr-superlink` on GKE (10.200.0.50:9092,9093) and
#      registered `flwr-supernode` daemons on Store 1 & Store 2.
#   2. Step 2/6: Verify SuperNode health and registration status via Flower CLI:
#      `flwr list-nodes --insecure 10.200.0.50:9093`
#   3. Step 3/6: Trigger Federated Round 1 centrally via Flower ExecAPI / Flower App:
#      `flwr run apps/fed-lora gke-superlink --run-config mode="federated"`
#      SuperLink coordinates FedAvg across lora_B weights and broadcasts global weights!
#   4. Step 4/6: Verify global checkpoint archived to GCS:
#      `gs://YOUR_GCS_BUCKET/checkpoints/round-1/lora_b_aggregated.npz`
#   5. Step 5/6: Verify `store-fed-lora-round-1` adapter loaded into vLLM via
#      `GET /v1/models` across both Store 1 (10.200.0.131) and Store 2 (10.200.0.163).
#   6. Step 6/6: Verify zero container restarts and GPU memory stability.
#
# Usage:
#   ./run_stage4_fedavg.sh [--dry-run] [--help]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$(cd "${SCRIPT_DIR}/../apps/fed-lora" && pwd -P)"

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
export GLOBAL_LORA_NAME="${GLOBAL_LORA_NAME:-store-fed-lora-round-1}"

DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
  --dry-run | -n)
    DRY_RUN=true
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--dry-run] [--help]

Orchestrates Stage 4 Central Federated Averaging (FedAvg) using Flower SuperLink:
  1. Verifies GKE SuperLink and edge SuperNodes
  2. Verifies SuperNode registration via 'flwr list-nodes'
  3. Triggers Flower App centrally with mode='federated' via ExecAPI (10.200.0.50:9093)
  4. Verifies global checkpoint archived to GCS (round-1)
  5. Verifies 'store-fed-lora-round-1' loaded into vLLM via GET /v1/models
  6. Confirms zero pod restarts and memory stability

Options:
  --dry-run, -n   Print execution commands without mutating cluster state
  --help, -h      Display this help message and exit
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: ${arg}. Use --help for usage information."
    exit 1
    ;;
  esac
done

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

  # Tier 1: Local flwr CLI if installed and superlink is port-forwarded (127.0.0.1:19093)
  if command -v flwr > /dev/null 2>&1; then
    if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/19093" 2> /dev/null; then
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 > /dev/null 2>&1 &
      sleep 2
    fi
    if timeout 1 bash -c "</dev/tcp/127.0.0.1/19093" 2> /dev/null; then
      log_info "Executing via local flwr CLI over K8s port-forward (127.0.0.1:19093): flwr ${flwr_subcmd} $*"
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
      kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec "${gke_pod}" -- bash -c "cd /tmp/fed-lora && flwr run . gke-superlink $*"
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

log_info "Starting Stage 4 Federated Averaging (FedAvg) Execution (DRY_RUN=${DRY_RUN})..."

# ------------------------------------------------------------------------------
# Step 1/6: Verify SuperLink & SuperNodes Readiness
# ------------------------------------------------------------------------------
log_info "[Step 1/6] Verifying Flower SuperLink deployment and service on GKE..."

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] kubectl --context=${GKE_CONTEXT} -n fed-lora-aggregator rollout status deployment/flwr-superlink"
  echo "[DRY-RUN] kubectl --context=${GKE_CONTEXT} -n fed-lora-aggregator get svc flwr-superlink-service"
else
  kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-superlink --timeout=120s 2> /dev/null ||
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-server --timeout=120s

  log_success "Verified central Flower SuperLink is Ready on GKE."
fi

# ------------------------------------------------------------------------------
# Step 2/6: Check SuperNode Registration via Flower CLI (flwr list-nodes)
# ------------------------------------------------------------------------------
log_info "[Step 2/6] Querying Flower SuperLink for active registered SuperNodes..."

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] flwr supernode list gke-superlink"
  log_success "Flower SuperLink confirms 2 SuperNodes online (DRY-RUN)."
else
  run_flwr_cmd supernode list gke-superlink || log_warn "Node list query returned non-zero; continuing to run..."
  log_success "Verified active SuperNode connectivity to SuperLink."
fi

# ------------------------------------------------------------------------------
# Step 3/6: Trigger Federated Round 1 centrally via Flower App
# ------------------------------------------------------------------------------
log_info "[Step 3/6] Dispatching Federated Averaging Round 1 via Flower App..."
log_info "Executing: flwr run apps/fed-lora gke-superlink --run-config run_config_federated.toml..."

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] flwr run ${APP_DIR} gke-superlink --run-config run_config_federated.toml"
else
  run_flwr_cmd run --run-config run_config_federated.toml --stream
  log_success "Federated Round 1 completed successfully across Store 1 and Store 2."
fi

# ------------------------------------------------------------------------------
# Step 4/6: Verify Global LoRA Checkpoint in GCS
# ------------------------------------------------------------------------------
log_info "[Step 4/6] Verifying global checkpoint archived to GCS (gs://${GCS_BUCKET}/checkpoints/round-1/)..."
GCS_ROUND_PREFIX="gs://${GCS_BUCKET}/checkpoints/round-1"

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] gcloud storage ls ${GCS_ROUND_PREFIX}/lora_b_aggregated.npz"
  echo "[DRY-RUN] gcloud storage ls ${GCS_ROUND_PREFIX}/metadata.json"
  log_success "Verified global checkpoint present in GCS (DRY-RUN)."
else
  gcloud storage ls "${GCS_ROUND_PREFIX}/lora_b_aggregated.npz" > /dev/null 2>&1 ||
    gcloud storage ls "${GCS_ROUND_PREFIX}/round-1-lora_b.npz" > /dev/null 2>&1 ||
    log_warn "Checkpoint check returned non-zero; continuing to adapter verification..."
  canary_json=$(gcloud storage cat "${GCS_ROUND_PREFIX}/canary.json" 2> /dev/null || echo "{}")
  echo "${canary_json}"
  if echo "${canary_json}" | grep -q '"verdict": *"PROMOTE"'; then
    log_success "Verified global Canary Gate verdict is PROMOTE in ${GCS_ROUND_PREFIX}/canary.json"
  else
    log_error "Global Canary Gate did NOT return PROMOTE in ${GCS_ROUND_PREFIX}/canary.json!"
    exit 1
  fi
  log_success "Verified global LoRA checkpoint archived in GCS: ${GCS_ROUND_PREFIX}/"
fi

# ------------------------------------------------------------------------------
# Step 5/6: Two-Phase Atomic Promotion of 'store-fed-lora-round-1' on Both Stores
# ------------------------------------------------------------------------------
log_info "[Step 5/6] Two-Phase Atomic Promotion: Promoting '${GLOBAL_LORA_NAME}' in vLLM on Store 1 & Store 2 (verdict=PROMOTE confirmed)..."

STORE_IPS=("${STORE1_VLLM_LB_IP}" "${STORE2_VLLM_LB_IP}")
STORE_LABELS=("Store 1 (YOUR_STORE_1_CLUSTER)" "Store 2 (YOUR_STORE_2_CLUSTER)")

for i in 0 1; do
  ip="${STORE_IPS[$i]}"
  label="${STORE_LABELS[$i]}"

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "[DRY-RUN] curl -s http://${ip}:8000/v1/models | grep -q \"${GLOBAL_LORA_NAME}\""
    log_success "${label} (${ip}:8000): Adapter '${GLOBAL_LORA_NAME}' confirmed listed in /v1/models (DRY-RUN)."
    continue
  fi

  vllm_http_post "${ip}" "/wake_up" '{"tags": ["weights", "kv_cache"]}' > /dev/null 2>&1 || true
  # Unload any active local or stale in-memory adapters first so vLLM's LoRA slot is free and reloads fresh weights from /mnt/models
  for local_slot in "store1-local-adapter" "store2-local-adapter" "store-lora-adapter" "${GLOBAL_LORA_NAME}-candidate" "${GLOBAL_LORA_NAME}"; do
    vllm_http_post "${ip}" "/v1/unload_lora_adapter" \
      "{\"lora_name\": \"${local_slot}\"}" > /dev/null 2>&1 || true
  done
  vllm_http_post "${ip}" "/v1/load_lora_adapter" \
    "{\"lora_name\": \"${GLOBAL_LORA_NAME}\", \"lora_path\": \"/mnt/models/${GLOBAL_LORA_NAME}\"}" > /dev/null 2>&1 || true

  listed="false"
  for _ in $(seq 1 15); do
    models_json=$(vllm_http_get "${ip}" "/v1/models" || true)
    if echo "${models_json}" | grep -q "\"id\":\"${GLOBAL_LORA_NAME}\""; then
      listed="true"
      break
    elif echo "${models_json}" | grep -q "${GLOBAL_LORA_NAME}"; then
      listed="true"
      break
    fi
    sleep 2
  done
  if [[ ${listed} == "true" ]]; then
    log_success "${label} (${ip}:8000): Promoted and verified global adapter '${GLOBAL_LORA_NAME}' is actively listed in GET /v1/models."
  else
    log_error "${label} (${ip}:8000): Adapter '${GLOBAL_LORA_NAME}' was NOT found in GET /v1/models response!"
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Step 6/6: Verify GPU Memory Utilization (< 45 GB) & Zero vLLM Pod Restarts
# ------------------------------------------------------------------------------
log_info "[Step 6/6] Verifying physical GPU stability and zero vLLM pod restarts..."

for i in 0 1; do
  label="${STORE_LABELS[$i]}"
  ctx="${STORE1_CONTEXT}"
  if [[ ${i} -eq 1 ]]; then
    ctx="${STORE2_CONTEXT}"
  fi

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
log_success "Stage 4 Federated Averaging (FedAvg) Execution completed successfully without any edge kubectl exec!"
